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
 * Product rule: the proxy is for the phone's **own** tether (Wi‑Fi SoftAP / USB /
 * BT pan), not café/home STA Wi‑Fi. Interface **names alone are never trusted**
 * without a tethering signal (SoftAP reflection, LOCAL_NETWORK wifi, or an
 * active rndis/bt-pan address). Empty list → UI asks to enable hotspot.
 *
 * Chipsets that put SoftAP on `wlan0`: when SoftAP is enabled and no dedicated
 * `ap*`/`swlan*` name exists, we return all private candidates so the user can
 * still bind.
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
     * using SoftAP / LOCAL_NETWORK / USB-tether signals.
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
     * Require an actual tethering signal before any candidate is offered.
     * Name heuristics only **rank** within an already-confirmed tether session.
     */
    fun filterForListen(context: Context, all: List<Endpoint>): List<Endpoint> {
        if (all.isEmpty()) return emptyList()
        if (!isTetheringActive(context, all)) {
            return emptyList()
        }
        val preferred = all.filter { it.hotspotLike }
        // SoftAP on opaque wlan0: no dedicated name → offer all private ifaces.
        return if (preferred.isNotEmpty()) preferred else all
    }

    /**
     * SoftAP (reflection), LOCAL_NETWORK Wi‑Fi capability, or USB/BT tether iface up.
     */
    fun isTetheringActive(context: Context, endpoints: List<Endpoint> = emptyList()): Boolean {
        if (isSoftApEnabled(context)) return true
        if (hasLocalNetworkWifi(context)) return true
        // USB / BT tether: interface presence is the signal (not café STA names).
        val list = endpoints.ifEmpty { scanAllPrivateIpv4() }
        return list.any {
            val n = it.interfaceName.lowercase()
            n.startsWith("rndis") || n.startsWith("bt-pan") || n.contains("usb")
        }
    }

    fun isSoftApEnabled(context: Context): Boolean {
        val app = context.applicationContext
        val wifi = app.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return false
        try {
            val m = wifi.javaClass.getMethod("isWifiApEnabled")
            if (m.invoke(wifi) as Boolean) return true
        } catch (_: Exception) {
        }
        return false
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

    /**
     * Ranking only — never sufficient alone to expose an address for bind.
     */
    fun isHotspotLikeName(name: String): Boolean {
        val n = name.lowercase()
        return n.startsWith("ap") ||
            n.contains("swlan") ||
            n.contains("softap") ||
            n.startsWith("rndis") ||
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
