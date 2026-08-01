import Foundation
import Network

final class NetworkTCPRelay {
    enum RelayError: Error, Equatable {
        case alreadyRunning
        case listenerSetup
        case listenerFailed
        case cancelled
    }

    private enum State {
        case stopped
        case starting
        case running
        case stopping
    }

    private let queue: DispatchQueue
    private let bindHost: NWEndpoint.Host
    private let requestedPort: UInt16
    private let counters: TrafficCounters
    private var state = State.stopped
    private var listener: NWListener?
    private var sessions: [UUID: RelaySession] = [:]
    private var generation = 0
    private var startCompletion: ((Result<UInt16, RelayError>) -> Void)?
    private var stopCompletions: [() -> Void] = []

    init(
        countingEnabled: Bool,
        bindHost: String = "0.0.0.0",
        port: UInt16 = 9876,
        queueLabel: String = "com.nanako.socksbypass.benchmark.relay"
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.bindHost = NWEndpoint.Host(bindHost)
        requestedPort = port
        counters = TrafficCounters(queue: queue, enabled: countingEnabled)
    }

    func start(_ completion: @escaping (Result<UInt16, RelayError>) -> Void) {
        queue.async {
            guard self.state == .stopped else {
                completion(.failure(.alreadyRunning))
                return
            }

            guard let port = NWEndpoint.Port(rawValue: self.requestedPort) else {
                completion(.failure(.listenerSetup))
                return
            }

            let parameters = Self.makeTCPParameters()
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: self.bindHost, port: port)

            let listener: NWListener
            do {
                listener = try NWListener(using: parameters)
            } catch {
                completion(.failure(.listenerSetup))
                return
            }

            self.generation += 1
            let generation = self.generation
            self.state = .starting
            self.listener = listener
            self.startCompletion = completion

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, generation: generation)
            }
            listener.stateUpdateHandler = { [weak self] newState in
                self?.handleListenerState(newState, generation: generation)
            }
            listener.start(queue: self.queue)
        }
    }

    func stop(_ completion: (() -> Void)? = nil) {
        queue.async {
            if let completion {
                self.stopCompletions.append(completion)
            }

            guard self.state != .stopped else {
                self.finishStop()
                return
            }
            guard self.state != .stopping else { return }

            self.state = .stopping
            if let startCompletion = self.startCompletion {
                self.startCompletion = nil
                startCompletion(.failure(.cancelled))
            }

            let currentSessions = Array(self.sessions.values)
            currentSessions.forEach { $0.cancel() }
            self.sessions.removeAll(keepingCapacity: true)
            self.counters.closeAllSessions()

            guard let listener = self.listener else {
                self.finishStop()
                return
            }
            listener.cancel()
        }
    }

    func snapshot(_ completion: @escaping (TrafficCounters.Snapshot) -> Void) {
        counters.snapshot(completion)
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == self.generation, state == .running else {
            connection.cancel()
            return
        }

        let id = UUID()
        let session = RelaySession(
            id: id,
            client: connection,
            queue: queue,
            counters: counters
        ) { [weak self] closedID in
            self?.sessions.removeValue(forKey: closedID)
        }
        sessions[id] = session
        session.start()
    }

    private func handleListenerState(_ newState: NWListener.State, generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard generation == self.generation else { return }

        switch newState {
        case .ready:
            guard state == .starting, let port = listener?.port?.rawValue else { return }
            state = .running
            let completion = startCompletion
            startCompletion = nil
            completion?(.success(port))

        case .failed:
            let completion = startCompletion
            startCompletion = nil
            completion?(.failure(.listenerFailed))
            let currentSessions = Array(sessions.values)
            currentSessions.forEach { $0.cancel() }
            sessions.removeAll(keepingCapacity: true)
            counters.closeAllSessions()
            listener = nil
            state = .stopped
            finishStop()

        case .cancelled:
            let currentSessions = Array(sessions.values)
            currentSessions.forEach { $0.cancel() }
            sessions.removeAll(keepingCapacity: true)
            counters.closeAllSessions()
            listener = nil
            state = .stopped
            finishStop()

        case .setup, .waiting:
            break

        @unknown default:
            break
        }
    }

    private func finishStop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard state == .stopped || listener == nil else { return }
        state = .stopped
        counters.closeAllSessions()
        let completions = stopCompletions
        stopCompletions.removeAll(keepingCapacity: true)
        completions.forEach { $0() }
    }

    fileprivate static func makeTCPParameters() -> NWParameters {
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.connectionTimeout = 10
        return NWParameters(tls: nil, tcp: options)
    }
}

private enum CleanupReason: String {
    case handshakeTimeout
    case relayStop
    case clientFailed
    case clientCancelledInactive
    case clientUnknownState
    case handshakeReceiveError
    case handshakeClientEOF
    case targetFailedActive
    case targetCancelledInactive
    case targetUnknownState
    case gracefulCloseTimeout
    case controlSendError
    case clientReceiveError
    case targetReceiveError
    case destinationMissing
    case forwardSendError
    case halfCloseSendError
    case terminalErrorAfterHalfClose
    case bothDirectionsClosed
}

private final class RelaySession {
    private enum Flow {
        case upload
        case download
    }

    private let id: UUID
    private let client: NWConnection
    private let queue: DispatchQueue
    private let counters: TrafficCounters
    private let didClose: (UUID) -> Void
    private var parser = Socks5HandshakeParser()
    private var target: NWConnection?
    private var pendingInitialPayload = Data()
    private var pendingClientReadComplete = false
    private var clientReady = false
    private var targetReady = false
    private var active = false
    private var cleaned = false
    private var clientReadComplete = false
    private var targetReadComplete = false
    private var handshakeReceivePending = false
    private var handshakeTimeout: DispatchWorkItem?
    private var clientReceivePending = false
    private var targetReceivePending = false
    private var gracefulCloseTimeout: DispatchWorkItem?
#if RELAY_DIAGNOSTICS
    private var sessionUpload = 0
    private var sessionDownload = 0
    private var sessionUploadReceived = 0
    private var sessionDownloadReceived = 0
    private var downloadReceiveError = false
    private var downloadReceiveErrorCode = "none"
    private var downloadSawFIN = false
#endif

    init(
        id: UUID,
        client: NWConnection,
        queue: DispatchQueue,
        counters: TrafficCounters,
        didClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.client = client
        self.queue = queue
        self.counters = counters
        self.didClose = didClose
    }

    func start() {
        assertQueue()
        let timeout = DispatchWorkItem { [weak self] in
            self?.cleanup(.handshakeTimeout)
        }
        handshakeTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)

        client.stateUpdateHandler = { [weak self] state in
            self?.handleClientState(state)
        }
        client.start(queue: queue)
    }

    func cancel() {
        assertQueue()
        cleanup(.relayStop)
    }

    private func handleClientState(_ state: NWConnection.State) {
        assertQueue()
        guard !cleaned else { return }

        switch state {
        case .ready:
            guard !clientReady else { return }
            clientReady = true
            receiveHandshake()
        case .failed:
            if active, !clientReadComplete, target != nil {
                armCloseTimeout()
                receiveClientPayload()
            } else {
                cleanup(.clientFailed)
            }
        case .cancelled:
            if !active {
                cleanup(.clientCancelledInactive)
            }
        case .setup, .preparing, .waiting:
            break
        @unknown default:
            cleanup(.clientUnknownState)
        }
    }

    private func receiveHandshake() {
        assertQueue()
        guard !cleaned, !active, !handshakeReceivePending else { return }
        handshakeReceivePending = true

        client.receive(minimumIncompleteLength: 1, maximumLength: Socks5HandshakeParser.maximumFeedBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.handshakeReceivePending = false
            guard !self.cleaned else { return }

            if error != nil, data?.isEmpty != false {
                self.cleanup(.handshakeReceiveError)
                return
            }

            let output = self.parser.feed(data ?? Data())
            self.pendingClientReadComplete = self.pendingClientReadComplete || isComplete || error != nil
            let closeAfterResponses = output.shouldClose || (self.pendingClientReadComplete && output.connect == nil)

            self.sendControlResponses(output.replies, final: closeAfterResponses) { success in
                guard success, !self.cleaned else { return }

                if output.shouldClose {
                    self.finishAfterGracefulControlClose()
                } else if let request = output.connect {
                    self.pendingInitialPayload = request.firstPayload
                    self.beginTargetConnection(request)
                } else if self.pendingClientReadComplete {
                    _ = self.parser.finish()
                    self.cleanup(.handshakeClientEOF)
                } else {
                    self.receiveHandshake()
                }
            }
        }
    }

    private func beginTargetConnection(_ request: Socks5HandshakeParser.ConnectRequest) {
        assertQueue()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        guard !cleaned, target == nil,
              let port = NWEndpoint.Port(rawValue: request.target.port) else {
            sendConnectFailure(0x01)
            return
        }

        let target = NWConnection(
            host: NWEndpoint.Host(request.target.address),
            port: port,
            using: NetworkTCPRelay.makeTCPParameters()
        )
        self.target = target
        target.stateUpdateHandler = { [weak self] state in
            self?.handleTargetState(state)
        }
        target.start(queue: queue)
    }

    private func handleTargetState(_ state: NWConnection.State) {
        assertQueue()
        guard !cleaned else { return }

        switch state {
        case .ready:
            guard !targetReady else { return }
            targetReady = true
            sendControlResponses([Socks5HandshakeParser.requestReply(0x00)], final: false) { success in
                guard success, !self.cleaned else { return }
                self.active = true
                self.counters.sessionOpened(self.id)
                self.receiveTargetPayload()

                if !self.pendingInitialPayload.isEmpty || self.pendingClientReadComplete {
                    let payload = self.pendingInitialPayload
                    self.pendingInitialPayload.removeAll(keepingCapacity: false)
                    self.forward(
                        payload,
                        flow: .upload,
                        complete: self.pendingClientReadComplete,
                        terminalError: false
                    )
                } else {
                    self.receiveClientPayload()
                }
            }

        case .failed(let error):
            if active {
                if targetReadComplete {
                    cleanup(.targetFailedActive)
                } else {
                    // A failed state does not mean the stack has nothing left for us.
                    // Backpressure leaves gaps with no receive outstanding, and giving
                    // up in one of those gaps discards whatever is still buffered.
                    // Keep draining; the receive path forwards and half-closes itself.
                    armCloseTimeout()
                    receiveTargetPayload()
                }
            } else {
                sendConnectFailure(Self.replyCode(for: error))
            }

        case .cancelled:
            if !active {
                cleanup(.targetCancelledInactive)
            }

        case .setup, .preparing, .waiting:
            break

        @unknown default:
            cleanup(.targetUnknownState)
        }
    }

    private func sendConnectFailure(_ reply: UInt8) {
        assertQueue()
        guard !cleaned else { return }
        sendControlResponses([Socks5HandshakeParser.requestReply(reply)], final: true) { success in
            if success {
                self.finishAfterGracefulControlClose()
            }
        }
    }

    private func finishAfterGracefulControlClose() {
        assertQueue()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        let timeout = DispatchWorkItem { [weak self] in
            self?.cleanup(.gracefulCloseTimeout)
        }
        gracefulCloseTimeout = timeout
        queue.asyncAfter(deadline: .now() + 1, execute: timeout)
    }

    private func sendControlResponses(_ responses: [Data], final: Bool, completion: @escaping (Bool) -> Void) {
        assertQueue()

        func send(_ index: Int) {
            guard !cleaned else {
                completion(false)
                return
            }
            guard index < responses.count else {
                completion(true)
                return
            }

            client.send(
                content: responses[index],
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.assertQueue()
                    guard error == nil else {
                        self.cleanup(.controlSendError)
                        completion(false)
                        return
                    }
                    send(index + 1)
                }
            )
        }

        send(0)
    }

    private func receiveClientPayload() {
        assertQueue()
        guard active, !cleaned, !clientReadComplete, !clientReceivePending else { return }
        clientReceivePending = true

        client.receive(minimumIncompleteLength: 1, maximumLength: Socks5HandshakeParser.maximumFeedBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.clientReceivePending = false
            guard !self.cleaned else { return }

            let payload = data ?? Data()
            self.noteReceived(payload.count, .upload, error: error, isComplete: isComplete)
            if !payload.isEmpty || isComplete {
                self.forward(payload, flow: .upload, complete: isComplete || error != nil, terminalError: error != nil)
            } else if error != nil {
                if let target = self.target, !self.clientReadComplete {
                    self.closeDirectionThenCleanup(to: target, flow: .upload)
                } else {
                    self.cleanup(.clientReceiveError)
                }
            } else {
                self.receiveClientPayload()
            }
        }
    }

    private func receiveTargetPayload() {
        assertQueue()
        guard active, !cleaned, !targetReadComplete, !targetReceivePending, let target else { return }
        targetReceivePending = true

        target.receive(minimumIncompleteLength: 1, maximumLength: Socks5HandshakeParser.maximumFeedBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.targetReceivePending = false
            guard !self.cleaned else { return }

            let payload = data ?? Data()
            self.noteReceived(payload.count, .download, error: error, isComplete: isComplete)
            if !payload.isEmpty || isComplete {
                self.forward(payload, flow: .download, complete: isComplete || error != nil, terminalError: error != nil)
            } else if error != nil {
                if !self.targetReadComplete {
                    self.closeDirectionThenCleanup(to: self.client, flow: .download)
                } else {
                    self.cleanup(.targetReceiveError)
                }
            } else {
                self.receiveTargetPayload()
            }
        }
    }

    private func forward(_ data: Data, flow: Flow, complete: Bool, terminalError: Bool) {
        assertQueue()
        guard !cleaned else { return }

        let destination: NWConnection?
        let direction: TrafficCounters.Direction
        switch flow {
        case .upload:
            destination = target
            direction = .upload
        case .download:
            destination = client
            direction = .download
        }

        guard let destination else {
            cleanup(.destinationMissing)
            return
        }

        guard !data.isEmpty else {
            if complete {
                sendHalfClose(to: destination, flow: flow, terminalError: terminalError)
            }
            return
        }

        destination.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.assertQueue()
                guard !self.cleaned else { return }
                guard error == nil else {
                    self.cleanup(.forwardSendError)
                    return
                }

                self.counters.recordCommitted(data.count, direction: direction)
                self.note(data.count, direction)
                if complete {
                    self.sendHalfClose(to: destination, flow: flow, terminalError: terminalError)
                } else {
                    self.receiveNextPayload(for: flow)
                }
            }
        )
    }

    private func sendHalfClose(to destination: NWConnection, flow: Flow, terminalError: Bool) {
        assertQueue()
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.assertQueue()
                guard !self.cleaned else { return }
                guard error == nil else {
                    self.cleanup(.halfCloseSendError)
                    return
                }

                switch flow {
                case .upload:
                    self.clientReadComplete = true
                case .download:
                    self.targetReadComplete = true
                }

                if terminalError {
                    self.cleanup(.terminalErrorAfterHalfClose)
                } else {
                    self.finishIfBothDirectionsClosed()
                }
            }
        )
    }

    private func receiveNextPayload(for flow: Flow) {
        assertQueue()
        switch flow {
        case .upload:
            receiveClientPayload()
        case .download:
            receiveTargetPayload()
        }
    }

    /// One endpoint failing is not a reason to abort the other direction. Write-close it
    /// first so the peer sees end-of-stream instead of an abort and keeps its in-flight
    /// bytes; `cancel()` only drops sends whose completion has not fired yet.
    private func closeDirectionThenCleanup(to destination: NWConnection, flow: Flow) {
        assertQueue()
        guard !cleaned else { return }
        armCloseTimeout()
        sendHalfClose(to: destination, flow: flow, terminalError: true)
    }

    /// A failed state must never outrun an outstanding receive: that callback can still
    /// carry the last bytes the peer managed to send, and cleaning up first discards them.
    /// Let it land, then it forwards and half-closes through the normal path.
    private func armCloseTimeout() {
        assertQueue()
        guard gracefulCloseTimeout == nil else { return }
        // ponytail: fixed 5s ceiling so a stalled peer cannot hold the session open;
        // make it adaptive only if a real workload is seen to need longer.
        let timeout = DispatchWorkItem { [weak self] in
            self?.cleanup(.gracefulCloseTimeout)
        }
        gracefulCloseTimeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func finishIfBothDirectionsClosed() {
        assertQueue()
        guard clientReadComplete, targetReadComplete, !cleaned else { return }
        cleanup(.bothDirectionsClosed)
    }

    private func cleanup(_ reason: CleanupReason) {
        assertQueue()
        guard !cleaned else { return }
        cleaned = true
        diagnose(reason)
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        gracefulCloseTimeout?.cancel()
        gracefulCloseTimeout = nil

        client.stateUpdateHandler = nil
        target?.stateUpdateHandler = nil
        client.cancel()
        target?.cancel()
        if active {
            active = false
            counters.sessionClosed(id)
        }
        didClose(id)
    }

    private func assertQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

#if RELAY_DIAGNOSTICS
    // Anonymous per-session close record: enum reason plus byte counts only.
    // No endpoints, addresses, identifiers or payload ever enter this output.
    private func note(_ byteCount: Int, _ direction: TrafficCounters.Direction) {
        switch direction {
        case .upload:
            sessionUpload += byteCount
        case .download:
            sessionDownload += byteCount
        }
    }

    /// Bytes handed to us by the peer's receive callback, before we forward them.
    /// Comparing this against the committed count says which leg lost the bytes.
    private func noteReceived(_ byteCount: Int, _ flow: Flow, error: NWError?, isComplete: Bool) {
        switch flow {
        case .upload:
            sessionUploadReceived += byteCount
        case .download:
            sessionDownloadReceived += byteCount
            if isComplete { downloadSawFIN = true }
            guard let error else { return }
            downloadReceiveError = true
            if case .posix(let code) = error {
                downloadReceiveErrorCode = String(describing: code)
            } else {
                downloadReceiveErrorCode = "nonPosix"
            }
        }
    }

    private func diagnose(_ reason: CleanupReason) {
        let record: [String: Any] = [
            "relayClose": reason.rawValue,
            "uploadCommitted": sessionUpload,
            "downloadCommitted": sessionDownload,
            "uploadReceived": sessionUploadReceived,
            "downloadReceived": sessionDownloadReceived,
            "downloadReceiveError": downloadReceiveError,
            "downloadReceiveErrorCode": downloadReceiveErrorCode,
            "downloadSawFIN": downloadSawFIN,
            "clientReadComplete": clientReadComplete,
            "targetReadComplete": targetReadComplete,
            "active": active
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
#else
    private func note(_ byteCount: Int, _ direction: TrafficCounters.Direction) {}
    private func noteReceived(_ byteCount: Int, _ flow: Flow, error: NWError?, isComplete: Bool) {}
    private func diagnose(_ reason: CleanupReason) {}
#endif

    private static func replyCode(for error: NWError) -> UInt8 {
        guard case .posix(let code) = error else { return 0x01 }
        switch code {
        case .ECONNREFUSED:
            return 0x05
        case .ENETUNREACH:
            return 0x03
        case .EHOSTUNREACH, .ETIMEDOUT:
            return 0x04
        default:
            return 0x01
        }
    }
}
