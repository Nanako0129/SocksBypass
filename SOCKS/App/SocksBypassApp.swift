import SwiftUI

@main
struct SocksBypassApp: App {
    @StateObject private var model = RelayViewModel()

    /// The benchmark harness drives the same binary with `--benchmark-mode`, which
    /// selects an engine and streams snapshots on stdout. Without it we are the
    /// product: start the Network.framework core and show the shell.
    private let benchmarkMode = ProcessInfo.processInfo.arguments.contains("--benchmark-mode")

    var body: some Scene {
        WindowGroup {
            Group {
                if benchmarkMode {
                    BenchmarkStatusView()
                } else {
                    ContentView(model: model)
                        .task { model.start() }
                }
            }
        }
    }
}

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
