import Foundation
import Combine
import AVFAudio
import Darwin

/// Drives the SwiftUI shell from the relay's one-second snapshots.
///
/// Totals are process-lifetime cumulative and come straight from `TrafficCounters`.
/// Speed is derived here by differencing consecutive snapshots, so it is a
/// measured rate rather than a second counter that could drift from the totals.
@MainActor
final class RelayViewModel: ObservableObject {
    enum Status: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// One address a client could point at, kept with the interface it came from.
    /// Picking a single "the" address was wrong: the hotspot gateway and the
    /// Wi-Fi address live on different interfaces and only the user knows which
    /// way their client is arriving.
    struct Endpoint: Identifiable, Equatable {
        let interface: String
        let address: String
        let role: String

        var id: String { "\(interface)|\(address)" }
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var endpoints: [Endpoint] = []
    @Published private(set) var backgroundActive = false
    @Published private(set) var uploadBytes: UInt64 = 0
    @Published private(set) var downloadBytes: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var activeTCP = 0
    @Published private(set) var activeUDP = 0
    @Published private(set) var log: [LogEntry] = []

    struct LogEntry: Identifiable, Equatable {
        let id = UUID()
        let at: Date
        let text: String
    }

    var activeTotal: Int { activeTCP + activeUDP }

    private let relay = NetworkTCPRelay(countingEnabled: true)
    private let keepAlive = BackgroundKeepAlive()
    private var timer: Timer?
    private var lastSample: (upload: UInt64, download: UInt64, at: Date)?

    func start() {
        guard timer == nil else { return }
        relay.eventHandler = { [weak self] event in
            Task { @MainActor in self?.append(Self.describe(event)) }
        }
        relay.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.status = .listening(port: port)
                    self.endpoints = Self.localEndpoints()
                    self.append("listening on \(port)")
                    self.keepAlive.start()
                    self.append(self.keepAlive.isActive
                                ? "background audio holding the app awake"
                                : "background audio unavailable")
                case .failure(let error):
                    let reason = Self.describe(error)
                    self.status = .failed(reason)
                    self.append(reason)
                }
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Bounded ring: the shell keeps the most recent entries and nothing else, so
    /// a long-running proxy cannot grow this without limit.
    private static let logLimit = 50

    private func append(_ text: String) {
        log.append(LogEntry(at: Date(), text: text))
        if log.count > Self.logLimit {
            log.removeFirst(log.count - Self.logLimit)
        }
    }

    private static func describe(_ event: NetworkTCPRelay.Event) -> String {
        switch event {
        case .sessionOpened: return "session opened"
        case .sessionClosed: return "session closed"
        case .connectEstablished: return "CONNECT established"
        case .connectRejected(let reply): return String(format: "CONNECT rejected 0x%02x", reply)
        case .udpAssociated: return "UDP ASSOCIATE established"
        case .udpAssociateFailed: return "UDP ASSOCIATE failed"
        }
    }

    private func sample() {
        // Addresses are re-read every tick rather than once at startup. Toggling
        // Wi-Fi or turning on the hotspot changes them, and the old code showed
        // whatever happened to be there the moment the listener came up.
        let current = Self.localEndpoints()
        if current != endpoints { endpoints = current }

        // Cheap self-heal: an interruption (a call, a route change) stops the
        // audio session, and without it the app is suspended the next time it
        // leaves the screen.
        keepAlive.resumeIfNeeded()
        if backgroundActive != keepAlive.isActive { backgroundActive = keepAlive.isActive }

        relay.snapshot { [weak self] snapshot in
            Task { @MainActor in
                guard let self else { return }
                let now = Date()
                if let previous = self.lastSample {
                    let elapsed = now.timeIntervalSince(previous.at)
                    if elapsed >= 0.2 {
                        self.uploadBytesPerSecond =
                            Self.rate(from: previous.upload, to: snapshot.uploadBytes, seconds: elapsed)
                        self.downloadBytesPerSecond =
                            Self.rate(from: previous.download, to: snapshot.downloadBytes, seconds: elapsed)
                    }
                }
                self.lastSample = (snapshot.uploadBytes, snapshot.downloadBytes, now)
                self.uploadBytes = snapshot.uploadBytes
                self.downloadBytes = snapshot.downloadBytes
                self.activeTCP = snapshot.activeTCP
                self.activeUDP = snapshot.activeUDP
            }
        }
    }

    private static func rate(from previous: UInt64, to current: UInt64, seconds: TimeInterval) -> UInt64 {
        guard current >= previous else { return 0 }
        return UInt64(Double(current - previous) / seconds)
    }

    private static func describe(_ error: NetworkTCPRelay.RelayError) -> String {
        switch error {
        case .alreadyRunning: return "relay already running"
        case .listenerSetup: return "listener setup failed"
        case .listenerFailed: return "listener failed"
        case .cancelled: return "listener cancelled"
        }
    }

    /// Every IPv4 address a LAN or hotspot client could actually reach, newest
    /// state each call. Cellular is left out on purpose: carrier NAT makes it
    /// unreachable from outside, and offering it as the address to type in is
    /// worse than offering nothing.
    static func localEndpoints() -> [Endpoint] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var found: [Endpoint] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else {
                continue
            }
            let name = String(cString: interface.ifa_name)
            guard let role = Self.role(for: name) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            found.append(Endpoint(interface: name, address: String(cString: host), role: role))
        }
        // Hotspot first: it is the address a tethered client needs and the one
        // the previous single-address picker could never return.
        return found.sorted { Self.rank($0.role) < Self.rank($1.role) }
    }

    /// `nil` means "never worth showing". Anything not recognised is still shown
    /// under its own interface name rather than guessed at or dropped.
    private static func role(for interface: String) -> String? {
        switch true {
        case interface.hasPrefix("lo"),
             interface.hasPrefix("utun"),
             interface.hasPrefix("ipsec"),
             interface.hasPrefix("awdl"),
             interface.hasPrefix("llw"),
             interface.hasPrefix("pdp_ip"):
            return nil
        case interface.hasPrefix("bridge"), interface.hasPrefix("ap"):
            return "HOTSPOT"
        case interface == "en0":
            return "WI-FI"
        default:
            return interface.uppercased()
        }
    }

    private static func rank(_ role: String) -> Int {
        switch role {
        case "HOTSPOT": return 0
        case "WI-FI": return 1
        default: return 2
        }
    }
}

/// iOS suspends an ordinary app seconds after it leaves the screen, taking the
/// listener and every live connection with it. An active audio session is what
/// keeps a plain app scheduled, so the relay plays silence for as long as it is
/// serving. `.mixWithOthers` leaves whatever the user is actually listening to
/// alone, and the buffer is all zeroes, so nothing is audible.
///
/// This restores behaviour the pre-Swift app had and the rewrite dropped: the
/// original kept itself alive the same way, with a blank WAV asset. Generating
/// the silence removes the asset.
@MainActor
final class BackgroundKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silence: AVAudioPCMBuffer?
    private var wanted = false

    var isActive: Bool { engine.isRunning && player.isPlaying }

    init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else {
            silence = nil
            return
        }
        buffer.frameLength = buffer.frameCapacity      // already zeroed
        silence = buffer
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() {
        guard !wanted else { return }
        wanted = true
        resumeIfNeeded()
    }

    func resumeIfNeeded() {
        guard wanted, !isActive, let silence else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            player.stop()                              // clears any stale schedule
            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
        } catch {
            // Left inactive on purpose. The next tick tries again, and the shell
            // shows the state rather than pretending the app will survive
            // backgrounding.
        }
    }
}
