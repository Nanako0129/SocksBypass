import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RelayViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                endpoint
                background
                exposureWarning
                speed
                totals
                sessions
                activity
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .monospaced()
    }

    private var endpoint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SOCKS5").font(.caption).foregroundStyle(.secondary)
            switch model.status {
            case .starting:
                Text("starting…").font(.title2)
            case .listening(let port):
                // Every reachable address, not a guess at which one matters. The
                // hotspot gateway and the Wi-Fi address are different interfaces
                // and only the user knows how their client is arriving.
                if model.endpoints.isEmpty {
                    Text("no reachable address").font(.title3).foregroundStyle(.orange)
                } else {
                    ForEach(model.endpoints) { endpoint in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(endpoint.role)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 64, alignment: .leading)
                            Text("\(endpoint.address):\(String(port))")
                                .font(.title3)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("NO AUTH · CONNECT · UDP ASSOCIATE")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.title3).foregroundStyle(.red)
            }
        }
    }

    /// Whether the app will survive being backgrounded or the screen locking.
    /// Without this the only way to tell was to probe the port from another
    /// machine and find out the hard way.
    private var background: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.backgroundActive ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(model.backgroundActive
                 ? "BACKGROUND · keeps running when closed or locked"
                 : "FOREGROUND ONLY · stops when closed or locked")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Always visible, never dismissible: the proxy is unauthenticated and this
    /// is the only thing standing between the user and an open relay.
    private var exposureWarning: some View {
        Text("Any device that can reach this address can use this proxy. There is no password. Use it only on a network you control.")
            .font(.footnote)
            .foregroundStyle(.black)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var speed: some View {
        HStack(spacing: 32) {
            metric("↑", ByteFormat.rate(model.uploadBytesPerSecond))
            metric("↓", ByteFormat.rate(model.downloadBytesPerSecond))
        }
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOTAL").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 32) {
                metric("↑", ByteFormat.size(model.uploadBytes))
                metric("↓", ByteFormat.size(model.downloadBytes))
            }
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SESSIONS").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                metric("TCP", String(model.activeTCP))
                metric("UDP", String(model.activeUDP))
                metric("ALL", String(model.activeTotal))
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVITY").font(.caption).foregroundStyle(.secondary)
            if model.log.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                ForEach(model.log.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.at, format: .dateTime.hour().minute().second())
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(entry.text).font(.caption)
                    }
                }
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3)
        }
    }
}

enum ByteFormat {
    static func size(_ bytes: UInt64) -> String {
        format(Double(bytes), units: ["B", "KB", "MB", "GB", "TB"])
    }

    static func rate(_ bytesPerSecond: UInt64) -> String {
        format(Double(bytesPerSecond), units: ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"])
    }

    private static func format(_ value: Double, units: [String]) -> String {
        var value = value
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(Int(value)) \(units[0])"
            : String(format: "%.1f %@", value, units[index])
    }
}
