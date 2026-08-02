import Foundation
import Network
import XCTest

final class NetworkTCPRelayTests: XCTestCase {
    func testLoopbackHalfCloseCountersStopAndRestart() throws {
        let echo = OneShotEchoServer()
        let echoReady = expectation(description: "echo ready")
        var echoPort: UInt16?
        echo.start { result in
            echoPort = try? result.get()
            echoReady.fulfill()
        }
        wait(for: [echoReady], timeout: 5)
        let targetPort = try XCTUnwrap(echoPort)
        defer { echo.stop() }

        let relay = NetworkTCPRelay(
            countingEnabled: true,
            bindHost: "127.0.0.1",
            port: 0,
            queueLabel: "NetworkTCPRelayTests.relay"
        )

        let firstRelayPort = try start(relay)
        let firstPayload = Data((0..<4_099).map { UInt8(truncatingIfNeeded: $0) })
        XCTAssertEqual(try roundTrip(relayPort: firstRelayPort, targetPort: targetPort, payload: firstPayload), firstPayload)
        let first = try waitForIdleSnapshot(relay)
        XCTAssertEqual(first, .init(uploadBytes: UInt64(firstPayload.count), downloadBytes: UInt64(firstPayload.count), activeTCP: 0))

        stop(relay)
        let stopped = try snapshot(relay)
        XCTAssertEqual(stopped, first)

        let secondRelayPort = try start(relay)
        let secondPayload = Data((0..<2_051).map { UInt8(truncatingIfNeeded: 255 - $0) })
        XCTAssertEqual(try roundTrip(relayPort: secondRelayPort, targetPort: targetPort, payload: secondPayload), secondPayload)
        let restarted = try waitForIdleSnapshot(relay)
        XCTAssertEqual(
            restarted,
            .init(
                uploadBytes: UInt64(firstPayload.count + secondPayload.count),
                downloadBytes: UInt64(firstPayload.count + secondPayload.count),
                activeTCP: 0
            )
        )
        stop(relay)
    }

    /// A refused target used to hang: Network.framework parks an unreachable
    /// outbound connection in `.waiting` and keeps retrying, so the client waited
    /// for a reply that never came. It is owed 0x05 instead.
    func testRefusedConnectRepliesConnectionRefused() throws {
        let relay = makeRelay()
        let relayPort = try start(relay)
        defer { stop(relay) }

        let request = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x01])
        let exchange = try socksExchange(relayPort: relayPort, request: request, expectedPayload: 0)

        XCTAssertEqual(exchange.methodReply, Data([0x05, 0x00]))
        XCTAssertEqual(exchange.connectReply.count, 10)
        XCTAssertEqual(exchange.connectReply[1], 0x05)
    }

    func testDomainNameConnectReachesTarget() throws {
        let echo = OneShotEchoServer()
        let targetPort = try startEcho(echo, host: "127.0.0.1")
        defer { echo.stop() }

        let relay = makeRelay()
        let relayPort = try start(relay)
        defer { stop(relay) }

        let name = Array("localhost".utf8)
        var request = Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)])
        request.append(contentsOf: name)
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))

        let payload = Data((0..<1_500).map { UInt8(truncatingIfNeeded: $0) })
        let exchange = try socksExchange(
            relayPort: relayPort, request: request, payload: payload,
            expectedPayload: payload.count
        )
        XCTAssertEqual(exchange.connectReply[1], 0x00)
        XCTAssertEqual(exchange.payload, payload)
    }

    func testIPv6ConnectReachesTarget() throws {
        let echo = OneShotEchoServer()
        let targetPort = try startEcho(echo, host: "::1")
        defer { echo.stop() }

        let relay = makeRelay()
        let relayPort = try start(relay)
        defer { stop(relay) }

        var request = Data([0x05, 0x01, 0x00, 0x04])
        request.append(contentsOf: [UInt8](repeating: 0, count: 15))
        request.append(0x01)                                   // ::1
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))

        let payload = Data((0..<1_500).map { UInt8(truncatingIfNeeded: 255 - $0) })
        let exchange = try socksExchange(
            relayPort: relayPort, request: request, payload: payload,
            expectedPayload: payload.count
        )
        XCTAssertEqual(exchange.connectReply[1], 0x00)
        XCTAssertEqual(exchange.payload, payload)
    }

    /// Enough traffic to cross many receive/forward cycles in both directions.
    /// The defect this guards against dropped one buffer's worth of payload
    /// between being received and being committed, which a small transfer that
    /// fits in a single receive cannot expose.
    func testLargeTransferIsByteExact() throws {
        let echo = OneShotEchoServer()
        let targetPort = try startEcho(echo, host: "127.0.0.1")
        defer { echo.stop() }

        let relay = makeRelay()
        let relayPort = try start(relay)
        defer { stop(relay) }

        let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var request = Data([0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
        request.append(UInt8(targetPort >> 8))
        request.append(UInt8(targetPort & 0xFF))

        let exchange = try socksExchange(
            relayPort: relayPort, request: request, payload: payload,
            expectedPayload: payload.count, timeout: 30
        )
        XCTAssertEqual(exchange.connectReply[1], 0x00)
        XCTAssertEqual(exchange.payload.count, payload.count)
        XCTAssertEqual(exchange.payload, payload)

        let idle = try waitForIdleSnapshot(relay)
        XCTAssertEqual(idle.uploadBytes, UInt64(payload.count))
        XCTAssertEqual(idle.downloadBytes, UInt64(payload.count))
    }

    private struct Exchange {
        var methodReply = Data()
        var connectReply = Data()
        var payload = Data()
    }

    private func makeRelay() -> NetworkTCPRelay {
        NetworkTCPRelay(
            countingEnabled: true,
            bindHost: "127.0.0.1",
            port: 0,
            queueLabel: "NetworkTCPRelayTests.relay"
        )
    }

    private func startEcho(_ echo: OneShotEchoServer, host: String) throws -> UInt16 {
        let ready = expectation(description: "echo ready")
        var port: UInt16?
        echo.start(host: host) { result in
            port = try? result.get()
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        return try XCTUnwrap(port)
    }

    /// Length of a CONNECT reply given its ATYP, or nil if not yet readable. The
    /// reply is not a fixed ten bytes: a successful CONNECT now carries the real
    /// bound endpoint, so an IPv6 target answers with twenty-two.
    private static func connectReplyLength(_ reply: Data) -> Int? {
        guard reply.count >= 4 else { return nil }
        switch reply[reply.startIndex + 3] {
        case 0x01: return 10
        case 0x04: return 22
        case 0x03:
            guard reply.count >= 5 else { return nil }
            return 7 + Int(reply[reply.startIndex + 4])
        default: return nil
        }
    }

    /// Sends the greeting, the request and any payload as one write-closed stream,
    /// then reads the method reply, the full CONNECT reply, and `expectedPayload`
    /// bytes after it.
    private func socksExchange(
        relayPort: UInt16,
        request: Data,
        payload: Data = Data(),
        expectedPayload: Int,
        timeout: TimeInterval = 10
    ) throws -> Exchange {
        let complete = expectation(description: "SOCKS exchange")
        let queue = DispatchQueue(label: "NetworkTCPRelayTests.exchange")
        let connection = NWConnection(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: relayPort)!, using: .tcp
        )
        var received = Data()
        var failure: Error?
        var finished = false

        func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            failure = error
            complete.fulfill()
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                guard !finished else { return }
                if let data { received.append(data) }
                let replyLength = Self.connectReplyLength(Data(received.dropFirst(2)))
                if let replyLength, received.count >= 2 + replyLength + expectedPayload {
                    finish(nil)
                } else if let error {
                    finish(error)
                } else if isComplete {
                    finish(TestError.truncatedReply)
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                var outbound = Data([0x05, 0x01, 0x00])
                outbound.append(request)
                outbound.append(payload)
                connection.send(
                    content: outbound,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error { finish(error) } else { receive() }
                    }
                )
            case .failed(let error):
                finish(error)
            case .cancelled:
                finish(TestError.truncatedReply)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                finish(TestError.unknownState)
            }
        }
        connection.start(queue: queue)
        wait(for: [complete], timeout: timeout)
        connection.cancel()

        if let failure { throw failure }
        var exchange = Exchange()
        exchange.methodReply = Data(received.prefix(2))
        let rest = Data(received.dropFirst(2))
        let replyLength = Self.connectReplyLength(rest) ?? 10
        exchange.connectReply = Data(rest.prefix(replyLength))
        exchange.payload = Data(rest.dropFirst(replyLength))
        return exchange
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
        relay.stop {
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 5)
    }

    private func snapshot(_ relay: NetworkTCPRelay) throws -> TrafficCounters.Snapshot {
        let received = expectation(description: "snapshot")
        var snapshot: TrafficCounters.Snapshot?
        relay.snapshot {
            snapshot = $0
            received.fulfill()
        }
        wait(for: [received], timeout: 2)
        return try XCTUnwrap(snapshot)
    }

    private func waitForIdleSnapshot(_ relay: NetworkTCPRelay) throws -> TrafficCounters.Snapshot {
        let idle = expectation(description: "relay idle")
        var final: TrafficCounters.Snapshot?
        let deadline = DispatchTime.now() + 5

        func poll() {
            relay.snapshot { snapshot in
                if snapshot.activeTCP == 0, snapshot.uploadBytes > 0, snapshot.downloadBytes > 0 {
                    final = snapshot
                    idle.fulfill()
                } else if DispatchTime.now() < deadline {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: poll)
                }
            }
        }

        poll()
        wait(for: [idle], timeout: 6)
        return try XCTUnwrap(final)
    }

    private func roundTrip(relayPort: UInt16, targetPort: UInt16, payload: Data) throws -> Data {
        let complete = expectation(description: "SOCKS round trip")
        let queue = DispatchQueue(label: "NetworkTCPRelayTests.client")
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: relayPort)!,
            using: .tcp
        )
        var result: Result<Data, Error>?
        var received = Data()
        var finished = false
        let expectedCount = 2 + 10 + payload.count

        func finish(_ outcome: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            result = outcome
            complete.fulfill()
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                guard !finished else { return }
                if let data {
                    received.append(data)
                }
                if let error {
                    finish(.failure(error))
                } else if received.count >= expectedCount {
                    let methodReply = Data(received.prefix(2))
                    let connectReply = Data(received.dropFirst(2).prefix(10))
                    if methodReply == Data([0x05, 0x00]), connectReply.count == 10, connectReply[1] == 0x00 {
                        finish(.success(Data(received.dropFirst(12).prefix(payload.count))))
                    } else {
                        finish(.failure(TestError.invalidSOCKSReply))
                    }
                } else if isComplete {
                    finish(.failure(TestError.truncatedReply))
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            guard !finished else { return }
            switch state {
            case .ready:
                var request = Data([0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1])
                request.append(UInt8(targetPort >> 8))
                request.append(UInt8(targetPort & 0xFF))
                request.append(payload)
                connection.send(
                    content: request,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                        } else {
                            receive()
                        }
                    }
                )
            case .failed(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(TestError.truncatedReply))
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                finish(.failure(TestError.unknownState))
            }
        }
        connection.start(queue: queue)
        wait(for: [complete], timeout: 8)
        connection.cancel()
        return try XCTUnwrap(result).get()
    }
}

private final class OneShotEchoServer {
    private let queue = DispatchQueue(label: "NetworkTCPRelayTests.echo")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]

    func start(host: String = "127.0.0.1", _ completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)

            do {
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            completion(.success(port))
                        } else {
                            completion(.failure(TestError.listenerPort))
                        }
                    case .failed(let error):
                        completion(.failure(error))
                    case .cancelled, .setup, .waiting:
                        break
                    @unknown default:
                        completion(.failure(TestError.unknownState))
                    }
                }
                listener.start(queue: self.queue)
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.relay(connection, id: id)
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                connection.cancel()
                self?.connections.removeValue(forKey: id)
            }
        }
        connection.start(queue: queue)
    }

    private func relay(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                connection.cancel()
                self.connections.removeValue(forKey: id)
                return
            }

            let payload = data ?? Data()
            guard !payload.isEmpty else {
                // The peer's FIN often arrives on its own receive, with no data.
                // Skipping the write-close here leaves the relay's download
                // direction open forever and the session never goes idle.
                if isComplete {
                    self.halfClose(connection, id: id)
                } else {
                    self.relay(connection, id: id)
                }
                return
            }

            // The write-close is a separate send. Carrying it on the same call as
            // the last chunk left that send's completion unfired and the echo
            // silently short by a whole buffer, which reads as a relay defect.
            connection.send(
                content: payload,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    if error != nil {
                        connection.cancel()
                        self.connections.removeValue(forKey: id)
                    } else if isComplete {
                        self.halfClose(connection, id: id)
                    } else {
                        self.relay(connection, id: id)
                    }
                }
            )
        }
    }
}

private extension OneShotEchoServer {
    func halfClose(_ connection: NWConnection, id: UUID) {
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in }
        )
    }
}

private enum TestError: Error {
    case invalidSOCKSReply
    case truncatedReply
    case listenerPort
    case unknownState
}
