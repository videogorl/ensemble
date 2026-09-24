import XCTest
@testable import EnsembleCore

@MainActor
final class RefreshOrchestratorTests: XCTestCase {
    func testCoalescesConcurrentRefreshRequests() async {
        let orchestrator = RefreshOrchestrator()
        let request = RefreshOrchestrator.HealthRefreshRequest(
            reason: .networkReconnect,
            forceServerRefresh: true
        )
        let eligibleServerKeys = Set(["account-1:server-1"])
        let now = Date(timeIntervalSince1970: 10_000)

        var runCount = 0
        let firstDidSchedule = orchestrator.scheduleHealthRefresh(
            request: request,
            now: { now },
            shouldDeferForegroundHealthRefresh: nil,
            eligibleServerKeysProvider: { eligibleServerKeys },
            runRefresh: { _, _, _ in
                runCount += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            },
            didComplete: { _ in }
        )

        let secondDidSchedule = orchestrator.scheduleHealthRefresh(
            request: request,
            now: { now },
            shouldDeferForegroundHealthRefresh: nil,
            eligibleServerKeysProvider: { eligibleServerKeys },
            runRefresh: { _, _, _ in
                runCount += 1
            },
            didComplete: { _ in }
        )

        XCTAssertTrue(firstDidSchedule)
        XCTAssertFalse(secondDidSchedule)
        await orchestrator.awaitHealthRefreshForTesting()
        XCTAssertEqual(runCount, 1)
    }

    func testForegroundRefreshHonorsStalenessThreshold() {
        let orchestrator = RefreshOrchestrator()
        let now = Date(timeIntervalSince1970: 20_000)
        orchestrator.setLastHealthRefreshForTesting(now.addingTimeInterval(-30))

        let didSchedule = orchestrator.scheduleHealthRefresh(
            request: .init(reason: .appForeground, forceServerRefresh: false),
            now: { now },
            shouldDeferForegroundHealthRefresh: nil,
            eligibleServerKeysProvider: { Set(["account-1:server-1"]) },
            runRefresh: { _, _, _ in },
            didComplete: { _ in }
        )

        XCTAssertFalse(didSchedule)
    }

    func testForegroundRefreshDefersDuringInteractiveLoadUntilStale() {
        let orchestrator = RefreshOrchestrator()
        let now = Date(timeIntervalSince1970: 30_000)

        orchestrator.setLastHealthRefreshForTesting(now.addingTimeInterval(-120))
        let deferredSchedule = orchestrator.scheduleHealthRefresh(
            request: .init(reason: .appForeground, forceServerRefresh: false),
            now: { now },
            shouldDeferForegroundHealthRefresh: { true },
            eligibleServerKeysProvider: { Set(["account-1:server-1"]) },
            runRefresh: { _, _, _ in },
            didComplete: { _ in }
        )

        orchestrator.setLastHealthRefreshForTesting(now.addingTimeInterval(-301))
        let staleSchedule = orchestrator.scheduleHealthRefresh(
            request: .init(reason: .appForeground, forceServerRefresh: false),
            now: { now },
            shouldDeferForegroundHealthRefresh: { true },
            eligibleServerKeysProvider: { Set(["account-1:server-1"]) },
            runRefresh: { _, _, _ in },
            didComplete: { _ in }
        )

        XCTAssertFalse(deferredSchedule)
        XCTAssertTrue(staleSchedule)
    }

    func testAccountInventoryRefreshBypassesCooldown() async {
        let orchestrator = RefreshOrchestrator()
        let now = Date(timeIntervalSince1970: 40_000)
        orchestrator.setLastHealthRefreshForTesting(now.addingTimeInterval(-5))

        var runCount = 0
        let didSchedule = orchestrator.scheduleHealthRefresh(
            request: .init(reason: .accountInventoryRefresh, forceServerRefresh: true),
            now: { now },
            shouldDeferForegroundHealthRefresh: nil,
            eligibleServerKeysProvider: { Set(["account-1:server-1"]) },
            runRefresh: { _, _, _ in
                runCount += 1
            },
            didComplete: { _ in }
        )

        XCTAssertTrue(didSchedule)
        await orchestrator.awaitHealthRefreshForTesting()
        XCTAssertEqual(runCount, 1)
    }

    func testStartupHealthChecksCanOnlyBeClaimedOnce() {
        let orchestrator = RefreshOrchestrator()

        XCTAssertTrue(orchestrator.beginStartupHealthChecksIfNeeded())
        XCTAssertFalse(orchestrator.beginStartupHealthChecksIfNeeded())

        let freshOrchestrator = RefreshOrchestrator()
        freshOrchestrator.setLastHealthRefreshForTesting(Date())
        XCTAssertFalse(freshOrchestrator.beginStartupHealthChecksIfNeeded())
    }

    func testSecondStartupHealthCheckCallerWaitsForInFlightRefresh() async {
        let orchestrator = RefreshOrchestrator()
        let now = Date(timeIntervalSince1970: 50_000)

        var events: [String] = []
        let firstTask = Task { @MainActor in
            let didRun = await orchestrator.runStartupHealthChecksIfNeeded(
                now: { now },
                runRefresh: {
                    events.append("first-start")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    events.append("first-end")
                },
                didComplete: { _ in
                    events.append("first-complete")
                }
            )
            XCTAssertTrue(didRun)
            events.append("first-returned")
        }

        try? await Task.sleep(nanoseconds: 10_000_000)

        var secondDidReturn = false
        let secondTask = Task { @MainActor in
            let didRun = await orchestrator.runStartupHealthChecksIfNeeded(
                now: { now },
                runRefresh: {
                    XCTFail("Second startup health-check caller should wait for the in-flight refresh instead of running a duplicate pass")
                },
                didComplete: { _ in
                    XCTFail("Second startup health-check caller should not mark completion")
                }
            )
            XCTAssertFalse(didRun)
            secondDidReturn = true
            events.append("second-returned")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(secondDidReturn)

        await firstTask.value
        await secondTask.value

        XCTAssertEqual(events.first, "first-start")
        XCTAssertTrue(events.contains("first-end"))
        XCTAssertTrue(events.contains("first-complete"))
        XCTAssertEqual(Set(events.suffix(2)), Set(["first-returned", "second-returned"]))
        XCTAssertEqual(events.filter { $0.hasSuffix("-returned") }.count, 2)
    }

    func testStartupHealthChecksWaitForActiveScheduledRefresh() async {
        let orchestrator = RefreshOrchestrator()
        let now = Date(timeIntervalSince1970: 60_000)
        var runCount = 0

        XCTAssertTrue(orchestrator.scheduleHealthRefresh(
            request: .init(reason: .accountInventoryRefresh, forceServerRefresh: true),
            now: { now },
            shouldDeferForegroundHealthRefresh: nil,
            eligibleServerKeysProvider: { Set(["account-1:server-1"]) },
            runRefresh: { _, _, _ in
                runCount += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            },
            didComplete: { _ in }
        ))

        let didRunStartupRefresh = await orchestrator.runStartupHealthChecksIfNeeded(
            now: { now },
            runRefresh: {
                runCount += 1
            },
            didComplete: { _ in }
        )

        XCTAssertFalse(didRunStartupRefresh)
        XCTAssertEqual(runCount, 1)
    }

    func testPostRatingPlaylistSyncCoalescesByServer() async {
        let orchestrator = RefreshOrchestrator(
            postRatingPlaylistDebounceNanoseconds: 10_000_000,
            postRatingFavoritesDebounceNanoseconds: 10_000_000
        )
        var invocations: [String] = []

        orchestrator.schedulePostRatingPlaylistSync(serverSourceKey: "plex:a:s1") { serverKey in
            invocations.append(serverKey)
        }
        orchestrator.schedulePostRatingPlaylistSync(serverSourceKey: "plex:a:s1") { serverKey in
            invocations.append("\(serverKey)-latest")
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(invocations, ["plex:a:s1-latest"])
    }

    func testPostRatingFavoritesReconciliationCoalesces() async {
        let orchestrator = RefreshOrchestrator(
            postRatingPlaylistDebounceNanoseconds: 10_000_000,
            postRatingFavoritesDebounceNanoseconds: 10_000_000
        )
        var invocationCount = 0

        orchestrator.schedulePostRatingFavoritesReconciliation {
            invocationCount += 1
        }
        orchestrator.schedulePostRatingFavoritesReconciliation {
            invocationCount += 1
        }

        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(invocationCount, 1)
    }
}
