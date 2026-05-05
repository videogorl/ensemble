import XCTest
@testable import EnsembleCore

@MainActor
final class BackgroundRefreshCoordinatorTests: XCTestCase {
    func testAppRefreshRunsAllStepsAndSchedulesNextRefresh() async {
        var events: [String] = []
        let sut = BackgroundRefreshCoordinator(
            endpointRefresh: { events.append("endpoint") },
            incrementalSync: { events.append("sync") },
            feedRefresh: {
                events.append("feed")
                return true
            },
            siriIndexRefresh: {
                events.append("siri-index")
                return true
            },
            siriContextRefresh: { events.append("siri-context") },
            scheduleNextAppRefresh: { events.append("schedule") },
            foregroundCooldown: 0
        )

        let result = await sut.performAppRefresh()

        XCTAssertEqual(events, ["schedule", "endpoint", "sync", "feed", "siri-index", "siri-context"])
        XCTAssertTrue(result.didRunEndpointRefresh)
        XCTAssertTrue(result.didRunIncrementalSync)
        XCTAssertTrue(result.didRefreshFeedSnapshot)
        XCTAssertTrue(result.didRebuildSiriIndex)
        XCTAssertTrue(result.didUpdateSiriContext)
        XCTAssertTrue(result.errorDescriptions.isEmpty)
    }

    func testForegroundFreshnessHonorsCooldownAfterSuccess() async {
        var runCount = 0
        let sut = BackgroundRefreshCoordinator(
            endpointRefresh: { runCount += 1 },
            incrementalSync: {},
            feedRefresh: { true },
            siriIndexRefresh: { true },
            siriContextRefresh: {},
            foregroundCooldown: 60
        )

        let first = await sut.performForegroundFreshnessRefresh()
        let second = await sut.performForegroundFreshnessRefresh()

        XCTAssertTrue(first.didRunEndpointRefresh)
        XCTAssertFalse(second.didRunEndpointRefresh)
        XCTAssertEqual(runCount, 1)
    }

    func testForegroundFreshnessUsesForegroundEndpointPolicy() async {
        var endpointEvents: [String] = []
        let sut = BackgroundRefreshCoordinator(
            appEndpointRefresh: { endpointEvents.append("app") },
            foregroundEndpointRefresh: { endpointEvents.append("foreground") },
            incrementalSync: {},
            feedRefresh: { true },
            siriIndexRefresh: { true },
            siriContextRefresh: {},
            foregroundCooldown: 0
        )

        _ = await sut.performAppRefresh()
        _ = await sut.performForegroundFreshnessRefresh()

        XCTAssertEqual(endpointEvents, ["app", "foreground"])
    }

    func testStepFailuresAreCollectedAndLaterStepsStillRun() async {
        enum TestError: LocalizedError {
            case endpoint
            var errorDescription: String? { "endpoint failed" }
        }

        var didRunFeed = false
        let sut = BackgroundRefreshCoordinator(
            endpointRefresh: { throw TestError.endpoint },
            incrementalSync: {},
            feedRefresh: {
                didRunFeed = true
                return false
            },
            siriIndexRefresh: { true },
            siriContextRefresh: {},
            foregroundCooldown: 0
        )

        let result = await sut.performAppRefresh()

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.errorDescriptions.contains { $0.contains("endpoint failed") })
        XCTAssertTrue(result.didRunIncrementalSync)
        XCTAssertTrue(didRunFeed)
        XCTAssertFalse(result.didRefreshFeedSnapshot)
    }
}
