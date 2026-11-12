import XCTest
@testable import EnsembleCore

@MainActor
final class SharedRestorationTests: XCTestCase {
    private final class Counter { var runs = 0 }

    /// Concurrent callers share one run; a caller that times out is told the work is not done, and a later caller
    /// joins the same run rather than starting another.
    func testCallersShareOneRunAndATimeoutIsNotDone() async {
        let restoration = SharedRestoration()
        let counter = Counter()
        let slow: @MainActor () async -> Void = {
            counter.runs += 1
            try? await Task.sleep(for: .milliseconds(300))
        }

        async let first = restoration.ensure(timeout: .milliseconds(50), work: slow)
        async let second = restoration.ensure(timeout: .milliseconds(50), work: slow)
        let early = await [first, second]
        XCTAssertEqual(early, [false, false], "a timeout fails closed")
        XCTAssertFalse(restoration.isDone)

        let later = await restoration.ensure(timeout: .seconds(2), work: slow)
        XCTAssertTrue(later)
        XCTAssertEqual(counter.runs, 1, "one run served every caller")

        let again = await restoration.ensure(timeout: .milliseconds(1), work: slow)
        XCTAssertTrue(again)
        XCTAssertEqual(counter.runs, 1, "finished work is not repeated")
    }
}
