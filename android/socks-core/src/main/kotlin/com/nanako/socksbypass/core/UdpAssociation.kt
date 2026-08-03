package com.nanako.socksbypass.core

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketAddress
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * Dual-socket UDP ASSOCIATE:
 * - LAN-facing socket accepts SOCKS UDP from the control TCP peer
 * - Cellular-bound socket (via [UpstreamNetwork]) sends/receives upstream
 *
 * Security: client IP must match control peer; declared host is not trusted
 * for latching; only previously contacted upstream endpoints may reply.
 */
class UdpAssociation(
    private val controlPeer: InetAddress,
    private val declaredClientPort: Int?,
    private val lanBindAddress: InetAddress?,
    private val upstream: UpstreamNetwork,
    private val counters: TrafficCounters,
    private val soTimeoutMs: Int = 500,
) {
    private val closed = AtomicBoolean(false)
    private val lanSocket: DatagramSocket
    private val upstreamSocket: DatagramSocket
    private val allowedUpstream = ConcurrentHashMap.newKeySet<String>()
    @Volatile
    private var clientEndpoint: InetSocketAddress? = null

    private enum class Resolution { Pending, Failed }
    private val resolutions = ConcurrentHashMap<String, Any>() // Resolved list or Pending/Failed
    private val resolutionOrder = ArrayList<String>()
    private val pendingResolutions = AtomicInteger(0)
    private val pendingDatagrams = ConcurrentHashMap<String, Pair<ByteArray, Int>>()

    val localPort: Int

    init {
        lanSocket = if (lanBindAddress != null) {
            DatagramSocket(InetSocketAddress(lanBindAddress, 0))
        } else {
            DatagramSocket(0)
        }
        lanSocket.soTimeout = soTimeoutMs
        localPort = lanSocket.localPort
        if (!upstream.isAvailable) {
            lanSocket.close()
            throw UpstreamUnavailableException()
        }
        upstreamSocket = upstream.createUdpSocket()
        upstreamSocket.soTimeout = soTimeoutMs
        if (declaredClientPort != null && declaredClientPort != 0) {
            clientEndpoint = InetSocketAddress(controlPeer, declaredClientPort)
        }
    }

    fun successReply(): ByteArray {
        val addr = lanSocket.localAddress?.address
            ?: lanBindAddress?.address
            ?: byteArrayOf(0, 0, 0, 0)
        val atyp = if (addr.size == 16) 0x04 else 0x01
        val ip = if (addr.size == 4 || addr.size == 16) addr else byteArrayOf(0, 0, 0, 0)
        val atypFinal = if (ip.size == 16) 0x04 else 0x01
        return Socks5HandshakeParser.requestReply(
            0x00,
            Socks5HandshakeParser.Companion.BoundEndpoint(atypFinal, if (ip.size == 4 || ip.size == 16) ip else byteArrayOf(0, 0, 0, 0), localPort),
        )
    }

    fun start() {
        thread(name = "socks-udp-lan", isDaemon = true) { lanLoop() }
        thread(name = "socks-udp-up", isDaemon = true) { upstreamLoop() }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        try {
            lanSocket.close()
        } catch (_: Exception) {
        }
        try {
            upstreamSocket.close()
        } catch (_: Exception) {
        }
    }

    val isClosed: Boolean get() = closed.get()

    private fun lanLoop() {
        val buf = ByteArray(65_535)
        while (!closed.get()) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                lanSocket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                if (!closed.get()) break
                break
            }
            val from = packet.socketAddress as? InetSocketAddress ?: continue
            val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            handleLanDatagram(from, data)
        }
    }

    private fun upstreamLoop() {
        val buf = ByteArray(65_535)
        while (!closed.get()) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                upstreamSocket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                break
            }
            val from = packet.socketAddress as? InetSocketAddress ?: continue
            val key = endpointKey(from)
            if (!allowedUpstream.contains(key)) {
                // Drop: not in response allowlist (anti-reflector / spoof)
                continue
            }
            val payload = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            val client = clientEndpoint ?: continue
            val wrapped = DatagramHeader.encode(
                addressType = if (from.address.address.size == 16) DatagramHeader.AddressType.Ipv6 else DatagramHeader.AddressType.Ipv4,
                address = from.address.hostAddress ?: continue,
                port = from.port,
                payload = payload,
            ) ?: continue
            try {
                lanSocket.send(DatagramPacket(wrapped, wrapped.size, client))
                counters.recordCommitted(payload.size, TrafficCounters.Direction.Download)
            } catch (_: Exception) {
                // ignore
            }
        }
    }

    private fun handleLanDatagram(from: InetSocketAddress, data: ByteArray) {
        if (!matchesControlPeer(from.address)) {
            return
        }
        val existing = clientEndpoint
        if (existing != null) {
            if (existing.address != from.address || existing.port != from.port) {
                // Second source rejected once latched
                return
            }
        } else {
            // Only control peer host may claim; require well-formed envelope
            if (DatagramHeader.decode(data) == null) return
            clientEndpoint = from
        }

        val decoded = DatagramHeader.decode(data) ?: return
        when (decoded.header.addressType) {
            DatagramHeader.AddressType.Ipv4, DatagramHeader.AddressType.Ipv6 -> {
                val dest = try {
                    InetSocketAddress(InetAddress.getByName(decoded.header.address), decoded.header.port)
                } catch (_: Exception) {
                    return
                }
                sendUpstream(decoded.payload, dest)
            }
            DatagramHeader.AddressType.Domain -> {
                val key = decoded.header.address.lowercase()
                when (val state = resolutions[key]) {
                    is List<*> -> {
                        @Suppress("UNCHECKED_CAST")
                        val addrs = state as List<InetAddress>
                        for (addr in addrs) {
                            if (sendUpstream(decoded.payload, InetSocketAddress(addr, decoded.header.port))) break
                        }
                    }
                    Resolution.Pending, Resolution.Failed -> return
                    null -> {
                        if (pendingResolutions.get() >= PENDING_RESOLUTION_LIMIT) return
                        pendingResolutions.incrementAndGet()
                        resolutions[key] = Resolution.Pending
                        synchronized(resolutionOrder) { resolutionOrder.add(key) }
                        pendingDatagrams[key] = decoded.payload to decoded.header.port
                        evictResolutions()
                        thread(name = "socks-udp-dns", isDaemon = true) {
                            val result = try {
                                if (!upstream.isAvailable) emptyList()
                                else upstream.resolve(decoded.header.address)
                            } catch (_: Exception) {
                                emptyList()
                            }
                            if (closed.get()) return@thread
                            pendingResolutions.decrementAndGet()
                            val queued = pendingDatagrams.remove(key)
                            if (result.isEmpty()) {
                                resolutions.remove(key)
                                synchronized(resolutionOrder) { resolutionOrder.remove(key) }
                                return@thread
                            }
                            resolutions[key] = result
                            if (queued != null) {
                                for (addr in result) {
                                    if (sendUpstream(queued.first, InetSocketAddress(addr, queued.second))) break
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private fun sendUpstream(payload: ByteArray, dest: InetSocketAddress): Boolean {
        if (closed.get() || !upstream.isAvailable) return false
        return try {
            allowedUpstream.add(endpointKey(dest))
            val packet = DatagramPacket(payload, payload.size, dest)
            upstreamSocket.send(packet)
            counters.recordCommitted(payload.size, TrafficCounters.Direction.Upload)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun matchesControlPeer(address: InetAddress): Boolean {
        return address.address.contentEquals(controlPeer.address)
    }

    private fun endpointKey(addr: InetSocketAddress): String =
        "${addr.address.hostAddress}:${addr.port}"

    private fun evictResolutions() {
        synchronized(resolutionOrder) {
            var index = 0
            while (resolutions.size > RESOLUTION_CACHE_LIMIT && index < resolutionOrder.size) {
                val key = resolutionOrder[index]
                if (resolutions[key] == Resolution.Pending) {
                    index++
                    continue
                }
                resolutions.remove(key)
                resolutionOrder.removeAt(index)
            }
        }
    }

    object DatagramHeader {
        enum class AddressType { Ipv4, Domain, Ipv6 }

        data class Header(val addressType: AddressType, val address: String, val port: Int)
        data class Decoded(val header: Header, val payload: ByteArray)

        fun decode(data: ByteArray): Decoded? {
            if (data.size < 4) return null
            if (data[0] != 0.toByte() || data[1] != 0.toByte() || data[2] != 0.toByte()) return null
            val typeByte = data[3].toInt() and 0xFF
            val type: AddressType
            val addressLength: Int
            var addressStart: Int
            when (typeByte) {
                0x01 -> {
                    type = AddressType.Ipv4
                    addressLength = 4
                    addressStart = 4
                }
                0x04 -> {
                    type = AddressType.Ipv6
                    addressLength = 16
                    addressStart = 4
                }
                0x03 -> {
                    if (data.size < 5) return null
                    type = AddressType.Domain
                    addressLength = data[4].toInt() and 0xFF
                    if (addressLength <= 0) return null
                    addressStart = 5
                }
                else -> return null
            }
            val portStart = addressStart + addressLength
            if (portStart + 2 > data.size) return null
            val addressBytes = data.copyOfRange(addressStart, portStart)
            val address = when (type) {
                AddressType.Ipv4 -> addressBytes.joinToString(".") { (it.toInt() and 0xFF).toString() }
                AddressType.Domain -> {
                    val s = String(addressBytes, Charsets.UTF_8)
                    if (s.isEmpty() || addressBytes.contains(0)) return null
                    s
                }
                AddressType.Ipv6 -> {
                    try {
                        InetAddress.getByAddress(addressBytes).hostAddress ?: return null
                    } catch (_: Exception) {
                        return null
                    }
                }
            }
            val port = ((data[portStart].toInt() and 0xFF) shl 8) or (data[portStart + 1].toInt() and 0xFF)
            val payload = data.copyOfRange(portStart + 2, data.size)
            return Decoded(Header(type, address, port), payload)
        }

        fun encode(
            addressType: AddressType,
            address: String,
            port: Int,
            payload: ByteArray = ByteArray(0),
        ): ByteArray? {
            val header = when (addressType) {
                AddressType.Ipv4 -> {
                    val parts = address.split('.')
                    if (parts.size != 4) return null
                    val ip = ByteArray(4) { parts[it].toInt().toByte() }
                    byteArrayOf(0, 0, 0, 0x01) + ip
                }
                AddressType.Domain -> {
                    val bytes = address.toByteArray(Charsets.UTF_8)
                    if (bytes.isEmpty() || bytes.size > 255 || bytes.contains(0)) return null
                    byteArrayOf(0, 0, 0, 0x03, bytes.size.toByte()) + bytes
                }
                AddressType.Ipv6 -> {
                    val ip = try {
                        InetAddress.getByName(address).address
                    } catch (_: Exception) {
                        return null
                    }
                    if (ip.size != 16) return null
                    byteArrayOf(0, 0, 0, 0x04) + ip
                }
            }
            val portBytes = byteArrayOf(((port shr 8) and 0xFF).toByte(), (port and 0xFF).toByte())
            return header + portBytes + payload
        }
    }

    companion object {
        const val RESOLUTION_CACHE_LIMIT = 256
        const val PENDING_RESOLUTION_LIMIT = 8
    }
}
