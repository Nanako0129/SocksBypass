import Foundation
import Combine
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
        case listening(address: String, port: UInt16)
        case failed(String)
    }

    @Published private(set) var status: Status = .starting
    @Published private(set) var uploadBytes: UInt64 = 0
    @Published private(set) var downloadBytes: UInt64 = 0
    @Published private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published private(set) var downloadBytesPerSecond: UInt64 = 0
    @Published private(set) var activeTCP = 0
    @Published private(set) var activeUDP = 0

    var activeTotal: Int { activeTCP + activeUDP }

    private let relay = NetworkTCPRelay(countingEnabled: true)
    private var timer: Timer?
    private var lastSample: (upload: UInt64, download: UInt64, at: Date)?

    func start() {
        guard timer == nil else { return }
        relay.start { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let port):
                    self.status = .listening(address: Self.localAddress() ?? "0.0.0.0", port: port)
                case .failure(let error):
                    self.status = .failed(Self.describe(error))
                }
            }
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sample() {
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

    /// First private IPv4 on a non-loopback, non-tunnel interface. This is the
    /// address a LAN peer would point its proxy settings at.
    static func localAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(first) }

        var candidate: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let addr = interface.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else {
                continue
            }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo"), !name.hasPrefix("utun"), !name.hasPrefix("ipsec") else {
                continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let text = String(cString: host)
            if name.hasPrefix("en") { return text }
            if candidate == nil { candidate = text }
        }
        return candidate
    }
}
