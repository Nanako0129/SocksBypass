import Foundation
import XCTest

final class ProcessUsageTests: XCTestCase {
    func testCPUIsCumulativeAndPeakRSSIsReportedInBytes() {
        let first = ProcessUsage.current()

        XCTAssertGreaterThan(first.cpuSeconds, 0)

        // Darwin reports ru_maxrss in bytes; Linux reports kilobytes. A process this
        // size would land near 10^5 under the kilobyte reading, so this bound fails
        // loudly if the unit assumption ever changes.
        XCTAssertGreaterThan(first.peakRSSBytes, 1_000_000)

        var sink = 0
        for value in 0..<2_000_000 { sink &+= value }
        XCTAssertGreaterThan(sink, 0)

        let second = ProcessUsage.current()
        XCTAssertGreaterThanOrEqual(second.cpuSeconds, first.cpuSeconds)
        XCTAssertGreaterThanOrEqual(second.peakRSSBytes, first.peakRSSBytes)
    }
}
