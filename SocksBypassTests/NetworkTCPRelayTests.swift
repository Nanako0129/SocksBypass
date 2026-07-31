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

    func start(_ completion: @escaping (Result<UInt16, Error>) -> Void) {
        queue.async {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

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
            if payload.isEmpty, !isComplete {
                self.relay(connection, id: id)
                return
            }

            connection.send(
                content: payload.isEmpty ? nil : payload,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if error != nil || isComplete {
                        connection.cancel()
                        self.connections.removeValue(forKey: id)
                    } else {
                        self.relay(connection, id: id)
                    }
                }
            )
        }
    }
}

private enum TestError: Error {
    case invalidSOCKSReply
    case truncatedReply
    case listenerPort
    case unknownState
}
