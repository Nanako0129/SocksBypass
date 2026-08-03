package com.nanako.socksbypass.network

import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Enumerate private IPv4 addresses suitable for a hotspot / LAN listener.
 * Does not auto-start tethering. Avoids loopback, VPN, and common cellular ifaces.
 */
object LocalEndpointScanner {
    data class Endpoint(
        val interfaceName: String,
        val address: String,
    )

    fun scanPrivateIpv4(): List<Endpoint> {
        val results = ArrayList<Endpoint>()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        } catch (_: Exception) {
            emptyList()
        }
        for (nif in interfaces) {
            // isUp/isLoopback can throw SocketException while ifaces churn (hotspot).
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
            for (addr in addrs) {
                if (addr !is Inet4Address) continue
                if (addr.isLoopbackAddress) continue
                val host = addr.hostAddress ?: continue
                if (!isPrivateIpv4(host)) continue
                results.add(Endpoint(interfaceName = nif.name, address = host))
            }
        }
        // Prefer hotspot-like names first
        return results.sortedWith(
            compareBy<Endpoint> { hotspotScore(it.interfaceName) }
                .thenBy { it.address },
        )
    }

    private fun isExcludedInterface(name: String): Boolean {
        if (name == "lo" || name.startsWith("lo")) return true
        if (name.startsWith("tun") || name.startsWith("tap")) return true
        if (name.startsWith("wg") || name.startsWith("vpn")) return true
        // Common cellular interface name patterns — never listen here
        if (name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("pdp")) return true
        if (name.startsWith("wwan") || name.startsWith("mobile") || name.contains("cellular")) return true
        return false
    }

    private fun hotspotScore(name: String): Int {
        val n = name.lowercase()
        return when {
            n.startsWith("ap") || n.contains("swlan") || n.contains("softap") -> 0
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
            // Android USB tethering often 192.168.42.x / Wi‑Fi hotspot 192.168.43.x already covered
            o[0] == 169 && o[1] == 254 -> false // link-local — skip
            else -> false
        }
    }
}
