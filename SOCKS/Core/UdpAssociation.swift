import Foundation
import Darwin
import Network

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

        /// Host and port only. `matches` also compares sin6_scope_id and
        /// sin6_flowinfo, which recvfrom fills for a link-local source while a
        /// declared endpoint built from the control peer's address (scope
        /// stripped) has them zero, so the declared client would never match.
        func matchesHostAndPort(_ other: SocketAddress) -> Bool {
            matchesHost(other) && port == other.port
        }

        /// The 16 raw address bytes alone, port and everything else stripped —
        /// a stable key for host-only lookups.
        var hostBytes: Data {
            guard bytes.count >= 24 else { return Data() }
            return bytes[8..<24]
        }

        /// ::ffff:a.b.c.d, the form every IPv4 destination takes on the
        /// dual-stack socket.
        var isIPv4Mapped: Bool {
            let host = [UInt8](hostBytes)
            return host.count == 16 && host.prefix(10).allSatisfy { $0 == 0 }
                && host[10] == 0xff && host[11] == 0xff
        }
    }

    private enum Resolution {
        case pending
        case resolved([SocketAddress])
    }

    private let queue: DispatchQueue
    private let counters: TrafficCounters
    private let resolutionQueue: DispatchQueue
    private let onFailure: () -> Void
    private var socketFD: Int32
    private var source: DispatchSourceRead?
    private var closed = false
    /// Where peer traffic is delivered: the declared endpoint until something
    /// confirms or replaces it (see handleReadable).
    private var clientAddress: SocketAddress?
    private let controlPeer: SocketAddress?
    /// The endpoint the UDP ASSOCIATE request declared (control peer's host,
    /// request's port), if any. It stays authoritative for the whole association.
    private let declaredClient: SocketAddress?
    /// The declared endpoint has sent a well-formed datagram; from then on the
    /// association belongs to it and nothing else can latch.
    private var declaredConfirmed = false
    /// The one-shot discovery latch (first well-formed same-host sender) has been used.
    private var discoveryUsed = false
    private var resolutions: [String: Resolution] = [:]
    /// Insertion order, so the cache can be evicted without a second index.
    private var resolutionOrder: [String] = []
    /// Reverse of the above, ATYP IPv4 requests only: synthesized destination
    /// host bytes back to the literal the client actually addressed it as.
    /// Entries live exactly as long as the `ipv4:` resolution they came from
    /// (removed in forgetResolution), so the map is bounded by the cache.
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
    /// errno of the last failed sendto, captured right after the call.
    private var lastSendError: Int32 = 0
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
        declaredClient = declaredClientEndpoint.flatMap {
            Self.numericAddress($0.address, port: $0.port)
        }
        clientAddress = declaredClient
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
        // Role is decided by source address. The envelope is inspected only as a
        // precondition for *becoming* the client (rules 1 and 3), never to decide
        // whether a sender that is not the client is a peer.
        if let declaredClient, sourceAddress.matchesHostAndPort(declaredClient) {
            // Never peer traffic, even before it confirms: forwarding it as a peer
            // payload would hand it to whoever discovery latched. A datagram that
            // doesn't decode (FRAG != 0, malformed) is dropped, as for any client.
            guard declaredConfirmed || DatagramHeader.decode(packet) != nil else { return }
            // Rule 1: the declared endpoint wins whenever it actually sends, even
            // over an earlier discovery latch, so a correct declaration keeps the
            // guarantee that a same-host stranger never receives the client's
            // payload. Accepted residual: when the declaration is wrong, whoever
            // later owns that declared port can take the association back from the
            // discovered client. The proxy cannot tell that ordering apart from a
            // stranger latching first ahead of a correctly declared client, and
            // this direction is never weaker than honouring the declaration alone.
            if !declaredConfirmed {
                declaredConfirmed = true
                clientAddress = sourceAddress
            }
            handleClientDatagram(packet)
        } else if let clientAddress, sourceAddress.matches(clientAddress) {
            // Rule 2: the discovered client.
            handleClientDatagram(packet)
        } else if !declaredConfirmed, !discoveryUsed,
                  let controlPeer, sourceAddress.matchesHost(controlPeer),
                  DatagramHeader.decode(packet) != nil {
            // Rule 3, one-shot discovery: only the TCP control connection's host may
            // claim the association, and only with a well-formed envelope. Latching
            // the first arbitrary sender let any host that guessed the ephemeral
            // port take over and receive the real client's payload as peer traffic.
            // This also covers clients that declare a port they never send from
            // (seen with Shadowrocket): without it every datagram they send is
            // misfiled as a peer reply and never reaches upstream. With a correct
            // declaration, a same-host stranger that latches first holds the
            // association only until the declared client sends (rule 1) and never
            // receives that client's datagrams. With a wrong or missing declaration
            // a stranger that sends first takes the client role and receives the
            // real client's traffic as peer payload: the same race main has always
            // accepted for undeclared clients.
            discoveryUsed = true
            clientAddress = sourceAddress
            handleClientDatagram(packet)
        } else {
            // Rule 4: everything else is a peer payload, wrapped verbatim and sent
            // to the client (dropped while there is none). The only translation is
            // the source label for NAT64-synthesized replies to literal IPv4
            // destinations; see literalIPv4ByDestinationHost.
            handlePeerDatagram(packet, from: sourceAddress)
        }
    }

    private func handleClientDatagram(_ packet: Data) {
        assertQueue()
        guard !closed, let decoded = DatagramHeader.decode(packet) else { return }
        let address = decoded.header.address
        let port = decoded.header.port

        switch decoded.header.addressType {
        case .ipv6:
            guard let destination = Self.numericAddress(address, port: port) else { return }
            _ = send(decoded.payload, to: destination, direction: .upload)

        case .ipv4:
            // The ::ffff:-mapped send is the normal path and stays synchronous, so
            // dual-stack and IPv4 networks behave exactly as before. On an
            // IPv6-only network that send fails (no IPv4 route), and only then is
            // the literal put through getaddrinfo, which synthesizes a NAT64
            // address for it the same way it does for a hostname; inet_pton never
            // does. The key is prefixed so an ATYP-domain request for the same
            // dotted string keeps its own entry. Assumption, not measured here:
            // sendto to a mapped address fails synchronously on an IPv6-only
            // interface rather than succeeding and vanishing.
            let key = "ipv4:" + address
            if case .resolved(let destinations) = resolutions[key] {
                var routeFailed = false
                for destination in destinations {
                    if send(decoded.payload, to: destination.withPort(port), direction: .upload) { return }
                    if !Self.isLocalSendError(lastSendError) { routeFailed = true }
                }
                // Only local errors (full buffer, oversized datagram) say nothing
                // about the route: drop this datagram, keep the entry and its labels.
                guard routeFailed else { return }
                // A synthesized address has no route: the network changed under the
                // association. Drop the entry and its reply labels, try mapped.
                forgetResolution(key)
            }
            guard let mapped = Self.numericAddress(address, port: port) else { return }
            if send(decoded.payload, to: mapped, direction: .upload) { return }
            // Synthesis is only for a missing route to a global address: NAT64
            // doesn't translate LAN/special ranges, and a local error (buffer,
            // size, broadcast permission) would repeat for the synthesized address.
            guard !Self.isLocalSendError(lastSendError),
                  let ipv4 = IPv4Address(address), NetworkTCPRelay.isGlobalUnicast(ipv4) else { return }
            startResolution(key: key, host: address, payload: decoded.payload, port: port, literalIPv4: true)

        case .domain:
            let key = address.lowercased()
            if case .resolved(let destinations) = resolutions[key] {
                _ = sendToFirst(decoded.payload, destinations, port: port)
                return
            }
            startResolution(key: key, host: address, payload: decoded.payload, port: port, literalIPv4: false)
        }
    }

    /// sendto errors caused by this host (buffer, datagram size, broadcast
    /// permission) rather than by the absence of a route.
    private static func isLocalSendError(_ code: Int32) -> Bool {
        [EAGAIN, EWOULDBLOCK, ENOBUFS, EMSGSIZE, EACCES].contains(code)
    }

    private func sendToFirst(_ payload: Data, _ destinations: [SocketAddress], port: UInt16) -> Bool {
        destinations.contains { send(payload, to: $0.withPort(port), direction: .upload) }
    }

    private func startResolution(key: String, host: String, payload: Data, port: UInt16, literalIPv4: Bool) {
        assertQueue()
        guard resolutions[key] == nil, pendingResolutions < Self.pendingResolutionLimit else { return }
        pendingResolutions += 1
        resolutions[key] = .pending
        resolutionOrder.append(key)
        // The datagram that triggered the lookup used to be dropped, so every
        // unseen domain silently lost its first packet: one-shot protocols failed
        // outright and DNS ate a timeout before a retry could use the cache. One
        // datagram is held per in-flight lookup, which the concurrent-lookup cap
        // already bounds.
        pendingDatagrams[key] = (payload, port)
        evictResolutions()
        resolutionQueue.async { [weak self] in
            var result = Self.resolve(host)
            // For a literal the mapped address just failed; keep only what
            // getaddrinfo synthesized.
            if literalIPv4 { result.removeAll { $0.isIPv4Mapped } }
            self?.queue.async { [weak self] in
                guard let self, !self.closed else { return }
                self.pendingResolutions -= 1
                let queued = self.pendingDatagrams.removeValue(forKey: key)
                guard self.resolutions[key] != nil else { return }
                guard !result.isEmpty else {
                    // A transient resolver failure must not black-hole the name for
                    // the life of the association: an association can stay open
                    // indefinitely, so a cached failure outlives the outage that
                    // caused it. Dropping the entry lets the next datagram retry,
                    // and the concurrent-lookup cap still bounds the retries.
                    self.forgetResolution(key)
                    return
                }
                self.resolutions[key] = .resolved(result)
                if literalIPv4 {
                    for destination in result {
                        self.literalIPv4ByDestinationHost[destination.hostBytes] = host
                    }
                }
                if let queued {
                    _ = self.sendToFirst(queued.payload, result, port: queued.port)
                }
            }
        }
    }

    /// Removes a cache entry together with the reply labels derived from it, so
    /// literalIPv4ByDestinationHost never outlives its resolution.
    private func forgetResolution(_ key: String) {
        assertQueue()
        if case .resolved(let destinations) = resolutions[key], key.hasPrefix("ipv4:") {
            for destination in destinations {
                literalIPv4ByDestinationHost.removeValue(forKey: destination.hostBytes)
            }
        }
        resolutions.removeValue(forKey: key)
        resolutionOrder.removeAll { $0 == key }
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
            forgetResolution(key)
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
                let sent = Darwin.sendto(
                    socketFD,
                    dataPointer.baseAddress,
                    data.count,
                    0,
                    address.assumingMemoryBound(to: sockaddr.self),
                    destination.length
                )
                if sent < 0 { lastSendError = errno }
                return sent
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
        if address.isIPv4Mapped {
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
