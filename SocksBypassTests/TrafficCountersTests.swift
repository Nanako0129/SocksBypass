import Foundation
import XCTest

final class TrafficCountersTests: XCTestCase {
    func testDirectionAndExactCommittedPayloadBytes() {
        let queue = DispatchQueue(label: "TrafficCountersTests.direction")
        let counters = TrafficCounters(queue: queue, enabled: true)

        let snapshot = queue.sync { () -> TrafficCounters.Snapshot in
            counters.recordCommitted(17_000_003, direction: .upload)
            counters.recordCommitted(13_000_007, direction: .download)
            counters.recordCommitted(0, direction: .upload)
            return counters.snapshot()
        }

        XCTAssertEqual(snapshot, .init(uploadBytes: 17_000_003, downloadBytes: 13_000_007, activeTCP: 0))
    }

    func testSessionOpenAndCleanupAreExactlyOnce() {
        let queue = DispatchQueue(label: "TrafficCountersTests.sessions")
        let counters = TrafficCounters(queue: queue, enabled: true)
        let session = UUID()

        let snapshots = queue.sync { () -> [TrafficCounters.Snapshot] in
            counters.sessionOpened(session)
            counters.sessionOpened(session)
            let open = counters.snapshot()
            counters.sessionClosed(session)
            counters.sessionClosed(session)
            let closed = counters.snapshot()
            return [open, closed]
        }

        XCTAssertEqual(snapshots[0].activeTCP, 1)
        XCTAssertEqual(snapshots[1].activeTCP, 0)
    }

    func testStopRestartRetainsTotalsButClearsSessions() {
        let queue = DispatchQueue(label: "TrafficCountersTests.restart")
        let counters = TrafficCounters(queue: queue, enabled: true)

        let snapshots = queue.sync { () -> [TrafficCounters.Snapshot] in
            let stale = UUID()
            counters.sessionOpened(stale)
            counters.recordCommitted(11, direction: .upload)
            counters.recordCommitted(13, direction: .download)
            counters.closeAllSessions()
            let stopped = counters.snapshot()

            let restarted = UUID()
            counters.sessionOpened(restarted)
            counters.recordCommitted(17, direction: .upload)
            counters.recordCommitted(19, direction: .download)
            counters.sessionClosed(restarted)
            return [stopped, counters.snapshot()]
        }

        XCTAssertEqual(snapshots[0], .init(uploadBytes: 11, downloadBytes: 13, activeTCP: 0))
        XCTAssertEqual(snapshots[1], .init(uploadBytes: 28, downloadBytes: 32, activeTCP: 0))
    }

    func testProcessRelaunchStartsAtZero() {
        let queue = DispatchQueue(label: "TrafficCountersTests.relaunch")
        let first = TrafficCounters(queue: queue, enabled: true)
        queue.sync {
            first.recordCommitted(99, direction: .upload)
        }

        let relaunched = TrafficCounters(queue: queue, enabled: true)
        XCTAssertEqual(
            queue.sync { relaunched.snapshot() },
            .init(uploadBytes: 0, downloadBytes: 0, activeTCP: 0)
        )
    }

    func testRawModeDoesNotCountHotPathOrSessions() {
        let queue = DispatchQueue(label: "TrafficCountersTests.raw")
        let counters = TrafficCounters(queue: queue, enabled: false)

        let snapshot = queue.sync { () -> TrafficCounters.Snapshot in
            let session = UUID()
            counters.sessionOpened(session)
            counters.recordCommitted(1_000_000, direction: .upload)
            counters.recordCommitted(2_000_000, direction: .download)
            counters.sessionClosed(session)
            return counters.snapshot()
        }

        XCTAssertEqual(snapshot, .init(uploadBytes: 0, downloadBytes: 0, activeTCP: 0))
    }
}
