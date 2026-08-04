import Darwin
import Foundation
import Network
import XCTest

final class UdpAssociationTests: XCTestCase {
    func testDatagramHeaderRoundTripsAllAddressTypes() throws {
        let cases: [(UdpAssociation.AddressType, String, UInt16)] = [
            (.ipv4, "127.0.0.1", 4001),
            (.domain, "localhost", 4002),
            (.ipv6, "2001:db8::1", 4003)
        ]

        for (type, address, port) in cases {
            let payload = Data([0x11, 0x22, 0x33])
            let encoded = try XCTUnwrap(
                UdpAssociation.DatagramHeader.encode(
                    addressType: type,
                    address: address,
                    port: port,
                    payload: payload
                )
            )
            let decoded = try XCTUnwrap(UdpAssociation.DatagramHeader.decode(encoded))
            XCTAssertEqual(decoded.header.addressType, type)
            XCTAssertEqual(decoded.header.address, address)
            XCTAssertEqual(decoded.header.port, port)
            XCTAssertEqual(decoded.payload, payload)
        }
    }

    func testNonZeroFragmentIsDropped() {
        let packet = Data([0, 0, 1, 1, 127, 0, 0, 1, 0, 53, 0xaa])
        XCTAssertNil(UdpAssociation.DatagramHeader.decode(packet))
    }

    func testPeerEnvelopePayloadIsWrappedVerbatim() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.peerEnvelope")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let peer = try UdpTestSocket(family: AF_INET)
        let client = try UdpTestSocket(family: AF_INET)
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "127.0.0.1",
                onFailure: {}
            )
        }
        defer {
            queue.sync { association.cancel() }
        }

        let innerEnvelope = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .ipv4,
                address: "192.0.2.1",
                port: 8080,
                payload: Data([0xde, 0xad, 0xbe, 0xef])
            )
        )
        let request = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .ipv4,
                address: "127.0.0.1",
                port: peer.port,
                payload: innerEnvelope
            )
        )

        XCTAssertTrue(client.send(request, host: "127.0.0.1", port: association.localPort))
        let echoed = try XCTUnwrap(peer.receiveAndEcho())
        XCTAssertEqual(echoed, innerEnvelope)

        let response = try XCTUnwrap(client.receive())
        let outerEnvelope = try XCTUnwrap(UdpAssociation.DatagramHeader.decode(response))
        XCTAssertEqual(outerEnvelope.header.address, "127.0.0.1")
        XCTAssertEqual(outerEnvelope.header.port, peer.port)
        XCTAssertEqual(outerEnvelope.payload, innerEnvelope)
    }

    func testClientAddressLatchesAndSecondSourceIsRejected() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.latch")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let echo = try UdpTestSocket(family: AF_INET)
        let firstClient = try UdpTestSocket(family: AF_INET)
        let secondClient = try UdpTestSocket(family: AF_INET)
        var failureCount = 0
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "127.0.0.1",
                onFailure: { failureCount += 1 }
            )
        }
        defer {
            queue.sync { association.cancel() }
        }

        let request = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .ipv4,
                address: "127.0.0.1",
                port: echo.port,
                payload: Data([1, 2, 3])
            )
        )
        XCTAssertTrue(firstClient.send(request, host: "127.0.0.1", port: association.localPort))
        let echoedRequest = try XCTUnwrap(echo.receiveAndEcho())
        XCTAssertEqual(echoedRequest, Data([1, 2, 3]))
        let firstReply = try XCTUnwrap(firstClient.receive())
        XCTAssertEqual(UdpAssociation.DatagramHeader.decode(firstReply)?.payload, Data([1, 2, 3]))

        let fragmentedRequest = Data([0, 0, 1, 1, 127, 0, 0, 1, 0, 53, 0xaa])
        XCTAssertTrue(firstClient.send(fragmentedRequest, host: "127.0.0.1", port: association.localPort))
        XCTAssertNil(echo.receiveAndEcho())
        XCTAssertNil(firstClient.receive())

        XCTAssertTrue(firstClient.send(request, host: "127.0.0.1", port: association.localPort))
        let echoedAfterFragment = try XCTUnwrap(echo.receiveAndEcho())
        XCTAssertEqual(echoedAfterFragment, Data([1, 2, 3]))
        let replyAfterFragment = try XCTUnwrap(firstClient.receive())
        XCTAssertEqual(UdpAssociation.DatagramHeader.decode(replyAfterFragment)?.payload, Data([1, 2, 3]))
        XCTAssertEqual(queue.sync { failureCount }, 0)

        XCTAssertTrue(secondClient.send(request, host: "127.0.0.1", port: association.localPort))
        XCTAssertNil(echo.receiveAndEcho(timeout: 0.2))
        XCTAssertNil(secondClient.receive(timeout: 0.2))
    }

    /// Review finding: any host that guessed the ephemeral port could latch the
    /// association and then receive the real client's payload as peer traffic.
    func testOnlyControlPeerCanClaimTheAssociation() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.hijack")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let peer = try UdpTestSocket(family: AF_INET)
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "203.0.113.7",
                onFailure: {}
            )
        }
        defer { queue.sync { association.cancel() } }

        let stranger = try UdpTestSocket(family: AF_INET)
        let packet = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .ipv4, address: "127.0.0.1", port: peer.port, payload: Data([9, 9])
            )
        )
        XCTAssertTrue(stranger.send(packet, host: "127.0.0.1", port: association.localPort))
        XCTAssertNil(peer.receiveAndEcho(), "a non-control-peer source must not claim the association")
        XCTAssertNil(stranger.receive(), "and must receive nothing back")
    }

    /// Bug found via a real device (Discord voice over an IPv6-only hotspot,
    /// Shadowrocket as the SOCKS5 client): the client declared a DST.PORT in
    /// its UDP ASSOCIATE request that didn't match the port it actually sent
    /// from. Every real datagram then failed the exact-address match against
    /// the pre-latched (wrong) endpoint and was silently misfiled as "peer"
    /// traffic — echoed back to the wrong port and never forwarded upstream —
    /// so the client's own SOCKS5 UDP never reached anything, forever.
    func testDeclaredEndpointWrongPortStillLatchesRealClient() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.wrongDeclaredPort")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let echo = try UdpTestSocket(family: AF_INET)
        let realClient = try UdpTestSocket(family: AF_INET)
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "127.0.0.1",
                // Deliberately wrong: some SOCKS5 clients advertise a stale or
                // placeholder port rather than 0.0.0.0:0, and realClient's
                // actual port is guaranteed not to be this one.
                declaredClientEndpoint: (address: "127.0.0.1", port: 1),
                onFailure: {}
            )
        }
        defer { queue.sync { association.cancel() } }

        let packet = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .ipv4, address: "127.0.0.1", port: echo.port, payload: Data([7, 7, 7])
            )
        )
        XCTAssertTrue(realClient.send(packet, host: "127.0.0.1", port: association.localPort))
        let echoed = try XCTUnwrap(echo.receiveAndEcho(), "the real client's datagram must still reach upstream")
        XCTAssertEqual(echoed, Data([7, 7, 7]))
        let reply = try XCTUnwrap(realClient.receive())
        XCTAssertEqual(UdpAssociation.DatagramHeader.decode(reply)?.payload, Data([7, 7, 7]))

        // Once real traffic has used an endpoint, a second same-host source must
        // go back to being treated as peer traffic, same as the no-declaration
        // path: the correction window is one-shot, not a standing exception.
        let stranger = try UdpTestSocket(family: AF_INET)
        XCTAssertTrue(stranger.send(packet, host: "127.0.0.1", port: association.localPort))
        XCTAssertNil(echo.receiveAndEcho(timeout: 0.2))
        XCTAssertNil(stranger.receive(timeout: 0.2))
    }

    /// Review finding: getaddrinfo AF_INET results were cached as sockaddr_in and
    /// then rejected by the dual-stack socket, so A-only names silently dropped
    /// every datagram. "127.0.0.1" as a domain resolves to IPv4 only.
    func testIPv4OnlyDomainDestinationIsReachable() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.ipv4Domain")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let echo = try UdpTestSocket(family: AF_INET)
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "127.0.0.1",
                onFailure: {}
            )
        }
        defer { queue.sync { association.cancel() } }

        let client = try UdpTestSocket(family: AF_INET)
        let packet = try XCTUnwrap(
            UdpAssociation.DatagramHeader.encode(
                addressType: .domain, address: "127.0.0.1", port: echo.port, payload: Data([4, 5, 6])
            )
        )
        // Every socket in this suite lives on 127.0.0.1, so a stray datagram from a
        // neighbouring test can reach this echo. Wait for the payload this test sent
        // rather than accepting whatever arrives first.
        var delivered: Data?
        for _ in 0..<10 where delivered != Data([4, 5, 6]) {
            XCTAssertTrue(client.send(packet, host: "127.0.0.1", port: association.localPort))
            if let received = echo.receiveAndEcho(), received == Data([4, 5, 6]) {
                delivered = received
            }
        }
        XCTAssertEqual(delivered, Data([4, 5, 6]), "A-only domain destination never received the payload")
        let reply = try XCTUnwrap(client.receive())
        XCTAssertEqual(UdpAssociation.DatagramHeader.decode(reply)?.payload, Data([4, 5, 6]))
    }

    func testCancelClosesUdpPort() throws {
        let queue = DispatchQueue(label: "UdpAssociationTests.teardown")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let association = try queue.sync {
            try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: "127.0.0.1",
                controlPeerAddress: "127.0.0.1",
                onFailure: {}
            )
        }
        let port = association.localPort
        queue.sync { association.cancel() }
        let replacement = try UdpTestSocket(family: AF_INET, port: port)
        XCTAssertEqual(replacement.port, port)
    }

    func testNetworkRelayUdpEchoIPv4IPv6AndDomain() throws {
        let relay = NetworkTCPRelay(
            countingEnabled: true,
            bindHost: "127.0.0.1",
            port: 0,
            queueLabel: "UdpAssociationTests.relay"
        )
        let relayPort = try start(relay)
        defer { stop(relay) }

        let ipv4Echo = try UdpTestSocket(family: AF_INET)
        let ipv6Echo = try UdpTestSocket(family: AF_INET6)
        let payloads = [
            ("127.0.0.1", ipv4Echo.port, Data([1, 2, 3, 4])),
            ("::1", ipv6Echo.port, Data([5, 6, 7, 8, 9])),
            ("localhost", ipv6Echo.port, Data([10, 11, 12]))
        ]

        var expectedUpload = 0
        var expectedDownload = 0
        for (destination, destinationPort, payload) in payloads {
            let control = try openAssociation(relayPort: relayPort)
            defer { control.connection.cancel() }
            let client = try UdpTestSocket(family: AF_INET)
            let packet = try XCTUnwrap(
                UdpAssociation.DatagramHeader.encode(
                    addressType: destination == "localhost" ? .domain : (destination == "::1" ? .ipv6 : .ipv4),
                    address: destination,
                    port: destinationPort,
                    payload: payload
                )
            )

            var response: Data?
            for attempt in 0..<8 where response == nil {
                XCTAssertTrue(client.send(packet, host: "127.0.0.1", port: control.udpPort))
                if destination == "127.0.0.1" {
                    _ = ipv4Echo.receiveAndEcho(timeout: 0.2)
                } else {
                    _ = ipv6Echo.receiveAndEcho(timeout: 0.2)
                }
                response = client.receive(timeout: 0.2)
                if attempt == 0, destination == "localhost" {
                    // The first domain packet is intentionally lost while DNS resolves.
                    continue
                }
            }
            let decoded = try XCTUnwrap(
                response.flatMap { UdpAssociation.DatagramHeader.decode($0) },
                "no decodable reply for destination \(destination)"
            )
            XCTAssertEqual(decoded.payload, payload, "payload mismatch for destination \(destination)")
            expectedUpload += payload.count
            expectedDownload += payload.count
            control.cancel()
            XCTAssertTrue(waitForPortRelease(control.udpPort))
        }

        let snapshot = try snapshot(relay)
        XCTAssertEqual(snapshot.uploadBytes, UInt64(expectedUpload))
        XCTAssertEqual(snapshot.downloadBytes, UInt64(expectedDownload))
        XCTAssertEqual(snapshot.activeTCP, 0)
    }

    private func start(_ relay: NetworkTCPRelay) throws -> UInt16 {
        let ready = expectation(description: "relay ready")
        var result: Result<UInt16, NetworkTCPRelay.RelayError>?
        relay.start {
            result = $0
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(result).get()
    }

    private func stop(_ relay: NetworkTCPRelay) {
        let stopped = expectation(description: "relay stopped")
        relay.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 5)
    }

    private func snapshot(_ relay: NetworkTCPRelay) throws -> TrafficCounters.Snapshot {
        let received = expectation(description: "snapshot")
        var value: TrafficCounters.Snapshot?
        relay.snapshot {
            value = $0
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        return try XCTUnwrap(value)
    }

    private func waitForPortRelease(_ port: UInt16) -> Bool {
        for _ in 0..<40 {
            if let socket = try? UdpTestSocket(family: AF_INET, port: port) {
                _ = socket
                return true
            }
            usleep(50_000)
        }
        return false
    }

    private func openAssociation(relayPort: UInt16) throws -> UdpControl {
        let queue = DispatchQueue(label: "UdpAssociationTests.control")
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: relayPort)!,
            using: .tcp
        )
        let ready = expectation(description: "control ready")
        let replyReceived = expectation(description: "associate reply")
        var reply = Data()
        var finished = false

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 128) { data, _, isComplete, error in
                if let data { reply.append(data) }
                if error != nil || isComplete {
                    return
                }
                // 2 bytes of method selection precede the 10-byte request reply
                // because the greeting and the request are sent coalesced.
                if reply.count >= 12 {
                    finished = true
                    replyReceived.fulfill()
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.fulfill()
                let request = Data([
                    0x05, 0x01, 0x00,
                    0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0
                ])
                connection.send(
                    content: request,
                    contentContext: .defaultMessage,
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if error == nil { receive() }
                    }
                )
            case .failed, .cancelled:
                if !finished { replyReceived.fulfill() }
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
        wait(for: [ready, replyReceived], timeout: 5)
        guard reply.count >= 12, Array(reply.prefix(2)) == [0x05, 0x00] else {
            connection.cancel()
            throw UdpTestError.invalidReply
        }
        let requestReply = Array(reply.dropFirst(2))
        XCTAssertEqual(requestReply.count, 10)
        XCTAssertEqual(requestReply[0], 0x05)
        XCTAssertEqual(requestReply[1], 0x00)
        XCTAssertNotEqual(requestReply[4], 0)
        let addressLength = requestReply[3] == 0x01 ? 4 : (requestReply[3] == 0x04 ? 16 : 1 + Int(requestReply[4]))
        let portOffset = 4 + addressLength
        let port = UInt16(requestReply[portOffset]) << 8 | UInt16(requestReply[portOffset + 1])
        return UdpControl(connection: connection, udpPort: port)
    }
}

private enum UdpTestError: Error {
    case invalidReply
}

private struct UdpControl {
    let connection: NWConnection
    let udpPort: UInt16

    func cancel() {
        connection.cancel()
    }
}

private final class UdpTestSocket {
    private let fd: Int32
    let family: Int32
    let port: UInt16

    init(family: Int32, port: UInt16 = 0) throws {
        self.family = family
        let socketFD = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        // 1s, not 200ms: the first run after a build is slow enough on a cold
        // simulator to trip a tighter bound without any production defect.
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        if family == AF_INET6 {
            // Dual stack, so one echo socket serves whichever family a name resolves to.
            var off: Int32 = 0
            _ = withUnsafePointer(to: &off) {
                Darwin.setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, $0, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr()
            guard withUnsafePointer(to: &address, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }) == 0 else {
                Darwin.close(socketFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var bound = address
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socketFD, $0, &length)
                }
            }
            self.port = UInt16(bigEndian: bound.sin_port)
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            guard withUnsafePointer(to: &address, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }) == 0 else {
                Darwin.close(socketFD)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var bound = address
            var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            _ = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(socketFD, $0, &length)
                }
            }
            self.port = UInt16(bigEndian: bound.sin6_port)
        }

        self.fd = socketFD
    }

    deinit { Darwin.close(fd) }

    func send(_ data: Data, host: String, port: UInt16) -> Bool {
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            guard host.withCString({ Darwin.inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return false }
            return send(data, address: address, length: socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        guard host.withCString({ Darwin.inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else { return false }
        return send(data, address: address, length: socklen_t(MemoryLayout<sockaddr_in6>.size))
    }

    func receive(timeout: TimeInterval = 1.0) -> Data? {
        var packet = [UInt8](repeating: 0, count: 65_535)
        let capacity = packet.count
        let count = packet.withUnsafeMutableBytes { pointer in
            Darwin.recvfrom(fd, pointer.baseAddress, capacity, 0, nil, nil)
        }
        guard count >= 0 else { return nil }
        return Data(packet.prefix(Int(count)))
    }

    /// Returns the raw bytes the destination received. A peer is an ordinary UDP
    /// endpoint: it gets payload, never a SOCKS envelope. Decoding here would
    /// silently reinterpret payload that happens to be envelope-shaped.
    func receiveAndEcho(timeout: TimeInterval = 1.0) -> Data? {
        var packet = [UInt8](repeating: 0, count: 65_535)
        let capacity = packet.count
        var source = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let count = packet.withUnsafeMutableBytes { pointer in
            withUnsafeMutablePointer(to: &source) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.recvfrom(fd, pointer.baseAddress, capacity, 0, sockaddrPointer, &length)
                }
            }
        }
        guard count >= 0 else { return nil }
        let data = Data(packet.prefix(Int(count)))
        _ = data.withUnsafeBytes { pointer in
            withUnsafePointer(to: &source) { sourcePointer in
                sourcePointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.sendto(fd, pointer.baseAddress, data.count, 0, sockaddrPointer, length)
                }
            }
        }
        return data
    }

    private func send<T>(_ data: Data, address: T, length: socklen_t) -> Bool {
        var address = address
        return data.withUnsafeBytes { dataPointer in
            withUnsafeBytes(of: &address) { addressBytes in
                guard let addressPointer = addressBytes.baseAddress else { return false }
                let count = Darwin.sendto(
                    fd,
                    dataPointer.baseAddress,
                    data.count,
                    0,
                    addressPointer.assumingMemoryBound(to: sockaddr.self),
                    length
                )
                return count == data.count
            }
        }
    }
}

extension UdpAssociationTests {
    /// The behavioural fixture for this was worthless: `getaddrinfo("127.0.0.1")`
    /// returns more than the A record, so the send loop's fallback masked the
    /// defect and the test passed with and without the fix. Assert the invariant
    /// the fix actually establishes instead.
    func testResolverReturnsOnlyDualStackAddresses() {
        let addresses = UdpAssociation.resolve("127.0.0.1")
        XCTAssertFalse(addresses.isEmpty, "127.0.0.1 must resolve")
        for address in addresses {
            XCTAssertEqual(
                address.family, sa_family_t(AF_INET6),
                "an AF_INET sockaddr is rejected by the dual-stack socket with EAFNOSUPPORT"
            )
        }
    }
}
