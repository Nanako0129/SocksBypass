import Foundation
import Darwin

/// The one UDP socket owned by a SOCKS5 UDP ASSOCIATE control connection.
///
/// All public methods are called on `queue`. DNS lookup is the only work that
/// leaves it; its completion is marshalled back before touching any state.
final class UdpAssociation {
    enum AssociationError: Error {
        case socket(Int32)
        case option(Int32)
        case bind(Int32)
        case address(Int32)
        case invalidLocalAddress
    }

    enum AddressType: Equatable {
        case ipv4
        case domain
        case ipv6
    }

    struct DatagramHeader: Equatable {
        let addressType: AddressType
        let address: String
        let port: UInt16

        static func decode(_ data: Data) -> DecodedDatagram? {
            guard data.count >= 4,
                  data[data.startIndex] == 0,
                  data[data.index(data.startIndex, offsetBy: 1)] == 0,
                  data[data.index(data.startIndex, offsetBy: 2)] == 0 else {
                return nil
            }

            let typeByte = data[data.index(data.startIndex, offsetBy: 3)]
            let type: AddressType
            let addressLength: Int
            switch typeByte {
            case 0x01:
                type = .ipv4
                addressLength = 4
            case 0x04:
                type = .ipv6
                addressLength = 16
            case 0x03:
                guard data.count >= 5 else { return nil }
                type = .domain
                addressLength = Int(data[data.index(data.startIndex, offsetBy: 4)])
                guard addressLength > 0 else { return nil }
            default:
                return nil
            }

            let addressStart = data.index(data.startIndex, offsetBy: type == .domain ? 5 : 4)
            let portStart = addressStart + addressLength
            guard portStart + 2 <= data.endIndex else { return nil }

            let addressBytes = data[addressStart..<portStart]
            let address: String
            switch type {
            case .ipv4:
                guard addressBytes.count == 4 else { return nil }
                address = addressBytes.map(String.init).joined(separator: ".")
            case .domain:
                guard let value = String(bytes: addressBytes, encoding: .utf8),
                      !value.isEmpty,
                      !value.utf8.contains(0) else {
                    return nil
                }
                address = value
            case .ipv6:
                guard addressBytes.count == 16 else { return nil }
                var value = in6_addr()
                _ = addressBytes.withUnsafeBytes { bytes in
                    memcpy(&value, bytes.baseAddress, MemoryLayout<in6_addr>.size)
                }
                var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard withUnsafePointer(to: &value, { pointer in
                    output.withUnsafeMutableBufferPointer { buffer in
                        Darwin.inet_ntop(AF_INET6, pointer, buffer.baseAddress, socklen_t(buffer.count))
                    }
                }) != nil else {
                    return nil
                }
                address = String(cString: output)
            }

            let port = UInt16(data[portStart]) << 8 | UInt16(data[portStart + 1])
            let payloadStart = portStart + 2
            return DecodedDatagram(
                header: DatagramHeader(addressType: type, address: address, port: port),
                payload: Data(data[payloadStart..<data.endIndex])
            )
        }

        static func encode(
            addressType: AddressType,
            address: String,
            port: UInt16,
            payload: Data = Data()
        ) -> Data? {
            var result = Data([0x00, 0x00, 0x00])
            switch addressType {
            case .ipv4:
                var value = in_addr()
                guard address.withCString({ Darwin.inet_pton(AF_INET, $0, &value) }) == 1 else {
                    return nil
                }
                result.append(0x01)
                result.append(Data(bytes: &value, count: MemoryLayout<in_addr>.size))
            case .domain:
                guard let value = address.data(using: .utf8),
                      !value.isEmpty,
                      value.count <= 255,
                      !value.contains(0) else {
                    return nil
                }
                result.append(0x03)
                result.append(UInt8(value.count))
                result.append(value)
            case .ipv6:
                var value = in6_addr()
                guard address.withCString({ Darwin.inet_pton(AF_INET6, $0, &value) }) == 1 else {
                    return nil
                }
                result.append(0x04)
                result.append(Data(bytes: &value, count: MemoryLayout<in6_addr>.size))
            }
            result.append(UInt8(port >> 8))
            result.append(UInt8(port & 0xff))
            result.append(payload)
            return result
        }
    }

    struct DecodedDatagram: Equatable {
        let header: DatagramHeader
        let payload: Data
    }

    let localPort: UInt16

    struct SocketAddress {
        let bytes: Data
        let length: socklen_t
        let family: sa_family_t

        var port: UInt16 {
            guard bytes.count >= 4 else { return 0 }
            return UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        }

        func withPort(_ port: UInt16) -> SocketAddress {
            guard bytes.count >= 4 else { return self }
            var bytes = bytes
            bytes[2] = UInt8(port >> 8)
            bytes[3] = UInt8(port & 0xff)
            return SocketAddress(bytes: bytes, length: length, family: family)
        }

        func matches(_ other: SocketAddress) -> Bool {
            guard family == other.family else { return false }
            return bytes == other.bytes
        }

        /// Compares the address without the port. Every address here is AF_INET6,
        /// so the 16 address bytes live at offset 8.
        func matchesHost(_ other: SocketAddress) -> Bool {
            guard family == other.family, bytes.count >= 24, other.bytes.count >= 24 else {
                return false
            }
            return bytes[8..<24] == other.bytes[8..<24]
        }

        /// The 16 raw address bytes alone, port and everything else stripped —
        /// a stable key for host-only lookups.
        var hostBytes: Data {
            guard bytes.count >= 24 else { return Data() }
            return bytes[8..<24]
        }
    }

    private enum Resolution {
        case pending
        case resolved([SocketAddress])
        case failed
    }

    private let queue: DispatchQueue
    private let counters: TrafficCounters
    private let resolutionQueue: DispatchQueue
    private let onFailure: () -> Void
    private var socketFD: Int32
    private var source: DispatchSourceRead?
    private var closed = false
    private var clientAddress: SocketAddress?
    private let controlPeer: SocketAddress?
    /// Whether a datagram has ever been confirmed on the current
    /// `clientAddress`. Gates the declared-endpoint correction below: once
    /// real traffic has used an endpoint, a mismatched sender goes back to
    /// being treated as peer traffic rather than re-latching.
    private var hasReceivedClientTraffic = false
    private var resolutions: [String: Resolution] = [:]
    /// Insertion order, so the cache can be evicted without a second index.
    private var resolutionOrder: [String] = []
    /// Reverse of the above, ATYP IPv4 requests only: resolved destination
    /// host bytes back to the literal the client actually addressed it as.
    ///
    /// A client that supplies a literal IPv4 target did its own resolution
    /// and expects replies to appear to come from exactly that literal. When
    /// the real send has to go out over a NAT64-synthesized address instead
    /// (an IPv6-only network, no route for the literal itself), a reply's
    /// source is that synthesized address, not the literal — reporting it
    /// as-is hands the client a SOCKS5 UDP header whose source doesn't match
    /// anything it dialed. A client tracking flows by that literal (seen on
    /// tun2socks: "symmetric NAT ... drop packet from [64:ff9b::...]")
    /// rejects the reply outright. This maps the observed source back to
    /// what the client actually asked for.
    private var literalIPv4ByDestinationHost: [Data: String] = [:]
    private var literalIPv4Order: [Data] = []
    private var pendingResolutions = 0
    /// At most one datagram per in-flight lookup, replayed once it resolves.
    private var pendingDatagrams: [String: (payload: Data, port: UInt16)] = [:]
    // The proxy answers without authentication and the control connection can be
    // held open indefinitely, so a client can stream unique hostnames faster than
    // a serial resolver drains them. Both the cache and the number of lookups in
    // flight are capped; over the limit a datagram is simply dropped, which UDP
    // already permits.
    private static let resolutionCacheLimit = 256
    private static let pendingResolutionLimit = 8

    init(
        queue: DispatchQueue,
        counters: TrafficCounters,
        localAddress: String,
        controlPeerAddress: String?,
        declaredClientEndpoint: (address: String, port: UInt16)? = nil,
        onFailure: @escaping () -> Void
    ) throws {
        self.queue = queue
        self.counters = counters
        self.onFailure = onFailure
        // RFC 1928 lets the client state the endpoint it will send from. Honouring
        // it closes the window where another process on the same host claims the
        // association by getting a well-formed datagram in first. An unspecified
        // endpoint still falls back to discovery.
        clientAddress = declaredClientEndpoint.flatMap {
            Self.numericAddress($0.address, port: $0.port)
        }
        controlPeer = controlPeerAddress.flatMap { Self.numericAddress($0, port: 0) }
        resolutionQueue = DispatchQueue(
            label: "com.nanako.socksbypass.benchmark.udp-dns",
            qos: .utility
        )

        let fd: Int32
        do {
            fd = try Self.makeSocket()
        } catch {
            throw error
        }
        socketFD = fd

        guard let localType = Self.numericAddressType(localAddress) else {
            Darwin.close(fd)
            socketFD = -1
            throw AssociationError.invalidLocalAddress
        }

        var bound = sockaddr_in6()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let getResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(fd, sockaddrPointer, &boundLength)
            }
        }
        guard getResult == 0 else {
            Darwin.close(fd)
            socketFD = -1
            throw AssociationError.address(errno)
        }
        localPort = UInt16(bigEndian: bound.sin6_port)

        guard Self.numericAddressType(localAddress) == localType,
              Self.reply(addressType: localType, address: localAddress, port: localPort) != nil else {
            Darwin.close(fd)
            socketFD = -1
            throw AssociationError.invalidLocalAddress
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source = readSource
        readSource.setEventHandler { [weak self] in
            self?.handleReadable()
        }
        readSource.setCancelHandler {}
        readSource.resume()
    }

    deinit {
        source?.cancel()
        if socketFD >= 0 {
            Darwin.close(socketFD)
        }
    }

    var isClosed: Bool {
        assertQueue()
        return closed
    }

    func replyData(localAddress: String) -> Data? {
        assertQueue()
        guard !closed, let type = Self.numericAddressType(localAddress) else { return nil }
        return Self.reply(addressType: type, address: localAddress, port: localPort)
    }

    func cancel() {
        assertQueue()
        guard !closed else { return }
        closed = true
        source?.setEventHandler {}
        source?.cancel()
        source = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func handleReadable() {
        assertQueue()
        guard !closed else { return }

        var data = [UInt8](repeating: 0, count: 65_535)
        let capacity = data.count
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = data.withUnsafeMutableBytes { dataPointer in
            withUnsafeMutablePointer(to: &storage) { storagePointer in
                storagePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.recvfrom(
                        socketFD,
                        dataPointer.baseAddress,
                        capacity,
                        0,
                        sockaddrPointer,
                        &length
                    )
                }
            }
        }

        guard count >= 0 else {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                onFailure()
            }
            return
        }

        let sourceAddress = Self.socketAddress(storage: storage, length: length)
        let packet = Data(data.prefix(Int(count)))
        if let clientAddress {
            if sourceAddress.matches(clientAddress) {
                handleClientDatagram(packet)
            } else if !hasReceivedClientTraffic,
                      let controlPeer, sourceAddress.matchesHost(controlPeer),
                      DatagramHeader.decode(packet) != nil {
                // The UDP ASSOCIATE request declared a port up front, but some
                // clients advertise a placeholder or a stale port rather than
                // 0.0.0.0:0 — nothing has actually confirmed that declaration
                // yet, so a well-formed datagram from the same host is far more
                // likely the real client correcting it than an attacker. Without
                // this, every datagram from that client is silently misfiled as
                // a "peer reply" forever: the client's own SOCKS5 UDP forever
                // gets echoed back to the wrong port and never reaches anything.
                // Once real traffic has used an endpoint this no longer applies,
                // matching the same same-host race the no-declaration path below
                // already accepts.
                self.clientAddress = sourceAddress
                handleClientDatagram(packet)
            } else {
                // There is intentionally no destination/NAT table. Every datagram
                // from a non-client source is a peer payload and is wrapped verbatim
                // with the address recvfrom reported. Never inspect its content to
                // decide the role of the sender.
                handlePeerDatagram(packet, from: sourceAddress)
            }
        } else {
            // Only the TCP control connection's peer may claim the association, and
            // only with a well-formed envelope. Latching the first arbitrary sender
            // let any host that guessed the ephemeral port take over the association
            // and receive the real client's payload as if it were peer traffic.
            guard let controlPeer, sourceAddress.matchesHost(controlPeer),
                  DatagramHeader.decode(packet) != nil else {
                return
            }
            clientAddress = sourceAddress
            handleClientDatagram(packet)
        }
    }

    private func handleClientDatagram(_ packet: Data) {
        assertQueue()
        guard !closed, let decoded = DatagramHeader.decode(packet) else { return }
        hasReceivedClientTraffic = true

        switch decoded.header.addressType {
        case .ipv6:
            guard let destination = Self.numericAddress(
                decoded.header.address,
                port: decoded.header.port
            ) else { return }
            _ = send(decoded.payload, to: destination, direction: .upload)

        case .ipv4, .domain:
            // inet_pton (used by the .ipv6 path above) never synthesizes a NAT64
            // address for an IPv4 literal; only getaddrinfo does, the same way it
            // does for a hostname. On an IPv6-only network that difference is the
            // whole story: numericAddress() would hand back an unroutable
            // ::ffff:-mapped address and every datagram to it silently vanishes.
            // Folding .ipv4 into the domain cache below gets it the same
            // getaddrinfo() call .domain already makes.
            let key = decoded.header.address.lowercased()
            switch resolutions[key] {
            case .resolved(let destinations):
                for destination in destinations {
                    if send(
                        decoded.payload,
                        to: destination.withPort(decoded.header.port),
                        direction: .upload
                    ) {
                        break
                    }
                }
            case .pending, .failed:
                return
            case nil:
                guard pendingResolutions < Self.pendingResolutionLimit else { return }
                pendingResolutions += 1
                resolutions[key] = .pending
                resolutionOrder.append(key)
                // The datagram that triggered the lookup used to be dropped, so
                // every unseen domain silently lost its first packet: one-shot
                // protocols failed outright and DNS ate a timeout before a retry
                // could use the cache. One datagram is held per in-flight lookup,
                // which the concurrent-lookup cap already bounds.
                pendingDatagrams[key] = (decoded.payload, decoded.header.port)
                evictResolutions()
                let host = decoded.header.address
                resolutionQueue.async { [weak self] in
                    let result = Self.resolve(host)
                    self?.queue.async { [weak self] in
                        guard let self, !self.closed else { return }
                        self.pendingResolutions -= 1
                        let queued = self.pendingDatagrams.removeValue(forKey: key)
                        guard self.resolutions[key] != nil else { return }
                        guard !result.isEmpty else {
                            // A transient resolver failure must not black-hole the
                            // name for the life of the association: an association
                            // can stay open indefinitely, so a cached failure
                            // outlives the outage that caused it. Dropping the
                            // entry lets the next datagram retry, and the
                            // concurrent-lookup cap still bounds the retries.
                            self.resolutions.removeValue(forKey: key)
                            self.resolutionOrder.removeAll { $0 == key }
                            return
                        }
                        self.resolutions[key] = .resolved(result)
                        if decoded.header.addressType == .ipv4 {
                            self.rememberLiteralIPv4(key, for: result)
                        }
                        guard let queued else { return }
                        for destination in result
                        where self.send(queued.payload, to: destination.withPort(queued.port),
                                        direction: .upload) {
                            break
                        }
                    }
                }
            }
        }
    }

    /// Drops the oldest settled entries once the cache is over its limit. Pending
    /// lookups are skipped rather than evicted so their completion still has an
    /// entry to write into; the separate in-flight cap bounds those.
    private func evictResolutions() {
        assertQueue()
        var index = 0
        while resolutions.count > Self.resolutionCacheLimit, index < resolutionOrder.count {
            let key = resolutionOrder[index]
            if case .pending = resolutions[key] {
                index += 1
                continue
            }
            resolutions.removeValue(forKey: key)
            resolutionOrder.remove(at: index)
        }
    }

    /// Records, for each resolved destination, the literal IPv4 the client
    /// addressed it as — so a reply arriving from a NAT64-synthesized address
    /// can still be reported to the client as the address it actually dialed.
    /// Bounded the same way the resolution cache is: this can only grow at
    /// the same rate `resolutions` does, since every entry here traces back
    /// to one ATYP IPv4 resolution.
    private func rememberLiteralIPv4(_ literal: String, for destinations: [SocketAddress]) {
        assertQueue()
        for destination in destinations {
            let hostKey = destination.hostBytes
            guard !hostKey.isEmpty, literalIPv4ByDestinationHost[hostKey] == nil else { continue }
            literalIPv4ByDestinationHost[hostKey] = literal
            literalIPv4Order.append(hostKey)
        }
        while literalIPv4ByDestinationHost.count > Self.resolutionCacheLimit, !literalIPv4Order.isEmpty {
            let oldest = literalIPv4Order.removeFirst()
            literalIPv4ByDestinationHost.removeValue(forKey: oldest)
        }
    }

    private func handlePeerDatagram(_ payload: Data, from sourceAddress: SocketAddress) {
        assertQueue()
        guard !closed, let clientAddress else { return }

        // If this peer is answering a literal IPv4 the client dialed, report it
        // back as that literal even though the real send went out over a
        // NAT64-synthesized address — see literalIPv4ByDestinationHost.
        let resolvedAddress: (AddressType, String)?
        if let literal = literalIPv4ByDestinationHost[sourceAddress.hostBytes] {
            resolvedAddress = (.ipv4, literal)
        } else {
            resolvedAddress = Self.headerAddress(sourceAddress)
        }

        guard let (addressType, address) = resolvedAddress,
              let packet = DatagramHeader.encode(
                addressType: addressType,
                address: address,
                port: sourceAddress.port,
                payload: payload
              ) else {
            return
        }
        _ = send(packet, to: clientAddress, direction: .download, committedBytes: payload.count)
    }

    private func send(
        _ data: Data,
        to destination: SocketAddress,
        direction: TrafficCounters.Direction,
        committedBytes: Int? = nil
    ) -> Bool {
        assertQueue()
        guard !closed, socketFD >= 0 else { return false }

        let count = data.withUnsafeBytes { dataPointer in
            destination.bytes.withUnsafeBytes { addressPointer in
                guard let address = addressPointer.baseAddress else { return -1 }
                return Darwin.sendto(
                    socketFD,
                    dataPointer.baseAddress,
                    data.count,
                    0,
                    address.assumingMemoryBound(to: sockaddr.self),
                    destination.length
                )
            }
        }
        guard count == data.count else { return false }
        counters.recordCommitted(committedBytes ?? data.count, direction: direction)
        return true
    }

    private func assertQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    private static func makeSocket() throws -> Int32 {
        let fd = Darwin.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw AssociationError.socket(errno) }

        var v6Only: Int32 = 0
        guard Darwin.setsockopt(
            fd,
            IPPROTO_IPV6,
            IPV6_V6ONLY,
            &v6Only,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw AssociationError.option(error)
        }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        address.sin6_addr = in6addr_any
        guard withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw AssociationError.bind(error)
        }

        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = errno
            Darwin.close(fd)
            throw AssociationError.option(error)
        }
        return fd
    }

    private static func socketAddress(storage: sockaddr_storage, length: socklen_t) -> SocketAddress {
        let safeLength = min(Int(length), MemoryLayout<sockaddr_storage>.size)
        var storage = storage
        let family = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0.pointee.sa_family }
        }
        return SocketAddress(
            bytes: Data(bytes: &storage, count: safeLength),
            length: socklen_t(safeLength),
            family: family
        )
    }

    /// Always produces an AF_INET6 address. The association socket is a single
    /// dual-stack AF_INET6 socket, and `sendto` on it rejects an AF_INET sockaddr
    /// with EAFNOSUPPORT, so IPv4 destinations must travel in IPv4-mapped form.
    /// `headerAddress` unwraps the mapping again, so reply ATYP stays 0x01.
    private static func numericAddress(_ address: String, port: UInt16) -> SocketAddress? {
        var value4 = in_addr()
        var text = address
        if address.withCString({ Darwin.inet_pton(AF_INET, $0, &value4) }) == 1 {
            text = "::ffff:" + address
        }

        var value6 = in6_addr()
        guard text.withCString({ Darwin.inet_pton(AF_INET6, $0, &value6) }) == 1 else {
            return nil
        }
        var sockaddr = sockaddr_in6()
        sockaddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sockaddr.sin6_family = sa_family_t(AF_INET6)
        sockaddr.sin6_port = port.bigEndian
        sockaddr.sin6_addr = value6
        return SocketAddress(
            bytes: Data(bytes: &sockaddr, count: MemoryLayout<sockaddr_in6>.size),
            length: socklen_t(MemoryLayout<sockaddr_in6>.size),
            family: sa_family_t(AF_INET6)
        )
    }

    private static func numericAddressType(_ address: String) -> AddressType? {
        guard let value = numericAddress(address, port: 0),
              let (type, _) = headerAddress(value) else { return nil }
        return type
    }

    private static func reply(addressType _: AddressType, address: String, port: UInt16) -> Data? {
        guard let value = numericAddress(address, port: port),
              let (canonicalType, canonicalAddress) = headerAddress(value),
              let encoded = DatagramHeader.encode(
            addressType: canonicalType,
            address: canonicalAddress,
            port: port
        ) else { return nil }
        var reply = Data([0x05, 0x00, 0x00])
        reply.append(contentsOf: encoded.dropFirst(3))
        return reply
    }

    /// Internal rather than private so the family invariant can be asserted:
    /// every result must be AF_INET6, since the association socket rejects an
    /// AF_INET sockaddr with EAFNOSUPPORT.
    static func resolve(_ host: String) -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString {
            Darwin.getaddrinfo($0, nil, &hints, &result)
        }
        guard status == 0, let first = result else { return [] }
        defer { Darwin.freeaddrinfo(first) }

        var addresses: [SocketAddress] = []
        var item: UnsafeMutablePointer<addrinfo>? = first
        while let current = item {
            let info = current.pointee
            if let rawAddress = info.ai_addr,
               (info.ai_family == AF_INET || info.ai_family == AF_INET6) {
                let length = min(Int(info.ai_addrlen), MemoryLayout<sockaddr_storage>.size)
                let bytes = Data(bytes: rawAddress, count: length)
                var address = SocketAddress(
                    bytes: bytes,
                    length: socklen_t(length),
                    family: sa_family_t(info.ai_family)
                )
                // sendto on the dual-stack AF_INET6 socket rejects an AF_INET
                // sockaddr with EAFNOSUPPORT, so an A-only name would resolve
                // successfully and then silently drop every datagram.
                // sendto on the dual-stack AF_INET6 socket rejects an AF_INET
                // sockaddr with EAFNOSUPPORT, so an A-only name would resolve
                // successfully and then silently drop every datagram.
                if info.ai_family == AF_INET,
                   let (_, dotted) = headerAddress(address),
                   let mapped = numericAddress(dotted, port: 0) {
                    address = mapped
                }
                if !addresses.contains(where: { $0.bytes == address.bytes }) {
                    addresses.append(address)
                }
            }
            item = info.ai_next
        }
        return addresses
    }

    private static func headerAddress(_ address: SocketAddress) -> (AddressType, String)? {
        let raw = [UInt8](address.bytes)
        if address.family == sa_family_t(AF_INET), raw.count >= 8 {
            return (.ipv4, raw[4..<8].map(String.init).joined(separator: "."))
        }
        guard address.family == sa_family_t(AF_INET6), raw.count >= 24 else { return nil }
        let value = Array(raw[8..<24])
        let isMapped = value.prefix(10).allSatisfy { $0 == 0 } && value[10] == 0xff && value[11] == 0xff
        if isMapped {
            return (.ipv4, value.suffix(4).map(String.init).joined(separator: "."))
        }
        let text = value.enumerated().reduce(into: "") { result, item in
            let (index, byte) = item
            if index > 0, index.isMultiple(of: 2) { result.append(":") }
            result += String(format: "%02x", byte)
        }
        return (.ipv6, text)
    }
}
