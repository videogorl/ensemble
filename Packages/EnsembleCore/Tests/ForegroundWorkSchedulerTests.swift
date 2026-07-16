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
            didRun = await scheduler.waitUntilAllowed(.systemMediaIndexing, policy: .idleOnly)
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
            didRun = await scheduler.waitUntilAllowed(.offlineHealing, policy: .idleOnly)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(didRun)

        scheduler.setStartupSyncInFlight(false)
        await task.value
        XCTAssertTrue(didRun)
    }

    func testStartupSyncWaitsForScrollingToBecomeIdleOnConstrainedDevice() async {
        var now = Date(timeIntervalSinceReferenceDate: 200)
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 1.5,
                pollingInterval: 0.01
            ),
            now: { now }
        )
        scheduler.clearLaunchState()
        scheduler.beginInteraction(.scrolling)

        var didRun = false
        let task = Task { @MainActor in
            didRun = await scheduler.waitUntilAllowed(.startupSync, policy: .idleOnly)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(didRun)

        scheduler.endInteraction(.scrolling)
        now.addTimeInterval(1.6)
        await task.value
        XCTAssertTrue(didRun)
    }

    func testIdleOnlyWorkReturnsFalseWhenForegroundInactive() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 0,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.setForegroundActive(false)

        let allowed = await scheduler.waitUntilAllowed(.artworkRetry, policy: .idleOnly)

        XCTAssertFalse(allowed)
    }

    func testPlaybackSafeWorkReturnsFalseWhenForegroundInactive() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 0,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.setForegroundActive(false)

        let allowed = await scheduler.waitUntilAllowed(.smartMixAnalysis, policy: .playbackSafe)

        XCTAssertFalse(allowed)
    }

    func testIdleOnlyWorkReturnsFalseWhenWaitingTaskIsCancelled() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 0,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.beginInteraction(.navigating)

        let task = Task { @MainActor in
            await scheduler.waitUntilAllowed(.artworkRetry, policy: .idleOnly)
        }

        task.cancel()
        let allowed = await task.value

        XCTAssertFalse(allowed)
    }

    func testVisibleArtworkRetryBypassesNavigationIdleGate() async {
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: true,
                idleDelay: 5,
                pollingInterval: 0.01
            )
        )
        scheduler.clearLaunchState()
        scheduler.beginInteraction(.navigating)

        let visibleRetryAllowed = await scheduler.waitUntilAllowed(.visibleArtworkRetry, policy: .immediate)

        XCTAssertTrue(visibleRetryAllowed)
        XCTAssertFalse(scheduler.isIdleForNonessentialWork)
    }

    func testSeriousThermalStateDefersNonessentialWorkUntilRecovery() async {
        var thermalState: ProcessInfo.ThermalState = .serious
        let scheduler = ForegroundWorkScheduler(
            configuration: ForegroundWorkSchedulerConfiguration(
                isConstrainedLegacyDevice: false,
                idleDelay: 0,
                pollingInterval: 0.01
            ),
            thermalState: { thermalState }
        )
        scheduler.clearLaunchState()

        var didRun = false
        let task = Task { @MainActor in
            didRun = await scheduler.waitUntilAllowed(.artworkRetry, policy: .immediate)
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(didRun)
        XCTAssertFalse(scheduler.isIdleForNonessentialWork)

        thermalState = .nominal
        await task.value
        XCTAssertTrue(didRun)
    }
}
