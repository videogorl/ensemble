import XCTest
@testable import EnsembleCore

@MainActor
final class OfflineDownloadBackgroundCoordinatorTests: XCTestCase {
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
