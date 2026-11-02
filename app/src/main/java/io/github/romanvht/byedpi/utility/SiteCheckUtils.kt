package io.github.romanvht.byedpi.utility

import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.coroutines.coroutineContext

class SiteCheckUtils(
    private val proxyIp: String,
    private val proxyPort: Int,
    // AutoDPI: true = connect directly (no proxy), used for the "without bypass" baseline
    private val direct: Boolean = false,
    // AutoDPI: read at most this much of each page (16 KB is enough to know the site opened)
    private val maxBytes: Long = 1024L * 1024,
    // AutoDPI: site address from encrypted DNS (host -> IPv4); null = normal DNS lookup
    private val resolver: ((String) -> String?)? = null
) {

    suspend fun checkSitesAsync(
        sites: List<String>,
        requestsCount: Int,
        requestTimeout: Long,
        concurrentRequests: Int = 20,
        fullLog: Boolean,
        onSiteChecked: (suspend (String, Int, Int) -> Unit)? = null,
        // AutoDPI: site, successes, requests, total ms of the successful requests
        onSiteTimed: (suspend (String, Int, Int, Long) -> Unit)? = null
    ): List<Pair<String, Int>> {
        val semaphore = Semaphore(concurrentRequests)
        return withContext(Dispatchers.IO) {
            sites.map { site ->
                async {
                    semaphore.withPermit {
                        val (successCount, successMs) = checkSiteAccess(site, requestsCount, requestTimeout)
                        coroutineContext.ensureActive()
                        if (fullLog) {
                            onSiteChecked?.invoke(site, successCount, requestsCount)
                        }
                        onSiteTimed?.invoke(site, successCount, requestsCount, successMs)
                        site to successCount
                    }
                }
            }.awaitAll()
        }
    }

    private suspend fun checkSiteAccess(
        site: String,
        requestsCount: Int,
        timeout: Long
    ): Pair<Int, Long> = withContext(Dispatchers.IO) {
        var responseCount = 0
        var successMs = 0L

        val formattedUrl = if (site.startsWith("http://") || site.startsWith("https://")) site
        else "https://$site"

        val url = try {
            URL(formattedUrl)
        } catch (_: Exception) {
            Log.e("SiteChecker", "Invalid URL: $formattedUrl")
            return@withContext 0 to 0L
        }

        val proxy = if (direct) Proxy.NO_PROXY else Proxy(Proxy.Type.SOCKS, InetSocketAddress(proxyIp, proxyPort))

        repeat(requestsCount) { attempt ->
            coroutineContext.ensureActive()
            Log.i("SiteChecker", "Attempt ${attempt + 1}/$requestsCount for $site")

            // AutoDPI: with encrypted DNS, connect to the DoH address and do TLS under the real name
            val pinnedIp = if (url.protocol == "https") resolver?.invoke(url.host) else null
            if (pinnedIp != null) {
                val started = System.currentTimeMillis()
                if (rawHttpsOk(url, pinnedIp, proxy, (timeout * 1000).toInt())) {
                    responseCount++
                    successMs += System.currentTimeMillis() - started
                }
                return@repeat
            }

            var connection: HttpURLConnection? = null
            val startedAt = System.currentTimeMillis()
            try {
                connection = url.openConnection(proxy) as HttpURLConnection
                connection.connectTimeout = (timeout * 1000).toInt()
                connection.readTimeout = (timeout * 1000).toInt()
                connection.instanceFollowRedirects = true
                connection.setRequestProperty("Connection", "close")

                val responseCode = connection.responseCode
                val declaredLength = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                    connection.contentLengthLong
                } else {
                    connection.contentLength.toLong()
                }

                var actualLength = 0L
                try {
                    val inputStream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
                    if (inputStream != null) {
                        val buffer = ByteArray(8192)
                        var bytesRead: Int

                        val limit = if (declaredLength > 0) minOf(declaredLength, maxBytes) else maxBytes

                        while (actualLength < limit) {
                            coroutineContext.ensureActive()
                            val remaining = limit - actualLength
                            val toRead = if (remaining > buffer.size) buffer.size else remaining.toInt()
                            bytesRead = inputStream.read(buffer, 0, toRead)
                            if (bytesRead == -1) break
                            actualLength += bytesRead
                        }
                    }
                } catch (_: IOException) {
                    // Stream reading failed
                }

                if (declaredLength <= 0L || actualLength >= minOf(declaredLength, maxBytes)) {
                    Log.i("SiteChecker", "Response for $site: $responseCode, Declared: $declaredLength, Actual: $actualLength")
                    responseCount++
                    successMs += System.currentTimeMillis() - startedAt
                } else {
                    Log.w("SiteChecker", "Block detected for $site, Declared: $declaredLength, Actual: $actualLength")
                }

            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e("SiteChecker", "Error accessing $site: ${e.message}")
            } finally {
                connection?.disconnect()
            }
        }

        responseCount to successMs
    }

    /**
     * AutoDPI: HTTPS request to a fixed address (from encrypted DNS) through [proxy].
     * Success = valid certificate for the site + an HTTP answer below 500 + the start of the
     * page (up to maxBytes) arriving in full.
     */
    private fun rawHttpsOk(url: URL, ip: String, proxy: Proxy, timeoutMs: Int): Boolean = try {
        val host = url.host
        val port = if (url.port > 0) url.port else 443
        val plain = Socket(proxy)
        plain.soTimeout = timeoutMs
        plain.connect(InetSocketAddress(ip, port), timeoutMs)
        (SSLSocketFactory.getDefault() as SSLSocketFactory).createSocket(plain, host, port, true).use { socket ->
            val ssl = socket as SSLSocket
            ssl.soTimeout = timeoutMs
            ssl.startHandshake()
            if (!HttpsURLConnection.getDefaultHostnameVerifier().verify(host, ssl.session)) {
                Log.w("SiteChecker", "Certificate mismatch for $host at $ip")
                false
            } else {
                val path = url.path.ifEmpty { "/" } + (url.query?.let { "?$it" } ?: "")
                val request = "GET $path HTTP/1.1\r\nHost: $host\r\n" +
                    "User-Agent: Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36\r\n" +
                    "Accept: text/html,*/*\r\nConnection: close\r\n\r\n"
                ssl.outputStream.write(request.toByteArray())
                ssl.outputStream.flush()
                val response = DohUtils.readHttp(ssl.inputStream, maxBytes.toInt())
                Log.i("SiteChecker", "Response for $host via $ip: ${response.status}, complete: ${response.complete}")
                response.status in 100..499 && response.complete
            }
        }
    } catch (e: Exception) {
        Log.e("SiteChecker", "Error accessing ${url.host} via $ip: ${e.message}")
        false
    }
}
