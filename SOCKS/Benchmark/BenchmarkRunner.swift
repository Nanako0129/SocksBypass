import Foundation

@objc(BenchmarkRunner)
final class BenchmarkRunner: NSObject {
    private enum Mode: String {
        case hevRaw = "HEV-RAW"
        case networkRaw = "NW-RAW"
        case networkStats = "NW-STATS"
    }

    private static var current: BenchmarkRunner?

    private let mode: Mode
    private let statusHandler: (NSString) -> Void
    private let snapshotQueue = DispatchQueue(label: "com.nanako.socksbypass.benchmark.snapshots")
    private var relay: NetworkTCPRelay?
    private var hev: HevSocks5ServerEngine?
    private var timer: DispatchSourceTimer?

    private init(mode: Mode, statusHandler: @escaping (NSString) -> Void) {
        self.mode = mode
        self.statusHandler = statusHandler
    }

    @objc(startWithStatusHandler:)
    static func start(statusHandler: @escaping (NSString) -> Void) -> NSString {
        if let current {
            return current.mode.rawValue as NSString
        }

        guard let mode = requestedMode(from: ProcessInfo.processInfo.arguments) else {
            statusHandler("error=configuration-invalid")
            return "INVALID"
        }

        let runner = BenchmarkRunner(mode: mode, statusHandler: statusHandler)
        current = runner
        runner.start()
        return mode.rawValue as NSString
    }

    private static func requestedMode(from arguments: [String]) -> Mode? {
        let selectors = arguments.indices.filter { arguments[$0] == "--benchmark-mode" }
        guard selectors.count == 1,
              !arguments.contains(where: { $0.hasPrefix("--benchmark-mode=") }),
              selectors[0] + 1 < arguments.count else {
            return nil
        }
        return Mode(rawValue: arguments[selectors[0] + 1])
    }

    private func start() {
        switch mode {
        case .hevRaw:
            let engine = HevSocks5ServerEngine()
            hev = engine
            emit("counters=disabled raw-mode")
            startRawSnapshots()
            engine.start { [weak self] succeeded in
                guard !succeeded else { return }
                self?.emit("error=hev-engine-failed")
            }

        case .networkRaw, .networkStats:
            let countingEnabled = mode == .networkStats
            let relay = NetworkTCPRelay(countingEnabled: countingEnabled)
            self.relay = relay
            relay.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.startNetworkSnapshots(countingEnabled: countingEnabled)
                case .failure(let error):
                    self.emit("error=\(self.category(for: error))" as NSString)
                }
            }
        }
    }

    private func startNetworkSnapshots(countingEnabled: Bool) {
        let timer = DispatchSource.makeTimerSource(queue: snapshotQueue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self, let relay = self.relay else { return }
            relay.snapshot { [weak self] snapshot in
                self?.emit(snapshot, countingEnabled: countingEnabled)
            }
        }
        self.timer = timer
        timer.resume()
    }

    private func startRawSnapshots() {
        let timer = DispatchSource.makeTimerSource(queue: snapshotQueue)
        timer.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.emit(
                TrafficCounters.Snapshot(uploadBytes: 0, downloadBytes: 0, activeTCP: 0),
                countingEnabled: false
            )
        }
        self.timer = timer
        timer.resume()
    }

    private func emit(_ snapshot: TrafficCounters.Snapshot, countingEnabled: Bool) {
        let status: NSString
        if countingEnabled {
            status = "upload=\(snapshot.uploadBytes) download=\(snapshot.downloadBytes) activeTCP=\(snapshot.activeTCP)" as NSString
        } else {
            status = "counters=disabled raw-mode" as NSString
        }
        emit(status)

        let usage = ProcessUsage.current()
        let json: [String: Any] = [
            "mode": mode.rawValue,
            "countersEnabled": countingEnabled,
            "uploadBytes": NSNumber(value: snapshot.uploadBytes),
            "downloadBytes": NSNumber(value: snapshot.downloadBytes),
            "activeTCP": snapshot.activeTCP,
            "cpuSeconds": usage.cpuSeconds,
            "peakRSSBytes": NSNumber(value: usage.peakRSSBytes)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private func emit(_ status: NSString) {
        DispatchQueue.main.async {
            self.statusHandler(status)
        }
    }

    private func category(for error: NetworkTCPRelay.RelayError) -> String {
        switch error {
        case .alreadyRunning:
            return "relay-state"
        case .listenerSetup:
            return "listener-setup"
        case .listenerFailed:
            return "listener-failed"
        case .cancelled:
            return "listener-cancelled"
        }
    }
}

private final class HevSocks5ServerEngine {
    private let queue = DispatchQueue(label: "com.nanako.socksbypass.benchmark.hev", qos: .userInitiated)
    private let lock = NSLock()
    private var started = false

    private static let configuration = Data("""
    main:
      workers: 4
      port: 9876
      listen-address: '0.0.0.0'
      listen-ipv6-only: false
    misc:
      log-file: /dev/null
      log-level: error
    """.utf8)

    func start(onExit: @escaping (Bool) -> Void) {
        lock.lock()
        guard !started else {
            lock.unlock()
            onExit(false)
            return
        }
        started = true
        lock.unlock()

        queue.async {
            let result = Self.configuration.withUnsafeBytes { bytes -> Int32 in
                let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
                return hev_socks5_server_main_from_str(pointer, UInt32(Self.configuration.count))
            }

            self.lock.lock()
            self.started = false
            self.lock.unlock()
            onExit(result == 0)
        }
    }

    func stop() {
        lock.lock()
        let shouldStop = started
        lock.unlock()
        if shouldStop {
            hev_socks5_server_quit()
        }
    }
}
