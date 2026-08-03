package com.nanako.socksbypass.core

import java.net.InetAddress

/**
 * Parse host strings as IP literals only — never triggers process-default DNS.
 *
 * [InetAddress.getByName] is intentionally unused: invalid "looks like IP" strings
 * (e.g. `999.1.2.3`, `evil:name`) can fall through to the system resolver on the
 * default network (often Wi‑Fi when tethering), bypassing cellular-bound DNS.
 */
object StrictIpLiteral {
    fun parse(host: String): InetAddress? {
        if (host.isEmpty()) return null
        parseIpv4(host)?.let { return it }
        parseIpv6(host)?.let { return it }
        return null
    }

    fun parseIpv4(host: String): InetAddress? {
        val parts = host.split('.')
        if (parts.size != 4) return null
        val octets = IntArray(4)
        for (i in 0..3) {
            val p = parts[i]
            if (p.isEmpty() || !p.all { it in '0'..'9' }) return null
            if (p.length > 1 && p[0] == '0') return null
            val n = p.toIntOrNull() ?: return null
            if (n !in 0..255) return null
            octets[i] = n
        }
        return InetAddress.getByAddress(
            byteArrayOf(
                octets[0].toByte(),
                octets[1].toByte(),
                octets[2].toByte(),
                octets[3].toByte(),
            ),
        )
    }

    /**
     * Strict IPv6 literal → 16 bytes via [InetAddress.getByAddress] only.
     * Supports compressed `::` and dotted IPv4 tail.
     */
    fun parseIpv6(host: String): InetAddress? {
        if (!host.contains(':')) return null
        if (host.contains('%')) return null
        if (!host.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' || it == ':' || it == '.' }) {
            return null
        }
        val bytes = expandIpv6(host) ?: return null
        return try {
            InetAddress.getByAddress(bytes)
        } catch (_: Exception) {
            null
        }
    }

    private fun expandIpv6(input: String): ByteArray? {
        var host = input
        var v4Bytes: ByteArray? = null
        val lastColon = host.lastIndexOf(':')
        if (lastColon >= 0 && host.indexOf('.', startIndex = lastColon) >= 0) {
            val v4 = host.substring(lastColon + 1)
            val a = parseIpv4(v4) ?: return null
            v4Bytes = a.address
            host = host.substring(0, lastColon + 1) // keep trailing colon for empty hextet handling
            // strip trailing colon so split works: "....:ffff:" + remove → better rebuild
            host = input.substring(0, lastColon)
        }

        val doubleIdx = host.indexOf("::")
        if (doubleIdx >= 0 && host.indexOf("::", doubleIdx + 1) >= 0) return null

        fun splitHextets(s: String): List<Int>? {
            if (s.isEmpty()) return emptyList()
            val parts = s.split(':')
            val out = ArrayList<Int>(parts.size)
            for (p in parts) {
                if (p.isEmpty() || p.length > 4) return null
                if (!p.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
                out.add(p.toInt(16))
            }
            return out
        }

        val hextets = ArrayList<Int>(8)
        if (doubleIdx >= 0) {
            val left = host.substring(0, doubleIdx)
            val right = host.substring(doubleIdx + 2)
            val head = splitHextets(left) ?: return null
            val tail = splitHextets(right) ?: return null
            val v4Slots = if (v4Bytes != null) 2 else 0
            val used = head.size + tail.size + v4Slots
            if (used > 8) return null
            hextets.addAll(head)
            repeat(8 - used) { hextets.add(0) }
            hextets.addAll(tail)
        } else {
            val all = splitHextets(host) ?: return null
            val v4Slots = if (v4Bytes != null) 2 else 0
            if (all.size + v4Slots != 8) return null
            hextets.addAll(all)
        }

        if (v4Bytes != null) {
            if (hextets.size != 6) return null
            hextets.add(((v4Bytes[0].toInt() and 0xff) shl 8) or (v4Bytes[1].toInt() and 0xff))
            hextets.add(((v4Bytes[2].toInt() and 0xff) shl 8) or (v4Bytes[3].toInt() and 0xff))
        }
        if (hextets.size != 8) return null

        val out = ByteArray(16)
        for (i in 0..7) {
            val h = hextets[i]
            if (h !in 0..0xffff) return null
            out[i * 2] = ((h shr 8) and 0xff).toByte()
            out[i * 2 + 1] = (h and 0xff).toByte()
        }
        return out
    }
}
