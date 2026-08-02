import Foundation

/// Whole-process CPU and peak resident size.
///
/// `getrusage` covers live and finished threads in one call and reports
/// `ru_maxrss` in bytes on Darwin, so it supplies what the core comparison needs
/// without an Instruments trace. Both figures are cumulative for the process, so
/// a per-run CPU figure is the difference between two samples.
enum ProcessUsage {
    static func current() -> (cpuSeconds: Double, peakRSSBytes: Int) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0) }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return (seconds(usage.ru_utime) + seconds(usage.ru_stime), Int(usage.ru_maxrss))
    }
}
