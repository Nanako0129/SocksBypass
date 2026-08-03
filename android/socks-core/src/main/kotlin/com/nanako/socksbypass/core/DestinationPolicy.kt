package com.nanako.socksbypass.core

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/**
 * Filters upstream destinations for CONNECT / UDP ASSOCIATE.
 * Production refuses destinations that would not (or must not) leave the phone
 * via public Internet, and that turn NO AUTH into a LAN / carrier-side scanner.
 */
fun interface DestinationPolicy {
    fun isAllowed(address: InetAddress): Boolean

    companion object {
        /**
         * Default for the app: only globally routable unicast.
         * Rejects loopback, link-local, unspecified, multicast, RFC1918 site-local,
         * CGNAT (100.64/10), and IPv6 ULA (fc00::/7). Lab targets use [ALLOW_ALL].
         */
        val PRODUCTION: DestinationPolicy = DestinationPolicy { addr ->
            !isBlockedProductionDestination(addr)
        }

        /** Unit-test harness only — never wire into the Android app. */
        val ALLOW_ALL: DestinationPolicy = DestinationPolicy { true }

        fun isBlockedProductionDestination(addr: InetAddress): Boolean {
            if (addr.isLoopbackAddress ||
                addr.isLinkLocalAddress ||
                addr.isAnyLocalAddress ||
                addr.isMulticastAddress
            ) {
                return true
            }
            // IPv4 site-local (10/8, 172.16/12, 192.168/16) + some stacks' site-local flag
            if (addr.isSiteLocalAddress) return true
            when (addr) {
                is Inet4Address -> {
                    val b = addr.address
                    val o0 = b[0].toInt() and 0xff
                    val o1 = b[1].toInt() and 0xff
                    // CGNAT / shared address space (RFC 6598)
                    if (o0 == 100 && o1 in 64..127) return true
                }
                is Inet6Address -> {
                    val b = addr.address
                    // Unique local addresses fc00::/7
                    if ((b[0].toInt() and 0xfe) == 0xfc) return true
                }
            }
            return false
        }
    }
}

class DestinationDeniedException(message: String = "destination not allowed") :
    Exception(message)
