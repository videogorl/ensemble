import XCTest
@testable import EnsembleCore

@MainActor
final class BackgroundRefreshCoordinatorTests: XCTestCase {
    func testAppRefreshRunsAllStepsAndSchedulesNextRefresh() async {
        var events: [String] = []
        let sut = BackgroundRefreshCoordinator(
            appEndpointRefresh: { events.append("endpoint") },
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
            scheduleNextAppRefresh: { events.append("schedule") }
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

    func testStepFailuresAreCollectedAndLaterStepsStillRun() async {
        enum TestError: LocalizedError {
            case endpoint
            var errorDescription: String? { "endpoint failed" }
        }

        var didRunFeed = false
        let sut = BackgroundRefreshCoordinator(
            appEndpointRefresh: { throw TestError.endpoint },
            incrementalSync: {},
            feedRefresh: {
                didRunFeed = true
                return false
            },
            siriIndexRefresh: { true },
            siriContextRefresh: {}
        )

        let result = await sut.performAppRefresh()

        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(result.errorDescriptions.contains { $0.contains("endpoint failed") })
        XCTAssertTrue(result.didRunIncrementalSync)
        XCTAssertTrue(didRunFeed)
        XCTAssertFalse(result.didRefreshFeedSnapshot)
    }

    func testRefreshSkipsNetworkBackedWorkWhenOffline() async {
        var events: [String] = []
        let sut = BackgroundRefreshCoordinator(
            appEndpointRefresh: { events.append("endpoint") },
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
            isNetworkAvailable: { false }
        )

        let result = await sut.performAppRefresh()

        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(result.didRunEndpointRefresh)
        XCTAssertFalse(result.didRunIncrementalSync)
        XCTAssertFalse(result.didRefreshFeedSnapshot)
        XCTAssertFalse(result.didRebuildSiriIndex)
        XCTAssertFalse(result.didUpdateSiriContext)
        XCTAssertTrue(result.errorDescriptions.isEmpty)
    }
}
