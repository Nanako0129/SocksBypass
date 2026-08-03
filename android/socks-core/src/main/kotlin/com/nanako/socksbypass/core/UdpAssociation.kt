package com.nanako.socksbypass.core

import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
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
    /** 0 = block until packet or socket close (preferred); >0 polls with timeout. */
    private val soTimeoutMs: Int = 0,
    private val destinationPolicy: DestinationPolicy = DestinationPolicy.PRODUCTION,
    private val onFailure: () -> Unit = {},
) {
    private val closed = AtomicBoolean(false)
    private val lanSocket: DatagramSocket
    private val upstreamSocket: DatagramSocket
    private val allowedUpstream = ConcurrentHashMap.newKeySet<String>()
    private val allowedOrder = ArrayDeque<String>()
    @Volatile
    private var clientEndpoint: InetSocketAddress? = null

    private val resolutionLock = Any()
    private val resolutions = HashMap<String, ResolutionState>()
    private val resolutionOrder = ArrayList<String>()
    private val pendingResolutions = AtomicInteger(0)
    private val pendingBytes = AtomicLong(0)

    private sealed interface ResolutionState {
        class Pending(
            val queue: ArrayDeque<PendingDatagram> = ArrayDeque(),
        ) : ResolutionState

        class Resolved(val addresses: List<InetAddress>) : ResolutionState
        data object Failed : ResolutionState
    }

    private data class PendingDatagram(val payload: ByteArray, val port: Int, val bytes: Int)

    val localPort: Int

    init {
        val lan = if (lanBindAddress != null) {
            DatagramSocket(InetSocketAddress(lanBindAddress, 0))
        } else {
            DatagramSocket(0)
        }
        lan.soTimeout = soTimeoutMs
        localPort = lan.localPort
        lanSocket = lan
        try {
            if (!upstream.isAvailable) {
                throw UpstreamUnavailableException()
            }
            upstreamSocket = upstream.createUdpSocket()
            upstreamSocket.soTimeout = soTimeoutMs
        } catch (e: Exception) {
            try {
                lan.close()
            } catch (_: Exception) {
            }
            throw e
        }
        if (declaredClientPort != null && declaredClientPort != 0) {
            clientEndpoint = InetSocketAddress(controlPeer, declaredClientPort)
        }
    }

    fun successReply(): ByteArray {
        val addr = lanSocket.localAddress?.address
            ?: lanBindAddress?.address
            ?: byteArrayOf(0, 0, 0, 0)
        val ip = if (addr.size == 4 || addr.size == 16) addr else byteArrayOf(0, 0, 0, 0)
        val atypFinal = if (ip.size == 16) 0x04 else 0x01
        return Socks5HandshakeParser.requestReply(
            0x00,
            Socks5HandshakeParser.Companion.BoundEndpoint(atypFinal, ip, localPort),
        )
    }

    fun start() {
        thread(name = "socks-udp-lan", isDaemon = true) { lanLoop() }
        thread(name = "socks-udp-up", isDaemon = true) { upstreamLoop() }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        closeSockets()
        releaseAllPendingBytes()
    }

    val isClosed: Boolean get() = closed.get()

    private fun closeSockets() {
        try {
            lanSocket.close()
        } catch (_: Exception) {
        }
        try {
            upstreamSocket.close()
        } catch (_: Exception) {
        }
    }

    /** Unexpected receive-loop death (cellular disconnect, socket error). */
    private fun failClosed() {
        if (!closed.compareAndSet(false, true)) return
        closeSockets()
        releaseAllPendingBytes()
        try {
            onFailure()
        } catch (_: Exception) {
        }
    }

    private fun lanLoop() {
        val buf = ByteArray(65_535)
        while (!closed.get()) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                lanSocket.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            } catch (_: Exception) {
                if (!closed.get()) {
                    failClosed()
                }
                return
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
                if (!closed.get()) {
                    failClosed()
                }
                return
            }
            val from = packet.socketAddress as? InetSocketAddress ?: continue
            val key = endpointKey(from)
            if (!allowedUpstream.contains(key)) {
                continue
            }
            val payload = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            val client = clientEndpoint ?: continue
            val wrapped = DatagramHeader.encode(
                addressType = if (from.address.address.size == 16) {
                    DatagramHeader.AddressType.Ipv6
                } else {
                    DatagramHeader.AddressType.Ipv4
                },
                address = from.address.hostAddress ?: continue,
                port = from.port,
                payload = payload,
            ) ?: continue
            try {
                lanSocket.send(DatagramPacket(wrapped, wrapped.size, client))
                counters.recordCommitted(payload.size, TrafficCounters.Direction.Download)
            } catch (_: Exception) {
                // ignore send errors; socket death handled on next receive
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
                return
            }
        } else {
            if (DatagramHeader.decode(data) == null) return
            clientEndpoint = from
        }

        val decoded = DatagramHeader.decode(data) ?: return
        when (decoded.header.addressType) {
            DatagramHeader.AddressType.Ipv4, DatagramHeader.AddressType.Ipv6 -> {
                val addr = StrictIpLiteral.parse(decoded.header.address) ?: return
                if (!destinationPolicy.isAllowed(addr)) return
                sendUpstream(decoded.payload, InetSocketAddress(addr, decoded.header.port))
            }
            DatagramHeader.AddressType.Domain -> {
                val key = decoded.header.address.lowercase()
                val host = decoded.header.address
                val startDns: Boolean
                val resolvedSnapshot: List<InetAddress>?
                synchronized(resolutionLock) {
                    when (val state = resolutions[key]) {
                        is ResolutionState.Resolved -> {
                            startDns = false
                            resolvedSnapshot = state.addresses
                        }
                        is ResolutionState.Failed -> {
                            startDns = false
                            resolvedSnapshot = null
                        }
                        is ResolutionState.Pending -> {
                            enqueuePendingLocked(state, decoded.payload, decoded.header.port)
                            startDns = false
                            resolvedSnapshot = null
                        }
                        null -> {
                            if (pendingResolutions.get() >= PENDING_RESOLUTION_LIMIT) {
                                startDns = false
                                resolvedSnapshot = null
                            } else {
                                val pending = ResolutionState.Pending()
                                resolutions[key] = pending
                                resolutionOrder.add(key)
                                pendingResolutions.incrementAndGet()
                                enqueuePendingLocked(pending, decoded.payload, decoded.header.port)
                                evictResolutionsLocked()
                                startDns = true
                                resolvedSnapshot = null
                            }
                        }
                    }
                }
                if (resolvedSnapshot != null) {
                    for (addr in resolvedSnapshot) {
                        if (!destinationPolicy.isAllowed(addr)) continue
                        if (sendUpstream(decoded.payload, InetSocketAddress(addr, decoded.header.port))) break
                    }
                    return
                }
                if (startDns) {
                    dnsExecutor.execute {
                        completeDns(key, host)
                    }
                }
            }
        }
    }

    private fun completeDns(key: String, host: String) {
        val result = try {
            if (!upstream.isAvailable) emptyList()
            else upstream.resolve(host)
        } catch (_: Exception) {
            emptyList()
        }
        if (closed.get()) {
            pendingResolutions.decrementAndGet()
            return
        }
        val toFlush: List<PendingDatagram>
        val addresses: List<InetAddress>
        synchronized(resolutionLock) {
            pendingResolutions.decrementAndGet()
            val current = resolutions[key]
            if (current !is ResolutionState.Pending) {
                return
            }
            if (result.isEmpty()) {
                toFlush = current.queue.toList()
                current.queue.clear()
                resolutions.remove(key)
                resolutionOrder.remove(key)
                addresses = emptyList()
            } else {
                toFlush = current.queue.toList()
                current.queue.clear()
                resolutions[key] = ResolutionState.Resolved(result)
                addresses = result
            }
            for (item in toFlush) {
                pendingBytes.addAndGet(-item.bytes.toLong())
                globalPendingBytes.addAndGet(-item.bytes.toLong())
            }
        }
        if (addresses.isEmpty()) return
        for (item in toFlush) {
            for (addr in addresses) {
                if (!destinationPolicy.isAllowed(addr)) continue
                if (sendUpstream(item.payload, InetSocketAddress(addr, item.port))) break
            }
        }
    }

    private fun enqueuePendingLocked(
        pending: ResolutionState.Pending,
        payload: ByteArray,
        port: Int,
    ) {
        val bytes = payload.size
        // Drop if association or global budget exceeded.
        if (pendingBytes.get() + bytes > PENDING_BYTES_PER_ASSOCIATION) return
        if (globalPendingBytes.get() + bytes > PENDING_BYTES_GLOBAL) return
        while (pending.queue.size >= PENDING_DATAGRAMS_PER_HOST && pending.queue.isNotEmpty()) {
            val old = pending.queue.removeFirst()
            pendingBytes.addAndGet(-old.bytes.toLong())
            globalPendingBytes.addAndGet(-old.bytes.toLong())
        }
        pending.queue.addLast(PendingDatagram(payload, port, bytes))
        pendingBytes.addAndGet(bytes.toLong())
        globalPendingBytes.addAndGet(bytes.toLong())
    }

    private fun releaseAllPendingBytes() {
        synchronized(resolutionLock) {
            for ((_, state) in resolutions) {
                if (state is ResolutionState.Pending) {
                    for (item in state.queue) {
                        pendingBytes.addAndGet(-item.bytes.toLong())
                        globalPendingBytes.addAndGet(-item.bytes.toLong())
                    }
                    state.queue.clear()
                }
            }
            resolutions.clear()
            resolutionOrder.clear()
        }
    }

    private fun sendUpstream(payload: ByteArray, dest: InetSocketAddress): Boolean {
        if (closed.get() || !upstream.isAvailable) return false
        if (!destinationPolicy.isAllowed(dest.address)) return false
        return try {
            rememberAllowed(endpointKey(dest))
            val packet = DatagramPacket(payload, payload.size, dest)
            upstreamSocket.send(packet)
            counters.recordCommitted(payload.size, TrafficCounters.Direction.Upload)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun rememberAllowed(key: String) {
        if (allowedUpstream.add(key)) {
            synchronized(allowedOrder) {
                allowedOrder.addLast(key)
                while (allowedOrder.size > ALLOWED_UPSTREAM_LIMIT) {
                    val old = allowedOrder.removeFirst()
                    allowedUpstream.remove(old)
                }
            }
        }
    }

    private fun matchesControlPeer(address: InetAddress): Boolean {
        return address.address.contentEquals(controlPeer.address)
    }

    private fun endpointKey(addr: InetSocketAddress): String =
        "${addr.address.hostAddress}:${addr.port}"

    private fun evictResolutionsLocked() {
        var index = 0
        while (resolutions.size > RESOLUTION_CACHE_LIMIT && index < resolutionOrder.size) {
            val key = resolutionOrder[index]
            if (resolutions[key] is ResolutionState.Pending) {
                index++
                continue
            }
            resolutions.remove(key)
            resolutionOrder.removeAt(index)
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
            val addressStart: Int
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
                    val ip = StrictIpLiteral.parse(address)?.address ?: return null
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
        const val PENDING_DATAGRAMS_PER_HOST = 8
        const val PENDING_BYTES_PER_ASSOCIATION = 512 * 1024
        const val PENDING_BYTES_GLOBAL = 8 * 1024 * 1024
        const val ALLOWED_UPSTREAM_LIMIT = 256

        private val globalPendingBytes = AtomicLong(0)

        private val dnsThreadFactory = ThreadFactory { r ->
            Thread(r, "socks-udp-dns").apply { isDaemon = true }
        }

        /** Shared DNS pool — avoids unbounded per-datagram threads. */
        internal val dnsExecutor: ExecutorService =
            Executors.newFixedThreadPool(4, dnsThreadFactory)
    }
}
