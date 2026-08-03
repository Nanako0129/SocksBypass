package com.nanako.socksbypass.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Enumerate private IPv4 addresses suitable for a hotspot / LAN listener.
 * Does not auto-start tethering. Avoids loopback, VPN, and common cellular ifaces.
 *
 * Product rule (upstream review): the proxy is meant for the phone's **personal
 * hotspot**, not café/home STA Wi‑Fi. When SoftAP is off we do not offer station
 * wlan addresses for bind — empty list → UI asks the user to enable hotspot.
 */
object LocalEndpointScanner {
    data class Endpoint(
        val interfaceName: String,
        val address: String,
        /** True when the iface name looks like SoftAP / tether bridge. */
        val hotspotLike: Boolean = false,
    )

    /**
     * Scan private IPv4 listen candidates. When [context] is provided, filters
     * using SoftAP / LOCAL_NETWORK signals so café `wlan0` is not auto-offered.
     */
    fun scanPrivateIpv4(context: Context? = null): List<Endpoint> {
        val raw = scanAllPrivateIpv4()
        if (context == null) return raw
        return filterForListen(context, raw)
    }

    fun scanAllPrivateIpv4(): List<Endpoint> {
        val results = ArrayList<Endpoint>()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        } catch (_: Exception) {
            emptyList()
        }
        for (nif in interfaces) {
            val up = try {
                nif.isUp
            } catch (_: Exception) {
                continue
            }
            val loopback = try {
                nif.isLoopback
            } catch (_: Exception) {
                continue
            }
            if (!up || loopback) continue
            val name = try {
                nif.name.lowercase()
            } catch (_: Exception) {
                continue
            }
            if (isExcludedInterface(name)) continue
            val addrs = try {
                nif.inetAddresses.toList()
            } catch (_: Exception) {
                emptyList()
            }
            val hotspotLike = isHotspotLikeName(name)
            for (addr in addrs) {
                if (addr !is Inet4Address) continue
                if (addr.isLoopbackAddress) continue
                val host = addr.hostAddress ?: continue
                if (!isPrivateIpv4(host)) continue
                results.add(
                    Endpoint(
                        interfaceName = nif.name,
                        address = host,
                        hotspotLike = hotspotLike,
                    ),
                )
            }
        }
        return results.sortedWith(
            compareBy<Endpoint> { if (it.hotspotLike) 0 else hotspotScore(it.interfaceName) }
                .thenBy { it.address },
        )
    }

    /**
     * Prefer SoftAP interfaces when present; if SoftAP appears enabled but names
     * are opaque (some chipsets use wlan0 for AP), keep all private candidates.
     * If SoftAP is off, return **empty** so UI does not bind café STA Wi‑Fi.
     */
    fun filterForListen(context: Context, all: List<Endpoint>): List<Endpoint> {
        if (all.isEmpty()) return emptyList()
        val apLike = all.filter { it.hotspotLike }
        if (apLike.isNotEmpty()) return apLike
        return if (isSoftApEnabled(context) || hasLocalNetworkWifi(context)) {
            all
        } else {
            emptyList()
        }
    }

    fun isSoftApEnabled(context: Context): Boolean {
        val app = context.applicationContext
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return false
        // Public API removed; reflection still works on current Samsung builds.
        try {
            @Suppress("UNCHECKED_CAST")
            val m = wifi.javaClass.getMethod("isWifiApEnabled")
            if (m.invoke(wifi) as Boolean) return true
        } catch (_: Exception) {
        }
        return hasLocalNetworkWifi(app)
    }

    private fun hasLocalNetworkWifi(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val cm = context.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return false
        return try {
            cm.allNetworks.any { network ->
                val caps = cm.getNetworkCapabilities(network) ?: return@any false
                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return@any false
                // SoftAP / local-only networks often advertise LOCAL_NETWORK.
                if (Build.VERSION.SDK_INT >= 30) {
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_LOCAL_NETWORK)
                } else {
                    false
                }
            }
        } catch (_: Exception) {
            false
        }
    }

    fun isHotspotLikeName(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("ap") ||
            n.contains("swlan") ||
            n.contains("softap") ||
            n.contains("wlan1") || // common second radio AP
            n.startsWith("rndis") || // USB tethering
            n.startsWith("bt-pan")
    }

    private fun isExcludedInterface(name: String): Boolean {
        if (name == "lo" || name.startsWith("lo")) return true
        if (name.startsWith("tun") || name.startsWith("tap")) return true
        if (name.startsWith("wg") || name.startsWith("vpn")) return true
        if (name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("pdp")) return true
        if (name.startsWith("wwan") || name.startsWith("mobile") || name.contains("cellular")) return true
        return false
    }

    private fun hotspotScore(name: String): Int {
        val n = name.lowercase()
        return when {
            isHotspotLikeName(n) -> 0
            n.startsWith("wlan") -> 1
            n.startsWith("eth") -> 2
            else -> 3
        }
    }

    fun isPrivateIpv4(host: String): Boolean {
        val parts = host.split('.')
        if (parts.size != 4) return false
        val o = parts.mapNotNull { it.toIntOrNull() }
        if (o.size != 4 || o.any { it !in 0..255 }) return false
        return when {
            o[0] == 10 -> true
            o[0] == 172 && o[1] in 16..31 -> true
            o[0] == 192 && o[1] == 168 -> true
            o[0] == 169 && o[1] == 254 -> false
            else -> false
        }
    }
}
