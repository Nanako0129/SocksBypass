import Foundation

final class TrafficCounters {
    enum Direction {
        case upload
        case download
    }

    struct Snapshot: Equatable {
        let uploadBytes: UInt64
        let downloadBytes: UInt64
        let activeTCP: Int
        var activeUDP: Int = 0

        var activeTotal: Int { activeTCP + activeUDP }
    }

    private let queue: DispatchQueue
    private let enabled: Bool
    private var uploadBytes: UInt64 = 0
    private var downloadBytes: UInt64 = 0
    private var activeSessions = Set<UUID>()
    private var activeAssociations = Set<UUID>()

    init(queue: DispatchQueue, enabled: Bool) {
        self.queue = queue
        self.enabled = enabled
    }

    func sessionOpened(_ id: UUID) {
        assertQueue()
        guard enabled else { return }
        activeSessions.insert(id)
    }

    func sessionClosed(_ id: UUID) {
        assertQueue()
        guard enabled else { return }
        activeSessions.remove(id)
    }

    /// UDP associations are counted separately: an association is not a
    /// connection, and `activeTCP` stays a CONNECT-only metric.
    func associationOpened(_ id: UUID) {
        assertQueue()
        guard enabled else { return }
        activeAssociations.insert(id)
    }

    func associationClosed(_ id: UUID) {
        assertQueue()
        guard enabled else { return }
        activeAssociations.remove(id)
    }

    func closeAllSessions() {
        assertQueue()
        activeSessions.removeAll(keepingCapacity: true)
        activeAssociations.removeAll(keepingCapacity: true)
    }

    func recordCommitted(_ byteCount: Int, direction: Direction) {
        assertQueue()
        guard enabled, byteCount > 0 else { return }

        let amount = UInt64(byteCount)
        switch direction {
        case .upload:
            uploadBytes = addingWithoutCrash(uploadBytes, amount)
        case .download:
            downloadBytes = addingWithoutCrash(downloadBytes, amount)
        }
    }

    func snapshot() -> Snapshot {
        assertQueue()
        return Snapshot(
            uploadBytes: uploadBytes,
            downloadBytes: downloadBytes,
            activeTCP: activeSessions.count,
            activeUDP: activeAssociations.count
        )
    }

    func snapshot(_ completion: @escaping (Snapshot) -> Void) {
        queue.async {
            completion(self.snapshot())
        }
    }

    private func assertQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }

    private func addingWithoutCrash(_ current: UInt64, _ amount: UInt64) -> UInt64 {
        let (sum, overflowed) = current.addingReportingOverflow(amount)
        return overflowed ? UInt64.max : sum
    }
}
