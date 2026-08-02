import SwiftUI

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
        ContentView(model: model).task { model.start() }
    }
}

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
