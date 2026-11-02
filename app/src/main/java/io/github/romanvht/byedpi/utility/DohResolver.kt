package io.github.romanvht.byedpi.utility

import android.content.Context
import android.util.Log
import androidx.annotation.Keep
import kotlinx.coroutines.runBlocking
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread

/**
 * AutoDPI: encrypted DNS for every app while the VPN runs.
 *
 * The VPN's DNS server is a local address (MAPDNS) that the tunnel answers itself with
 * placeholder addresses, and connections are handed to ByeDPI with the site's name.
 * ByeDPI then asks this resolver (through getaddrinfo, see byedpi-jni.c), which looks the
 * name up over DNS-over-HTTPS. So no app ever sends plain DNS to the internet provider.
 */
@Keep
object DohResolver {
    private const val TAG = "DohResolver"
    private const val TIMEOUT_MS = 3000
    private const val CACHE_MS = 5 * 60 * 1000L
    private const val PROVIDER_FILE = "autodpi_dns.txt"

    /** VPN DNS address answered by the tunnel itself. */
    const val MAPDNS = "10.10.10.53"

    private val cache = ConcurrentHashMap<String, Pair<String, Long>>()
    private val lock = Any()
    @Volatile private var order: List<DohUtils.Provider> = DohUtils.providers
    private var connection: SSLSocket? = null
    private var connected: DohUtils.Provider? = null
    private var file: File? = null

    /** Name of the encrypted DNS server in use, as last saved (null = not chosen yet). */
    fun currentName(context: Context): String? =
        runCatching { File(context.filesDir, PROVIDER_FILE).readText().trim() }.getOrNull()?.ifBlank { null }

    /** Saves the server to use (the fastest one from the test). */
    fun save(context: Context, provider: DohUtils.Provider) {
        runCatching { File(context.filesDir, PROVIDER_FILE).writeText(provider.name) }
    }

    /** Reset: the next start picks the fastest server again. */
    fun forget(context: Context) {
        File(context.filesDir, PROVIDER_FILE).delete()
    }

    /**
     * Called in the VPN process before ByeDPI starts: begins with the saved server (if any)
     * and switches to the fastest one on this network as soon as that is measured.
     */
    fun init(context: Context) {
        file = File(context.filesDir, PROVIDER_FILE)
        cache.clear()
        val name = currentName(context)
        DohUtils.providers.firstOrNull { it.name == name }?.let { use(it) }
        thread(name = "DoH rank") {
            val fastest = runBlocking { DohUtils.rankBySpeed(TIMEOUT_MS) }.firstOrNull()?.first
            if (fastest != null) use(fastest)
        }
    }

    private fun use(provider: DohUtils.Provider) {
        order = listOf(provider) + DohUtils.providers.filter { it != provider }
        runCatching { file?.writeText(provider.name) }
    }

    /**
     * IPv4 address of [host] (called from native code). "" = the name does not exist,
     * null = no encrypted DNS server answered (ByeDPI then falls back to normal DNS).
     */
    @JvmStatic
    fun resolve(host: String): String? {
        val key = host.lowercase().trimEnd('.')
        cache[key]?.let { (ip, time) -> if (System.currentTimeMillis() - time < CACHE_MS) return ip }
        synchronized(lock) {
            // at most 3 servers, so a dead network does not stall browsing for long
            for (provider in order.take(3)) {
                val answer = ask(provider, key) ?: continue
                if (provider != order.first()) use(provider)
                val ip = answer.firstOrNull { !DohUtils.isBogus(it) }.orEmpty()
                cache[key] = ip to System.currentTimeMillis()
                return ip
            }
        }
        Log.w(TAG, "No encrypted DNS server answered for $key")
        return null
    }

    /** Tries: the open connection, a new one to the fixed address, then one via normal lookup. */
    private fun ask(provider: DohUtils.Provider, host: String): List<String>? {
        for (step in 0..2) {
            try {
                val ssl = if (step == 0) {
                    connection?.takeIf { connected == provider && !it.isClosed } ?: continue
                } else {
                    close()
                    DohUtils.open(provider, TIMEOUT_MS, pinned = step == 1).also {
                        connection = it
                        connected = provider
                    }
                }
                DohUtils.exchange(ssl, provider, host, keepAlive = true)?.let { return it }
            } catch (e: Exception) {
                Log.d(TAG, "${provider.name}: ${e.message}")
            }
            close()
        }
        return null
    }

    private fun close() {
        runCatching { connection?.close() }
        connection = null
        connected = null
    }
}
