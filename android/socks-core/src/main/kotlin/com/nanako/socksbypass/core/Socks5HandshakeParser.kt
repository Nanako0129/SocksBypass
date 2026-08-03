package com.nanako.socksbypass.core

/**
 * Incremental SOCKS5 handshake parser (NO AUTH, CONNECT, UDP ASSOCIATE).
 * Parity with the Swift Socks5HandshakeParser.
 */
class Socks5HandshakeParser {
    data class Target(val address: String, val port: Int)

    enum class Command { Connect, UdpAssociate }

    data class Request(
        val command: Command,
        val target: Target,
        val firstPayload: ByteArray,
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (other !is Request) return false
            return command == other.command &&
                target == other.target &&
                firstPayload.contentEquals(other.firstPayload)
        }

        override fun hashCode(): Int {
            var result = command.hashCode()
            result = 31 * result + target.hashCode()
            result = 31 * result + firstPayload.contentHashCode()
            return result
        }
    }

    data class Output(
        val replies: MutableList<ByteArray> = mutableListOf(),
        var request: Request? = null,
        var shouldClose: Boolean = false,
    )

    private enum class AddressKind { Ipv4, Ipv6, Domain }

    private sealed class Phase {
        data object GreetingHeader : Phase()
        data class GreetingMethods(val count: Int) : Phase()
        data object RequestHeader : Phase()
        data object RequestDomainLength : Phase()
        data class RequestAddress(val kind: AddressKind, val required: Int) : Phase()
        data object Active : Phase()
        data object Closed : Phase()
    }

    private var phase: Phase = Phase.GreetingHeader
    private var pendingCommand: Command = Command.Connect
    private val buffer = ArrayList<Byte>(64)

    val isActive: Boolean get() = phase is Phase.Active
    val isClosed: Boolean get() = phase is Phase.Closed
    val bufferedByteCount: Int get() = buffer.size

    fun feed(data: ByteArray): Output {
        if (data.size > MAXIMUM_FEED_BYTES) {
            return closeForOversizedFeed()
        }
        if (data.isEmpty() || isClosed) return Output()

        val output = Output()
        var offset = 0

        while (offset < data.size && !output.shouldClose && output.request == null) {
            when (val current = phase) {
                is Phase.GreetingHeader -> {
                    if (!appendNeeded(2, data, offsetRef = { offset }, setOffset = { offset = it })) break
                    val version = u8(buffer[0])
                    val methodCount = u8(buffer[1])
                    buffer.clear()
                    if (version != 0x05 || methodCount <= 0) {
                        output.replies.add(byteArrayOf(0x05, 0xFF.toByte()))
                        close(output)
                        continue
                    }
                    phase = Phase.GreetingMethods(methodCount)
                }

                is Phase.GreetingMethods -> {
                    if (!appendNeeded(current.count, data, offsetRef = { offset }, setOffset = { offset = it })) break
                    val supportsNoAuth = buffer.any { u8(it) == 0x00 }
                    buffer.clear()
                    if (!supportsNoAuth) {
                        output.replies.add(byteArrayOf(0x05, 0xFF.toByte()))
                        close(output)
                        continue
                    }
                    output.replies.add(byteArrayOf(0x05, 0x00))
                    phase = Phase.RequestHeader
                }

                is Phase.RequestHeader -> {
                    if (!appendNeeded(4, data, offsetRef = { offset }, setOffset = { offset = it })) break
                    val bytes = buffer.map { u8(it) }
                    buffer.clear()
                    val reply: Int? = when {
                        bytes[0] != 0x05 -> 0x01
                        bytes[2] != 0x00 -> 0x01
                        bytes[1] != 0x01 && bytes[1] != 0x03 -> 0x07
                        else -> null
                    }
                    val command = if (bytes[1] == 0x03) Command.UdpAssociate else Command.Connect
                    if (reply != null) {
                        output.replies.add(requestReply(reply))
                        close(output)
                    } else {
                        pendingCommand = command
                        when (bytes[3]) {
                            0x01 -> phase = Phase.RequestAddress(AddressKind.Ipv4, 6)
                            0x04 -> phase = Phase.RequestAddress(AddressKind.Ipv6, 18)
                            0x03 -> phase = Phase.RequestDomainLength
                            else -> {
                                output.replies.add(requestReply(0x08))
                                close(output)
                            }
                        }
                    }
                }

                is Phase.RequestDomainLength -> {
                    if (!appendNeeded(1, data, offsetRef = { offset }, setOffset = { offset = it })) break
                    val length = u8(buffer[0])
                    buffer.clear()
                    if (length <= 0) {
                        output.replies.add(requestReply(0x01))
                        close(output)
                        continue
                    }
                    phase = Phase.RequestAddress(AddressKind.Domain, length + 2)
                }

                is Phase.RequestAddress -> {
                    if (!appendNeeded(current.required, data, offsetRef = { offset }, setOffset = { offset = it })) break
                    val bytes = buffer.map { u8(it) }
                    buffer.clear()
                    val addressPart = bytes.subList(0, current.required - 2)
                    val address = decodeAddress(current.kind, addressPart)
                    val port = (bytes[current.required - 2] shl 8) or bytes[current.required - 1]
                    val payload = if (offset < data.size) data.copyOfRange(offset, data.size) else ByteArray(0)
                    offset = data.size
                    phase = Phase.Active
                    output.request = Request(
                        command = pendingCommand,
                        target = Target(address = address, port = port),
                        firstPayload = payload,
                    )
                }

                is Phase.Active, is Phase.Closed -> {
                    offset = data.size
                }
            }
        }
        return output
    }

    fun finish(): Output {
        if (isClosed || isActive) return Output()
        buffer.clear()
        phase = Phase.Closed
        return Output(shouldClose = true)
    }

    private fun appendNeeded(
        requiredCount: Int,
        data: ByteArray,
        offsetRef: () -> Int,
        setOffset: (Int) -> Unit,
    ): Boolean {
        val needed = requiredCount - buffer.size
        if (needed <= 0) return true
        val offset = offsetRef()
        val available = data.size - offset
        val count = minOf(needed, available)
        if (count <= 0) return false
        for (i in 0 until count) {
            buffer.add(data[offset + i])
        }
        setOffset(offset + count)
        return buffer.size == requiredCount
    }

    private fun close(output: Output) {
        buffer.clear()
        phase = Phase.Closed
        output.shouldClose = true
    }

    private fun closeForOversizedFeed(): Output {
        val output = Output()
        when (phase) {
            is Phase.GreetingHeader, is Phase.GreetingMethods ->
                output.replies.add(byteArrayOf(0x05, 0xFF.toByte()))
            is Phase.RequestHeader, is Phase.RequestDomainLength, is Phase.RequestAddress ->
                output.replies.add(requestReply(0x01))
            else -> Unit
        }
        close(output)
        return output
    }

    companion object {
        const val MAXIMUM_FEED_BYTES = 64 * 1024

        fun requestReply(reply: Int): ByteArray =
            byteArrayOf(0x05, reply.toByte(), 0x00, 0x01, 0, 0, 0, 0, 0, 0)

        data class BoundEndpoint(
            val atyp: Int,
            val address: ByteArray,
            val port: Int,
        )

        fun requestReply(reply: Int, bound: BoundEndpoint?): ByteArray {
            if (bound == null) return requestReply(reply)
            val expected = if (bound.atyp == 0x01) 4 else 16
            if (bound.address.size != expected) return requestReply(reply)
            val out = ByteArray(4 + bound.address.size + 2)
            out[0] = 0x05
            out[1] = reply.toByte()
            out[2] = 0x00
            out[3] = bound.atyp.toByte()
            System.arraycopy(bound.address, 0, out, 4, bound.address.size)
            val portIndex = 4 + bound.address.size
            out[portIndex] = ((bound.port shr 8) and 0xFF).toByte()
            out[portIndex + 1] = (bound.port and 0xFF).toByte()
            return out
        }

        private fun u8(b: Byte): Int = b.toInt() and 0xFF

        private fun decodeAddress(kind: AddressKind, bytes: List<Int>): String = when (kind) {
            AddressKind.Ipv4 -> bytes.joinToString(".") { it.toString() }
            AddressKind.Ipv6 -> bytes.chunked(2).joinToString(":") { pair ->
                String.format("%02x%02x", pair[0], pair[1])
            }
            AddressKind.Domain -> String(bytes.map { it.toByte() }.toByteArray(), Charsets.UTF_8)
        }
    }

    private fun u8(b: Byte): Int = b.toInt() and 0xFF

    private fun decodeAddress(kind: AddressKind, bytes: List<Int>): String =
        Companion.decodeAddress(kind, bytes)
}
