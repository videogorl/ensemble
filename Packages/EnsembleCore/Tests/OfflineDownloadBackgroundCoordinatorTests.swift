import XCTest
@testable import EnsembleCore

@MainActor
final class OfflineDownloadBackgroundCoordinatorTests: XCTestCase {
    func testBatchProgressCountsUniqueWorkAndNeverRegressesDuringFallback() {
        var progress = OfflineDownloadBatchProgress()
        progress.include(["a", "a", "b"])
        progress.update("a", fraction: 0.9)
        progress.update("a", fraction: 0.2) // Original fallback starts after a rejected transcode.
        progress.update("b", fraction: .nan)
        progress.update("unrelated", fraction: 1)
        XCTAssertEqual(progress.completedUnitCount, 900)
        XCTAssertEqual(progress.totalUnitCount, 2_000)
        progress.include(["a", "c"])
        progress.update("a", fraction: 1)
        progress.update("b", fraction: 0.99)
        progress.update("c", fraction: -1)
        XCTAssertEqual(progress.completedUnitCount, 1_990)
        XCTAssertEqual(progress.totalUnitCount, 3_000)
        progress.update("b", fraction: 2)
        progress.update("c", fraction: 1)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
    }

    func testBackgroundURLSessionCompletionWaitsForRecoveryCallback() async {
        let coordinator = OfflineBackgroundExecutionCoordinator()
        var receivedIdentifier: String?
        var deferredCompletion: (() -> Void)?
        var completionCount = 0

        coordinator.onBackgroundURLSessionEvents = { identifier, completion in
            receivedIdentifier = identifier
            deferredCompletion = completion
        }

        coordinator.handleBackgroundURLSessionEvents(identifier: "com.test.downloads") {
            completionCount += 1
        }

        XCTAssertEqual(receivedIdentifier, "com.test.downloads")
        XCTAssertEqual(completionCount, 0)

        deferredCompletion?()
        await Task.yield()
        XCTAssertEqual(completionCount, 1)

        coordinator.completeBackgroundURLSessionEvents(identifier: "com.test.downloads")
        XCTAssertEqual(completionCount, 1)
    }

    func testBackgroundURLSessionCompletesImmediatelyWithoutRecoveryHandler() {
        let coordinator = OfflineBackgroundExecutionCoordinator()
        var completionCount = 0

        coordinator.handleBackgroundURLSessionEvents(identifier: "com.test.unhandled") {
            completionCount += 1
        }

        XCTAssertEqual(completionCount, 1)
    }

    func testSystemSleepWakeHooksRouteThroughCoordinator() {
        let coordinator = OfflineBackgroundExecutionCoordinator()
        var events: [String] = []
        coordinator.onSystemWillSleep = { events.append("sleep") }
        coordinator.onSystemDidWake = { events.append("wake") }

        coordinator.handleSystemWillSleep()
        coordinator.handleSystemDidWake()

        XCTAssertEqual(events, ["sleep", "wake"])
    }
}
