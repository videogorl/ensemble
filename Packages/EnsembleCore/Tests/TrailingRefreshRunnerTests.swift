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
}
