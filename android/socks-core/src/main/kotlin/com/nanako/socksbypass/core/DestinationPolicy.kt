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
         * Blocks loopback, link-local, private, CGNAT, ULA, and other special-purpose
         * ranges (IETF reserved / documentation / benchmarking / Class E). Lab targets
         * use [ALLOW_ALL].
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
            // IPv4 site-local (10/8, 172.16/12, 192.168/16)
            if (addr.isSiteLocalAddress) return true
            when (addr) {
                is Inet4Address -> {
                    if (isBlockedSpecialIpv4(addr)) return true
                }
                is Inet6Address -> {
                    if (isBlockedSpecialIpv6(addr)) return true
                }
            }
            return false
        }

        /**
         * Special-purpose IPv4 (IANA special-purpose registry subset relevant to
         * unauthenticated proxy abuse / non-global routing).
         */
        private fun isBlockedSpecialIpv4(addr: Inet4Address): Boolean {
            val b = addr.address
            val o0 = b[0].toInt() and 0xff
            val o1 = b[1].toInt() and 0xff
            val o2 = b[2].toInt() and 0xff
            // 0.0.0.0/8 — "this" network (incl. 0.0.0.1)
            if (o0 == 0) return true
            // CGNAT / shared address space 100.64.0.0/10 (RFC 6598)
            if (o0 == 100 && o1 in 64..127) return true
            // IETF Protocol Assignments 192.0.0.0/24
            if (o0 == 192 && o1 == 0 && o2 == 0) return true
            // TEST-NET-1 192.0.2.0/24
            if (o0 == 192 && o1 == 0 && o2 == 2) return true
            // 6to4 relay anycast 192.88.99.0/24
            if (o0 == 192 && o1 == 88 && o2 == 99) return true
            // Benchmarking 198.18.0.0/15
            if (o0 == 198 && o1 in 18..19) return true
            // TEST-NET-2 198.51.100.0/24
            if (o0 == 198 && o1 == 51 && o2 == 100) return true
            // TEST-NET-3 203.0.113.0/24
            if (o0 == 203 && o1 == 0 && o2 == 113) return true
            // Class E / reserved 240.0.0.0/4 (incl. 240.0.0.1, 255.255.255.255)
            if (o0 >= 240) return true
            return false
        }

        private fun isBlockedSpecialIpv6(addr: Inet6Address): Boolean {
            val b = addr.address
            val z = 0.toByte()
            // Unique local addresses fc00::/7
            if ((b[0].toInt() and 0xfe) == 0xfc) return true
            // Documentation 2001:db8::/32
            if (b[0] == 0x20.toByte() && b[1] == 0x01.toByte() &&
                b[2] == 0x0d.toByte() && b[3] == 0xb8.toByte()
            ) {
                return true
            }
            // Benchmarking 2001:2::/48 (RFC 5180)
            if (b[0] == 0x20.toByte() && b[1] == 0x01.toByte() &&
                b[2] == z && b[3] == 0x02.toByte()
            ) {
                return true
            }
            // ORCHIDv2 2001:20::/28 (RFC 7343) — first 28 bits of 2001:0020::/28
            // 2001 has 16 bits; next 12 bits must be 0x002 → second hextet 0x0020–0x002f
            if (b[0] == 0x20.toByte() && b[1] == 0x01.toByte() &&
                b[2] == z && (b[3].toInt() and 0xf0) == 0x20
            ) {
                return true
            }
            // Well-known NAT64 64:ff9b::/96 and local-use NAT64 64:ff9b:1::/48 (RFC 8215)
            if (b[0] == z && b[1] == 0x64.toByte() &&
                b[2] == 0xff.toByte() && b[3] == 0x9b.toByte()
            ) {
                return true
            }
            // Discard-only 100::/64 (RFC 6666) — first 8 bytes 0100:0000:0000:0000
            if (b[0] == 0x01.toByte() && b[1] == z &&
                b[2] == z && b[3] == z && b[4] == z && b[5] == z && b[6] == z && b[7] == z
            ) {
                return true
            }
            // IPv4-mapped ::ffff:0:0/96 — re-apply IPv4 special-purpose rules.
            val isV4Mapped = b[0] == z && b[1] == z && b[2] == z &&
                b[3] == z && b[4] == z && b[5] == z &&
                b[6] == z && b[7] == z &&
                b[8] == z && b[9] == z &&
                b[10] == 0xff.toByte() && b[11] == 0xff.toByte()
            if (isV4Mapped) {
                val v4 = InetAddress.getByAddress(b.copyOfRange(12, 16)) as Inet4Address
                return isBlockedProductionDestination(v4)
            }
            return false
        }
    }
}

class DestinationDeniedException(message: String = "destination not allowed") :
    Exception(message)
