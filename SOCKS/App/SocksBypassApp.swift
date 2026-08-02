import SwiftUI
#if RELAY_DIAGNOSTICS
import Darwin
import Foundation
#endif

@main
struct SocksBypassApp: App {
    @StateObject private var model = RelayViewModel()

    var body: some Scene {
        WindowGroup {
#if BENCHMARK
            // The measurement harness drives this same binary with
            // `--benchmark-mode`, which selects an engine and streams snapshots on
            // stdout. `BenchmarkRunner` links the HEV bridge, so it exists only in
            // the Benchmark configuration.
            if ProcessInfo.processInfo.arguments.contains("--benchmark-mode") {
                BenchmarkStatusView()
            } else {
                shell
            }
#else
            shell
#endif
        }
    }

    private var shell: some View {
        ContentView(model: model).task {
#if RELAY_DIAGNOSTICS
            if ProcessInfo.processInfo.arguments.contains("--halfclose-probe") {
                HalfCloseProbe.start()
                return
            }
#endif
            model.start()
        }
    }
}

#if RELAY_DIAGNOSTICS
/// Does a BSD socket still hand over bytes that were sitting in its receive
/// buffer when the connection finished closing? Network.framework does not, and
/// that is what truncates downloads. Answering this decides whether moving the
/// data path off Network.framework would actually fix anything.
///
/// Mirrors the losing shape exactly: write-close first, then stay out of the
/// socket while the peer sends and closes, then try to drain.
enum HalfCloseProbe {
    static func start(port: UInt16 = 9877) {
        Thread.detachNewThread {
            let listener = socket(AF_INET6, SOCK_STREAM, 0)
            guard listener >= 0 else { return emit(["probeError": "socket"]) }
            var on: Int32 = 1
            var off: Int32 = 0
            setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(listener, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard bound == 0, listen(listener, 8) == 0 else {
                emit(["probeError": "bind", "probeErrno": Int(errno)])
                close(listener)
                return
            }
            emit(["probeReady": Int(port)])

            while true {
                let connection = accept(listener, nil, nil)
                guard connection >= 0 else { continue }
                drainAfterHalfClose(connection)
                close(connection)
            }
        }
    }

    private static func drainAfterHalfClose(_ fd: Int32) {
        shutdown(fd, SHUT_WR)
        // Deliberately not reading: the peer sends and closes during this window,
        // so the bytes are buffered and both FINs are exchanged before we drain.
        Thread.sleep(forTimeInterval: 0.3)

        var total = 0
        var failure = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                total += count
                continue
            }
            if count < 0 { failure = Int(errno) }
            break
        }
        emit(["probeReceived": total, "probeErrno": failure])
    }

    private static func emit(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            return
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
#endif

#if BENCHMARK
private struct BenchmarkStatusView: View {
    @State private var status = "starting"
    @State private var mode = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("BENCHMARK ONLY \(mode)")
            Text(status).font(.caption)
        }
        .monospaced()
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .task {
            mode = BenchmarkRunner.start { value in
                status = value as String
            } as String
        }
    }
}
#endif
