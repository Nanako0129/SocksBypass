import Darwin
import Foundation
import Network

final class NetworkTCPRelay {
    /// Redacted by construction: these cases carry no address, hostname, port of a
    /// peer, or payload, so there is nothing to filter out before display.
    enum Event: Equatable {
        case sessionOpened
        case sessionClosed
        case connectEstablished
        case connectRejected(reply: UInt8)
        case udpAssociated
        case udpAssociateFailed
        /// Pure counts, no addresses or payload: how many datagrams from the
        /// client this association ever recognized, how many reply datagrams
        /// came back from a peer, and how many arrivals before the client
        /// address latched didn't match the control peer and were dropped.
        case udpAssociateClosed(uploaded: Int, downloaded: Int, preLatchRejected: Int)
        /// The listener died after it had already reported success. The start
        /// callback fires once, so without this the shell keeps showing a
        /// listening endpoint for a relay that stopped serving.
        case listenerFailed
    }

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
    /// Invoked on the relay queue. Set before `start`.
    var eventHandler: ((Event) -> Void)?

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
            counters: counters,
            emit: { [weak self] event in self?.eventHandler?(event) }
        ) { [weak self] closedID in
            self?.sessions.removeValue(forKey: closedID)
        }
        eventHandler?(.sessionOpened)
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
            // Fires whether or not anyone is still holding the start callback:
            // after `.ready` that callback is gone and this is the only signal.
            eventHandler?(.listenerFailed)
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
    case udpControlClosed
    case udpSocketFailed
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
    case upstreamTruncated
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
    private let emit: (NetworkTCPRelay.Event) -> Void
    private let didClose: (UUID) -> Void
    private var parser = Socks5HandshakeParser()
    private var target: NWConnection?
    private var udpAssociation: UdpAssociation?
    private var pendingInitialPayload = Data()
    private var pendingClientReadComplete = false
    /// The handshake receive ended in an error rather than a clean end of stream.
    /// Folding that into `pendingClientReadComplete` alone would hand the target a
    /// clean FIN, making a request that was cut short look like a whole one.
    private var pendingClientReadTruncated = false
    /// One reply per request. Set as soon as a failure reply is committed.
    private var requestRejected = false
    private var clientReady = false
    private var targetReady = false
    private var active = false
    private var cleaned = false
    private var clientReadComplete = false
    private var targetReadComplete = false
    private var handshakeReceivePending = false
    private var handshakeTimeout: DispatchWorkItem?
    /// Bounds the getaddrinfo() round trip in beginTargetConnection's literal-IPv4
    /// synthesis path; that call runs off-queue and has no timeout of its own.
    private var synthesisTimeout: DispatchWorkItem?
    private var clientReceivePending = false
    private var targetReceivePending = false
    // A receive must never overtake the send carrying the previous payload. The
    // normal path enforces that by only re-arming from the send completion, but
    // the connection-state handlers drain directly; without this the overtaking
    // receive can reach cleanup first and the queued payload dies unsent.
    private var uploadSendPending = false
    private var downloadSendPending = false
    private var gracefulCloseTimeout: DispatchWorkItem?
#if RELAY_DIAGNOSTICS
    private var sessionUpload = 0
    private var sessionDownload = 0
    private var sessionUploadReceived = 0
    private var sessionDownloadReceived = 0
    private var downloadReceiveError = false
    private var downloadReceiveErrorCode = "none"
    private var downloadSawFIN = false
    private var targetStateTrace: [String] = []
    private var sessionStartedAt = Date()
    private var lastDownloadByteAt: Date?
    private var downloadIdleBeforeError = -1.0
#endif

    init(
        id: UUID,
        client: NWConnection,
        queue: DispatchQueue,
        counters: TrafficCounters,
        emit: @escaping (NetworkTCPRelay.Event) -> Void,
        didClose: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.client = client
        self.queue = queue
        self.counters = counters
        self.emit = emit
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
            if udpAssociation != nil {
                cleanup(.udpControlClosed)
            } else if active, !clientReadComplete, target != nil {
                armCloseTimeout()
                receiveClientPayload()
            } else {
                cleanup(.clientFailed)
            }
        case .cancelled:
            if udpAssociation != nil {
                cleanup(.udpControlClosed)
            } else if !active {
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
            self.pendingClientReadTruncated = self.pendingClientReadTruncated || (error != nil && !isComplete)
            let closeAfterResponses = output.shouldClose || (self.pendingClientReadComplete && output.request == nil)

            self.sendControlResponses(output.replies, final: closeAfterResponses) { success in
                guard success, !self.cleaned else { return }

                if output.shouldClose {
                    self.finishAfterGracefulControlClose()
                } else if let request = output.request {
                    switch request.command {
                    case .connect:
                        self.pendingInitialPayload = request.firstPayload
                        self.beginTargetConnection(request)
                    case .udpAssociate:
                        self.beginUdpAssociation(request)
                    }
                } else if self.pendingClientReadComplete {
                    _ = self.parser.finish()
                    self.cleanup(.handshakeClientEOF)
                } else {
                    self.receiveHandshake()
                }
            }
        }
    }

    private func beginUdpAssociation(_ request: Socks5HandshakeParser.Request) {
        assertQueue()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        guard !cleaned, target == nil, udpAssociation == nil,
              let localAddress = controlLocalAddress() else {
            emit(.udpAssociateFailed)
            sendRequestFailure(0x01, event: nil)
            return
        }

        do {
            let association = try UdpAssociation(
                queue: queue,
                counters: counters,
                localAddress: localAddress,
                controlPeerAddress: controlRemoteAddress(),
                declaredClientEndpoint: Self.declaredUdpEndpoint(
                    request,
                    controlPeer: controlRemoteAddress()
                ),
                onFailure: { [weak self] in
                    guard let self else { return }
                    self.assertQueue()
                    self.cleanup(.udpSocketFailed)
                }
            )
            guard let reply = association.replyData(localAddress: localAddress) else {
                association.cancel()
                sendRequestFailure(0x01, event: .udpAssociateFailed)
                return
            }
            udpAssociation = association
            counters.associationOpened(id)
            emit(.udpAssociated)
            // activeTCP intentionally remains unchanged: this metric counts
            // TCP CONNECT flows, not UDP control associations.
            sendControlResponses([reply], final: false) { success in
                guard success, !self.cleaned else { return }
                self.receiveUdpControl()
            }
        } catch {
            sendRequestFailure(0x01, event: .udpAssociateFailed)
        }
    }

    /// The endpoint a UDP ASSOCIATE request says the client will send from.
    ///
    /// Only the port is taken from the request. The host always comes from the
    /// control connection, because a declared host is attacker-controlled input:
    /// naming a third party made it the association's client, so datagrams from
    /// the real sender were classified as peer traffic and wrapped and forwarded
    /// to that third party — an open reflector. Nothing about a declared host is
    /// verifiable, and the peer of the TCP connection is, so the declaration
    /// contributes only the port it can legitimately narrow.
    private static func declaredUdpEndpoint(
        _ request: Socks5HandshakeParser.Request,
        controlPeer: String?
    ) -> (address: String, port: UInt16)? {
        guard request.target.port != 0, let controlPeer else { return nil }
        return (controlPeer, request.target.port)
    }

    private func receiveUdpControl() {
        assertQueue()
        guard !cleaned, udpAssociation != nil, !handshakeReceivePending else { return }
        handshakeReceivePending = true
        client.receive(minimumIncompleteLength: 1, maximumLength: Socks5HandshakeParser.maximumFeedBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.handshakeReceivePending = false
            guard !self.cleaned else { return }
            if isComplete || error != nil {
                self.cleanup(.udpControlClosed)
            } else {
                self.receiveUdpControl()
            }
            _ = data
        }
    }

    private func controlRemoteAddress() -> String? {
        assertQueue()
        guard case let .hostPort(host, _) = client.endpoint else { return nil }
        return String(describing: host)
            .components(separatedBy: "%").first
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
    }

    private func controlLocalAddress() -> String? {
        assertQueue()
        guard let endpoint = client.currentPath?.localEndpoint,
              case let .hostPort(host, _) = endpoint else {
            return nil
        }
        return String(describing: host).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private func beginTargetConnection(_ request: Socks5HandshakeParser.Request) {
        assertQueue()
        handshakeTimeout?.cancel()
        handshakeTimeout = nil
        guard !cleaned, target == nil,
              let port = NWEndpoint.Port(rawValue: request.target.port) else {
            sendRequestFailure(0x01)
            return
        }

        // NWEndpoint.Host(String) parses a string that already looks like an
        // IPv4 literal straight into `.ipv4` and never asks the resolver
        // anything; the NAT64 synthesis that makes an IPv6-only network reach
        // an IPv4 destination only happens for the `.name` case, i.e. when
        // resolution goes through a hostname. A CONNECT whose ATYP was a raw
        // IPv4 address (as opposed to a domain) would otherwise dial an
        // address the interface has no route for. getaddrinfo() performs the
        // same synthesis for a numeric string as it does for a hostname, so
        // route a literal through it before handing Network.framework a host.
        guard IPv4Address(request.target.address) != nil else {
            connectTarget(host: NWEndpoint.Host(request.target.address), port: port)
            return
        }

        let address = request.target.address
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !self.cleaned, self.target == nil else { return }
            self.synthesisTimeout = nil
            self.sendRequestFailure(0x04)
        }
        synthesisTimeout = timeout
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)

        Self.synthesisQueue.async { [weak self] in
            let host = Self.synthesizedHost(for: address)
            self?.queue.async {
                guard let self else { return }
                self.assertQueue()
                // Already fired (or the session moved on) — don't also start a
                // connection past that point.
                guard let pending = self.synthesisTimeout else { return }
                pending.cancel()
                self.synthesisTimeout = nil
                self.connectTarget(host: host, port: port)
            }
        }
    }

    private func connectTarget(host: NWEndpoint.Host, port: NWEndpoint.Port) {
        assertQueue()
        guard !cleaned, target == nil else { return }

        let target = NWConnection(
            host: host,
            port: port,
            using: NetworkTCPRelay.makeTCPParameters()
        )
        self.target = target
        target.stateUpdateHandler = { [weak self] state in
            self?.handleTargetState(state)
        }
        target.start(queue: queue)
    }

    /// Off the relay queue: getaddrinfo() is a blocking syscall and every
    /// session shares that queue, so resolving on it would stall unrelated
    /// connections for the DNS/synthesis round trip.
    private static let synthesisQueue = DispatchQueue(
        label: "com.nanako.socksbypass.benchmark.relay.tcp-synthesis",
        qos: .utility
    )

    /// Falls back to the plain literal wherever synthesis doesn't apply
    /// (ordinary dual-stack/IPv4 networks, or a lookup failure) — that
    /// reproduces exactly the pre-existing direct-dial behavior, so this
    /// only changes anything on a network where the literal had no route.
    private static func synthesizedHost(for literal: String) -> NWEndpoint.Host {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = literal.withCString { Darwin.getaddrinfo($0, nil, &hints, &result) }
        guard status == 0, let first = result else {
            return NWEndpoint.Host(literal)
        }
        defer { Darwin.freeaddrinfo(first) }

        guard first.pointee.ai_family == AF_INET6, let raw = first.pointee.ai_addr else {
            return NWEndpoint.Host(literal)
        }
        var address = sockaddr_in6()
        memcpy(&address, raw, MemoryLayout<sockaddr_in6>.size)
        let bytes = withUnsafeBytes(of: &address.sin6_addr) { Data($0) }
        guard let synthesized = IPv6Address(bytes) else {
            return NWEndpoint.Host(literal)
        }
        return .ipv6(synthesized)
    }

    /// The local address the outbound connection actually bound to, for BND.ADDR
    /// and BND.PORT. Returning zeros told clients nothing and reported IPv6
    /// targets as an IPv4 zero endpoint. Falls back to nil, which keeps the old
    /// all-zero reply, when the path has no usable local endpoint.
    private func boundEndpoint() -> Socks5HandshakeParser.BoundEndpoint? {
        assertQueue()
        guard case .hostPort(let host, let port)? = target?.currentPath?.localEndpoint else {
            return nil
        }
        // Raw bytes straight from the address, never a formatted string: an IPv6
        // description can carry a `%interface` scope that would not round-trip.
        switch host {
        case .ipv4(let address):
            return .init(atyp: 0x01, address: address.rawValue, port: port.rawValue)
        case .ipv6(let address):
            return .init(atyp: 0x04, address: address.rawValue, port: port.rawValue)
        default:
            return nil
        }
    }

    private func handleTargetState(_ state: NWConnection.State) {
        assertQueue()
        noteTargetState(state)
        guard !cleaned else { return }
        // Committing to a failure reply ends this request. Without this a path
        // that recovered to `.ready` inside the close window would send a second,
        // contradictory reply on the same session, and repeated `.waiting`
        // updates would each send another failure.
        guard !requestRejected else { return }

        switch state {
        case .ready:
            guard !targetReady else { return }
            targetReady = true
            // Only now is the outbound connection real. Emitting on construction
            // logged "CONNECT established" for every refused or unreachable
            // attempt, immediately followed by "CONNECT rejected".
            emit(.connectEstablished)
            let reply = Socks5HandshakeParser.requestReply(0x00, bound: boundEndpoint())
            sendControlResponses([reply], final: false) { success in
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
                        terminalError: self.pendingClientReadTruncated,
                        truncated: self.pendingClientReadTruncated
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
                sendRequestFailure(Self.replyCode(for: error))
            }

        case .cancelled:
            if !active {
                cleanup(.targetCancelledInactive)
            }

        case .waiting(let error):
            // Network.framework parks a refused or unreachable outbound connection
            // in .waiting and retries for as long as the path might become viable.
            // A proxy client is owed an answer instead: without this the CONNECT
            // never receives a reply and the session hangs indefinitely.
            if !active {
                sendRequestFailure(Self.replyCode(for: error))
            }

        case .setup, .preparing:
            break

        @unknown default:
            cleanup(.targetUnknownState)
        }
    }

    /// Sending the SOCKS failure reply and classifying the event are separate
    /// concerns: a UDP ASSOCIATE that fails is not a rejected CONNECT, and
    /// emitting both put two contradictory lines in the activity log. Pass `nil`
    /// when the caller has already emitted the right event.
    private func sendRequestFailure(
        _ reply: UInt8,
        event: NetworkTCPRelay.Event? = .connectRejected(reply: 0)
    ) {
        assertQueue()
        guard !cleaned, !requestRejected else { return }
        requestRejected = true
        switch event {
        case .connectRejected:
            emit(.connectRejected(reply: reply))
        case .some(let other):
            emit(other)
        case nil:
            break
        }
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

    /// The handshake parser's limit bounds a protocol message; it has no business
    /// bounding bulk payload. A cap is not an allocation, so raising it only means
    /// fewer queue hops per megabyte and less kernel buffer left undrained.
    private static let payloadReceiveBytes = 1024 * 1024

    private func receiveClientPayload() {
        assertQueue()
        guard active, !cleaned, !clientReadComplete, !clientReceivePending,
              !uploadSendPending else { return }
        clientReceivePending = true

        client.receive(minimumIncompleteLength: 1, maximumLength: Self.payloadReceiveBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.clientReceivePending = false
            guard !self.cleaned else { return }

            let payload = data ?? Data()
            self.noteReceived(payload.count, .upload, error: error, isComplete: isComplete)
            if !payload.isEmpty || isComplete {
                self.forward(payload, flow: .upload,
                             complete: isComplete || error != nil,
                             terminalError: error != nil,
                             truncated: error != nil && !isComplete)
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
        guard active, !cleaned, !targetReadComplete, !targetReceivePending,
              !downloadSendPending, let target else { return }
        targetReceivePending = true

        target.receive(minimumIncompleteLength: 1, maximumLength: Self.payloadReceiveBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.assertQueue()
            self.targetReceivePending = false
            guard !self.cleaned else { return }

            let payload = data ?? Data()
            self.noteReceived(payload.count, .download, error: error, isComplete: isComplete)
            if !payload.isEmpty || isComplete {
                self.forward(payload, flow: .download,
                             complete: isComplete || error != nil,
                             terminalError: error != nil,
                             truncated: error != nil && !isComplete)
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

    private func forward(_ data: Data, flow: Flow, complete: Bool, terminalError: Bool, truncated: Bool) {
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
                finishDirection(to: destination, flow: flow,
                                terminalError: terminalError, truncated: truncated)
            }
            return
        }

        setSendPending(flow, true)
        destination.send(
            content: data,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.assertQueue()
                guard !self.cleaned else { return }
                guard error == nil else {
                    self.setSendPending(flow, false)
                    self.cleanup(.forwardSendError)
                    return
                }

                self.counters.recordCommitted(data.count, direction: direction)
                self.note(data.count, direction)
                if complete {
                    // Stays pending: the half-close is the same direction's send.
                    self.finishDirection(to: destination, flow: flow,
                                         terminalError: terminalError, truncated: truncated)
                } else {
                    self.setSendPending(flow, false)
                    self.receiveNextPayload(for: flow)
                }
            }
        )
    }

    private func setSendPending(_ flow: Flow, _ pending: Bool) {
        assertQueue()
        switch flow {
        case .upload:
            uploadSendPending = pending
        case .download:
            downloadSendPending = pending
        }
    }

    /// A stream that ended in an error without the stack marking it complete was
    /// cut short. Passing that on as a clean FIN tells the peer the transfer ended
    /// normally, so a truncated download reads exactly like a whole one — silent
    /// corruption, which is the one outcome a proxy must never produce. Abort
    /// instead: a reset is the only in-band way to say the transfer failed.
    ///
    /// The cost is the tail we already forwarded but that the peer may not have
    /// read yet; a reset can discard it. That is the right trade. The bytes belong
    /// to a transfer that is already incomplete, and delivering them under a clean
    /// end-of-stream is what makes the loss invisible.
    private func finishDirection(to destination: NWConnection, flow: Flow,
                                 terminalError: Bool, truncated: Bool) {
        assertQueue()
        guard !cleaned else { return }
        guard truncated else {
            sendHalfClose(to: destination, flow: flow, terminalError: terminalError)
            return
        }
        setSendPending(flow, false)
        destination.forceCancel()
        cleanup(.upstreamTruncated)
    }

    private func sendHalfClose(to destination: NWConnection, flow: Flow, terminalError: Bool) {
        assertQueue()
        setSendPending(flow, true)
        destination.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.assertQueue()
                guard !self.cleaned else { return }
                self.setSendPending(flow, false)
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

    /// Reached only when a receive returned an error with nothing left to hand over
    /// and the direction never completed, so the stream is short. The drain that
    /// precedes this still runs: a receive cannot be issued while a forward is in
    /// flight, so by here everything we did receive has already been sent on. What
    /// is left is only the question of which end-of-stream the peer is told about,
    /// and a short stream must not be reported as a whole one.
    private func closeDirectionThenCleanup(to destination: NWConnection, flow: Flow) {
        assertQueue()
        guard !cleaned else { return }
        armCloseTimeout()
        finishDirection(to: destination, flow: flow, terminalError: true, truncated: true)
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
        synthesisTimeout?.cancel()
        synthesisTimeout = nil
        gracefulCloseTimeout?.cancel()
        gracefulCloseTimeout = nil

        client.stateUpdateHandler = nil
        target?.stateUpdateHandler = nil
        client.cancel()
        target?.cancel()
        if let udpAssociation {
            emit(.udpAssociateClosed(
                uploaded: udpAssociation.uploadedDatagramCount,
                downloaded: udpAssociation.downloadedDatagramCount,
                preLatchRejected: udpAssociation.preLatchRejectedCount
            ))
            udpAssociation.cancel()
            self.udpAssociation = nil
            counters.associationClosed(id)
        }
        if active {
            active = false
            counters.sessionClosed(id)
        }
        emit(.sessionClosed)
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
            if byteCount > 0 { lastDownloadByteAt = Date() }
            if isComplete { downloadSawFIN = true }
            guard let error else { return }
            downloadReceiveError = true
            // A multi-second gap means the connection sat idle and then died; a
            // gap near zero means it was torn down mid-stream. Different causes.
            downloadIdleBeforeError = Date().timeIntervalSince(lastDownloadByteAt ?? sessionStartedAt)
            if case .posix(let code) = error {
                downloadReceiveErrorCode = String(describing: code)
            } else {
                downloadReceiveErrorCode = "nonPosix"
            }
        }
    }

    /// Which states the target connection passed through, and when. This is the
    /// only way to tell a teardown we caused from one the stack handed us.
    private func noteTargetState(_ state: NWConnection.State) {
        guard targetStateTrace.count < 12 else { return }
        let name: String
        switch state {
        case .setup: name = "setup"
        case .preparing: name = "preparing"
        case .ready: name = "ready"
        case .cancelled: name = "cancelled"
        case .waiting(let error): name = "waiting(\(Self.codeName(error)))"
        case .failed(let error): name = "failed(\(Self.codeName(error)))"
        @unknown default: name = "unknown"
        }
        targetStateTrace.append(
            String(format: "%@@%.3f", name, Date().timeIntervalSince(sessionStartedAt))
        )
    }

    private static func codeName(_ error: NWError) -> String {
        if case .posix(let code) = error { return String(describing: code) }
        return "nonPosix"
    }

    private func diagnose(_ reason: CleanupReason) {
        let record: [String: Any] = [
            "relayClose": reason.rawValue,
            "targetStates": targetStateTrace,
            "downloadIdleBeforeError": downloadIdleBeforeError,
            "sessionSeconds": Date().timeIntervalSince(sessionStartedAt),
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
    private func noteTargetState(_ state: NWConnection.State) {}
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
