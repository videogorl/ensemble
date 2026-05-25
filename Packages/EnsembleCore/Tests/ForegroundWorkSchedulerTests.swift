import XCTest
@testable import EnsembleCore

@MainActor
final class ForegroundWorkSchedulerTests: XCTestCase {
    func testIdleRequiresNoBlockingInteractionForConfiguredDelay() {
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 1.5,
                pollingInterval: 0.01
            ),
            now: { now }
        )

        scheduler.clearLaunchState()
        XCTAssertFalse(scheduler.isIdleForNonessentialWork)

        now.addTimeInterval(1.6)
        XCTAssertTrue(scheduler.isIdleForNonessentialWork)

        scheduler.beginInteraction(.nowPlayingInteractive)
        now.addTimeInterval(3)
        XCTAssertFalse(scheduler.isIdleForNonessentialWork)

        scheduler.endInteraction(.nowPlayingInteractive)
        XCTAssertFalse(scheduler.isIdleForNonessentialWork)

        now.addTimeInterval(1.6)
        XCTAssertTrue(scheduler.isIdleForNonessentialWork)
    }

    func testIdleOnlyWorkWaitsForShareSheetToDismiss() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 0,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.beginInteraction(.shareSheetPresenting)

        var didRun = false
        let task = Task { @MainActor in
            await scheduler.waitUntilAllowed(.systemMediaIndexing, policy: .idleOnly)
            didRun = true
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(didRun)

        scheduler.endInteraction(.shareSheetPresenting)
        await task.value
        XCTAssertTrue(didRun)
    }

    func testStartupSyncExcludesIdleWork() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 0,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.setStartupSyncInFlight(true)

        var didRun = false
        let task = Task { @MainActor in
            await scheduler.waitUntilAllowed(.offlineHealing, policy: .idleOnly)
            didRun = true
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(didRun)

        scheduler.setStartupSyncInFlight(false)
        await task.value
        XCTAssertTrue(didRun)
    }
}
