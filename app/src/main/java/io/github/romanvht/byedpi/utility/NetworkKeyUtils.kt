package io.github.romanvht.byedpi.utility

import android.content.Context
import android.content.SharedPreferences
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.telephony.TelephonyManager
import androidx.core.content.edit

/**
 * AutoDPI: remembers the best setting separately for each network.
 *
 * A network is identified without location permission:
 *  - Wi-Fi / Ethernet: router (default gateway) address + DHCP domain
 *  - Mobile data: operator code (MCC+MNC)
 * The VPN network itself is skipped, so the key describes the real connection.
 */
object NetworkKeyUtils {
    private const val WINNER_PREFIX = "autodpi_winner_"
    private const val SCORE_PREFIX = "autodpi_score_"
    // the command AutoDPI applied last; used to know whether the user picked something by hand since
    private const val APPLIED_KEY = "autodpi_applied"

    fun currentKey(context: Context): String {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "unknown"
        @Suppress("DEPRECATION")
        val candidates: List<Network> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) listOfNotNull(cm.activeNetwork) + cm.allNetworks
            else cm.allNetworks.toList()

        for (network in candidates) {
            val caps = cm.getNetworkCapabilities(network) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
            val link = cm.getLinkProperties(network)
            val gateway = link?.routes
                ?.firstOrNull { it.isDefaultRoute && it.gateway != null }
                ?.gateway?.hostAddress.orEmpty()
            val domain = link?.domains.orEmpty()
            return when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi:$gateway:$domain"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet:$gateway:$domain"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "mobile:" + operator(context)
                else -> "other:$gateway"
            }
        }
        return "unknown"
    }

    private fun operator(context: Context): String = try {
        (context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager)?.networkOperator.orEmpty()
    } catch (_: Exception) {
        ""
    }

    fun savedWinner(prefs: SharedPreferences, key: String): Pair<String, Int>? {
        val command = prefs.getString(WINNER_PREFIX + key, null) ?: return null
        val score = prefs.getInt(SCORE_PREFIX + key, -1)
        return if (command.isBlank() || score <= 0) null else command to score
    }

    fun saveWinner(prefs: SharedPreferences, key: String, command: String, score: Int) {
        prefs.edit(commit = true) {
            putString(WINNER_PREFIX + key, command)
            putInt(SCORE_PREFIX + key, score)
            putString(APPLIED_KEY, command)
            putString("byedpi_cmd_args", command)
            putBoolean("byedpi_enable_cmd_settings", true)
        }
    }

    /**
     * Before connecting: if the current network has its own saved winner and the active
     * strategy was set by AutoDPI (not picked by hand), switch to this network's winner.
     * Returns true when the strategy was changed.
     */
    fun switchToNetworkWinner(context: Context): Boolean {
        val prefs = context.getPreferences()
        val active = prefs.getString("byedpi_cmd_args", "").orEmpty()
        if (active != prefs.getString(APPLIED_KEY, null)) return false
        val (command, _) = savedWinner(prefs, currentKey(context)) ?: return false
        if (command == active) return false
        prefs.edit(commit = true) {
            putString("byedpi_cmd_args", command)
            putString(APPLIED_KEY, command)
        }
        return true
    }
}
