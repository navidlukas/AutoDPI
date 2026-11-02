package io.github.romanvht.byedpi.utility

import android.util.Base64
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.InputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

/**
 * AutoDPI: small encrypted-DNS client.
 * DoH (DNS over HTTPS) and DoT (DNS over TLS) are spoken directly over TLS to fixed server
 * addresses, so a faked DNS answer from the internet provider cannot redirect them.
 */
object DohUtils {
    private const val TAG = "DohUtils"

    data class Provider(
        val name: String,
        val dohHost: String,  // DoH server name (TLS certificate)
        val dohIp: String,    // fixed address of the DoH server
        val dns1: String,     // plain DNS addresses, used as the VPN's DNS server
        val dns2: String,
        val dotHost: String,  // name for Android's Private DNS (DoT)
    )

    val providers = listOf(
        Provider("Quad9", "dns.quad9.net", "9.9.9.9", "9.9.9.9", "149.112.112.112", "dns.quad9.net"),
        Provider("Cloudflare", "cloudflare-dns.com", "1.1.1.1", "1.1.1.1", "1.0.0.1", "one.one.one.one"),
        Provider("Google", "dns.google", "8.8.8.8", "8.8.8.8", "8.8.4.4", "dns.google"),
        Provider("AdGuard", "dns.adguard-dns.com", "94.140.14.14", "94.140.14.14", "94.140.15.15", "dns.adguard-dns.com"),
        Provider("Yandex", "common.dot.dns.yandex.net", "77.88.8.8", "77.88.8.8", "77.88.8.1", "common.dot.dns.yandex.net"),
        Provider("OpenDNS", "doh.opendns.com", "146.112.41.2", "208.67.222.222", "208.67.220.220", "dns.opendns.com"),
    )

    /** Fastest provider that answers a DoH query, with its time in ms; null if none answers. */
    suspend fun pickFastest(timeoutMs: Int): Pair<Provider, Long>? = coroutineScope {
        providers.map { provider ->
            async(Dispatchers.IO) {
                val started = System.currentTimeMillis()
                val answer = doh(provider, "example.com", timeoutMs)
                if (answer.isNullOrEmpty()) null else provider to (System.currentTimeMillis() - started)
            }
        }.awaitAll().filterNotNull().minByOrNull { it.second }
    }

    /** IPv4 addresses of [name] via DoH; first with the fixed server address, then via a normal lookup. */
    fun doh(provider: Provider, name: String, timeoutMs: Int): List<String>? =
        dohOnce(provider, name, timeoutMs, pinned = true) ?: dohOnce(provider, name, timeoutMs, pinned = false)

    private fun dohOnce(provider: Provider, name: String, timeoutMs: Int, pinned: Boolean): List<String>? = try {
        val target = if (pinned) InetSocketAddress(provider.dohIp, 443) else InetSocketAddress(provider.dohHost, 443)
        tls(target, provider.dohHost, timeoutMs).use { ssl ->
            val query = Base64.encodeToString(query(name), Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
            val request = "GET /dns-query?dns=$query HTTP/1.1\r\nHost: ${provider.dohHost}\r\n" +
                "Accept: application/dns-message\r\nConnection: close\r\n\r\n"
            ssl.outputStream.write(request.toByteArray())
            ssl.outputStream.flush()
            val response = readHttp(ssl.inputStream, 64 * 1024)
            if (response.status != 200) null else parseA(response.body)
        }
    } catch (e: Exception) {
        Log.d(TAG, "DoH ${provider.name} ($name, pinned=$pinned) failed: ${e.message}")
        null
    }

    /** Can [provider]'s DoT (Android Private DNS) be reached and does it answer? */
    fun dotWorks(provider: Provider, timeoutMs: Int): Boolean = try {
        tls(InetSocketAddress(provider.dns1, 853), provider.dotHost, timeoutMs).use { ssl ->
            val q = query("example.com")
            ssl.outputStream.write(byteArrayOf((q.size shr 8).toByte(), q.size.toByte()) + q)
            ssl.outputStream.flush()
            val input = DataInputStream(ssl.inputStream)
            val length = input.readUnsignedShort()
            val answer = ByteArray(length)
            input.readFully(answer)
            parseA(answer).isNotEmpty()
        }
    } catch (e: Exception) {
        Log.d(TAG, "DoT ${provider.name} failed: ${e.message}")
        false
    }

    /** Plain (unencrypted) DNS lookup sent to [server]; null on timeout. */
    fun udp(server: String, name: String, timeoutMs: Int): List<String>? = try {
        DatagramSocket().use { socket ->
            socket.soTimeout = timeoutMs
            val q = query(name)
            socket.send(DatagramPacket(q, q.size, InetAddress.getByName(server), 53))
            val buffer = ByteArray(1500)
            val packet = DatagramPacket(buffer, buffer.size)
            socket.receive(packet)
            parseA(buffer.copyOf(packet.length))
        }
    } catch (e: Exception) {
        null
    }

    /** Addresses DNS blockers typically answer with (local, private, or "nowhere"). */
    fun isBogus(ip: String): Boolean {
        val p = ip.split(".").mapNotNull { it.toIntOrNull() }
        if (p.size != 4) return true
        return p[0] == 0 || p[0] == 10 || p[0] == 127 || (p[0] == 169 && p[1] == 254) ||
            (p[0] == 172 && p[1] in 16..31) || (p[0] == 192 && p[1] == 168) || (p[0] == 100 && p[1] in 64..127)
    }

    // ---------- TLS / HTTP / DNS helpers ----------

    private fun tls(target: InetSocketAddress, serverName: String, timeoutMs: Int): SSLSocket {
        val plain = Socket()
        plain.connect(target, timeoutMs)
        plain.soTimeout = timeoutMs
        val ssl = (SSLSocketFactory.getDefault() as SSLSocketFactory)
            .createSocket(plain, serverName, target.port, true) as SSLSocket
        ssl.soTimeout = timeoutMs
        ssl.startHandshake()
        if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(serverName, ssl.session)) {
            ssl.close()
            throw IllegalStateException("certificate does not match $serverName")
        }
        return ssl
    }

    class HttpResponse(val status: Int, val headers: Map<String, String>, val body: ByteArray, val complete: Boolean)

    /**
     * Reads an HTTP/1.1 response: status, headers and up to [maxBody] bytes of the body.
     * [complete] is true when the body (or its first [maxBody] bytes) arrived in full.
     */
    fun readHttp(input: InputStream, maxBody: Int): HttpResponse {
        val head = ByteArrayOutputStream()
        var matched = 0
        while (matched < 4 && head.size() < 32 * 1024) {
            val b = input.read()
            if (b < 0) break
            head.write(b)
            matched = when {
                (matched == 0 || matched == 2) && b == '\r'.code -> matched + 1
                (matched == 1 || matched == 3) && b == '\n'.code -> matched + 1
                b == '\r'.code -> 1
                else -> 0
            }
        }
        val lines = head.toString("ISO-8859-1").split("\r\n")
        val status = lines.firstOrNull()?.split(" ")?.getOrNull(1)?.toIntOrNull() ?: 0
        val headers = lines.drop(1).mapNotNull { line ->
            val i = line.indexOf(':')
            if (i <= 0) null else line.substring(0, i).trim().lowercase() to line.substring(i + 1).trim()
        }.toMap()
        val length = headers["content-length"]?.toLongOrNull() ?: -1L
        val chunked = headers["transfer-encoding"]?.contains("chunked", ignoreCase = true) == true
        val body = ByteArrayOutputStream()
        var complete: Boolean
        if (chunked) {
            complete = true
            while (body.size() < maxBody) {
                val sizeLine = readLine(input)
                if (sizeLine == null) { complete = false; break }
                val size = sizeLine.substringBefore(';').trim().toIntOrNull(16)
                if (size == null) { complete = false; break }
                if (size == 0) break
                val want = minOf(size, maxBody - body.size())
                if (copy(input, body, want.toLong()) < want) { complete = false; break }
                if (want < size) break
                readLine(input)
            }
        } else {
            val want = if (length >= 0) minOf(length, maxBody.toLong()) else maxBody.toLong()
            val got = copy(input, body, want)
            complete = length < 0 || got >= want
        }
        return HttpResponse(status, headers, body.toByteArray(), complete)
    }

    private fun readLine(input: InputStream): String? {
        val line = StringBuilder()
        while (true) {
            val b = input.read()
            if (b < 0) return if (line.isEmpty()) null else line.toString()
            if (b == '\n'.code) return line.toString().trimEnd('\r')
            line.append(b.toChar())
        }
    }

    private fun copy(input: InputStream, out: ByteArrayOutputStream, max: Long): Long {
        val buffer = ByteArray(8192)
        var total = 0L
        while (total < max) {
            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), max - total).toInt())
            if (n < 0) break
            out.write(buffer, 0, n)
            total += n
        }
        return total
    }

    /** DNS query packet for the A (IPv4) record of [name]. */
    fun query(name: String): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(byteArrayOf(0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0)) // id 0, recursion desired, 1 question
        for (label in name.trimEnd('.').split('.')) {
            val bytes = label.toByteArray()
            out.write(bytes.size)
            out.write(bytes)
        }
        out.write(byteArrayOf(0, 0, 1, 0, 1)) // end of name, type A, class IN
        return out.toByteArray()
    }

    /** IPv4 addresses from a DNS response (empty list for "no such name" or no A records). */
    fun parseA(msg: ByteArray): List<String> {
        if (msg.size < 12) return emptyList()
        fun u16(i: Int) = ((msg[i].toInt() and 0xff) shl 8) or (msg[i + 1].toInt() and 0xff)
        val questions = u16(4)
        val answers = u16(6)
        var pos = 12
        fun skipName() {
            while (pos < msg.size) {
                val len = msg[pos].toInt() and 0xff
                if (len == 0) { pos += 1; return }
                if (len and 0xc0 == 0xc0) { pos += 2; return }
                pos += len + 1
            }
        }
        repeat(questions) { skipName(); pos += 4 }
        val result = mutableListOf<String>()
        repeat(answers) {
            if (pos >= msg.size) return result
            skipName()
            if (pos + 10 > msg.size) return result
            val type = u16(pos)
            val rdLength = u16(pos + 8)
            pos += 10
            if (type == 1 && rdLength == 4 && pos + 4 <= msg.size) {
                result.add((0 until 4).joinToString(".") { (msg[pos + it].toInt() and 0xff).toString() })
            }
            pos += rdLength
        }
        return result
    }

    /** Resolves many hosts in parallel with [provider]; hosts that fail are left out. */
    suspend fun resolveAll(provider: Provider, hosts: Collection<String>, timeoutMs: Int): Map<String, String> =
        withContext(Dispatchers.IO) {
            hosts.distinct().map { host ->
                async { host to doh(provider, host, timeoutMs)?.firstOrNull { !isBogus(it) } }
            }.awaitAll().mapNotNull { (host, ip) -> ip?.let { host to it } }.toMap()
        }
}
