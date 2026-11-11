import XCTest
@testable import EnsembleCore

@MainActor
final class TrailingRefreshRunnerTests: XCTestCase {
    /// A request that arrives while a pass is running is not lost: the pass runs once more afterwards.
    func testRequestDuringPassTriggersOneTrailingPass() async {
        var started = 0
        var gate: CheckedContinuation<Void, Never>?
        let runner = TrailingRefreshRunner {
            started += 1
            if started == 1 { await withCheckedContinuation { gate = $0 } }
            return true
        }

        let first = Task { await runner.run() }
        while gate == nil { await Task.yield() }
        let second = Task { await runner.run() }
        let third = Task { await runner.run() }
        await Task.yield()
        gate?.resume()
        _ = await (first.value, second.value, third.value)

        XCTAssertEqual(started, 2)
        _ = await runner.run()
        XCTAssertEqual(started, 3)
    }

    /// When the caller driving a pass is cancelled, a request another caller made during it is still run.
    func testCancelledDriverHandsPendingRequestToALiveCaller() async {
        var started = 0
        var gate: CheckedContinuation<Void, Never>?
        let runner = TrailingRefreshRunner {
            started += 1
            if started == 1 { await withCheckedContinuation { gate = $0 } }
            return true
        }

        let driver = Task { await runner.run() }
        while gate == nil { await Task.yield() }
        let requester = Task { await runner.run() }
        await Task.yield()
        driver.cancel()
        gate?.resume()
        _ = await (driver.value, requester.value)

        XCTAssertEqual(started, 2)
    }

    /// Callers joining at different moments never make two passes overlap, whichever resumes first when a pass ends.
    func testPassesNeverOverlap() async {
        var active = 0
        var overlapped = false
        let runner = TrailingRefreshRunner {
            active += 1
            if active > 1 { overlapped = true }
            for _ in 0..<5 { await Task.yield() }
            active -= 1
            return true
        }

        var callers: [Task<Bool, Never>] = []
        for _ in 0..<8 {
            callers.append(Task { await runner.run() })
            for _ in 0..<3 { await Task.yield() }
        }
        for caller in callers { _ = await caller.value }

        XCTAssertFalse(overlapped)
    }
}
