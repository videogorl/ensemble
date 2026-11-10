import XCTest
@testable import EnsembleCore

final class DirectDownloadGateTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// One direct download per server: a waiting prefetch starts the moment the current
    /// download ends, never while it runs, and is not starved when nothing is downloading.
    func testPrefetchWaitsForTheCurrentDownloadOfTheSameServerOnly() async throws {
        let gate = DirectDownloadGate()
        let idle = try await gate.acquire("a:1")
        idle.release()

        let current = gate.enter("a:1")
        let other = try await gate.acquire("b:1")
        other.release()

        let started = Flag()
        let prefetch = Task {
            let slot = try await gate.acquire("a:1")
            started.set()
            return slot
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(started.isSet, "the prefetch waits while the current download runs")

        current.release()
        let slot = try await prefetch.value
        XCTAssertTrue(started.isSet)

        // A third download waits for the prefetch that now holds the slot; dropping the holder frees it.
        let third = Task { try await gate.acquire("a:1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        slot.release()
        let thirdSlot = try await third.value
        thirdSlot.release()
    }

    func testCancelledPrefetchLeavesTheQueueAndTheSlotFreesOnRelease() async throws {
        let gate = DirectDownloadGate()
        let current = gate.enter("a:1")
        let prefetch = Task { try await gate.acquire("a:1") }
        try await Task.sleep(nanoseconds: 50_000_000)
        prefetch.cancel()
        do {
            _ = try await prefetch.value
            XCTFail("a cancelled wait throws")
        } catch is CancellationError {}

        current.release()
        current.release()
        let next = try await gate.acquire("a:1")
        next.release()
    }
}
