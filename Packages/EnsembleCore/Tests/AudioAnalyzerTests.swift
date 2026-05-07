import XCTest
@testable import EnsembleCore

@MainActor
final class AudioAnalyzerTests: XCTestCase {
    func testDisplayTimerRequiresVisibleConsumer() {
        let sut = FrequencyAnalysisService()

        sut.activateTimeline(for: "track-1")
        sut.resumeUpdates()

        XCTAssertFalse(sut.isDisplayTimerRunningForTesting)

        sut.setVisualizationConsumer(.phoneOverlay, isVisible: true)

        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)
        XCTAssertEqual(sut.activeDisplayFPSForTesting, 30)
    }

    func testDisplayTimerStopsWhenLastConsumerHides() {
        let sut = FrequencyAnalysisService()

        sut.setVisualizationConsumer(.phoneOverlay, isVisible: true)
        sut.activateTimeline(for: "track-1")
        sut.resumeUpdates()
        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)

        sut.setVisualizationConsumer(.phoneOverlay, isVisible: false)

        XCTAssertFalse(sut.isDisplayTimerRunningForTesting)
        XCTAssertTrue(sut.visibleVisualizationConsumersForTesting.isEmpty)
    }

    func testAdditionalNowPlayingConsumersKeepFullRate() {
        let sut = FrequencyAnalysisService()

        sut.setVisualizationConsumer(.phoneOverlay, isVisible: true)
        sut.activateTimeline(for: "track-1")
        sut.resumeUpdates()
        XCTAssertEqual(sut.activeDisplayFPSForTesting, 30)

        sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)

        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)
        XCTAssertEqual(sut.activeDisplayFPSForTesting, 30)
    }

    func testStageFlowConsumerKeepsFullRate() {
        let sut = FrequencyAnalysisService()

        sut.setVisualizationConsumer(.phoneOverlay, isVisible: true)
        sut.activateTimeline(for: "track-1")
        sut.resumeUpdates()
        XCTAssertEqual(sut.activeDisplayFPSForTesting, 30)

        sut.setVisualizationConsumer(.stageFlow, isVisible: true)

        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)
        XCTAssertEqual(sut.activeDisplayFPSForTesting, 30)
    }

    func testPauseKeepsVisibleConsumerButStopsTimerUntilResume() {
        let sut = FrequencyAnalysisService()

        sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)
        sut.activateTimeline(for: "track-1")
        sut.resumeUpdates()
        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)

        sut.pauseUpdates()
        XCTAssertFalse(sut.isDisplayTimerRunningForTesting)
        XCTAssertEqual(sut.visibleVisualizationConsumersForTesting, [.nowPlayingSheet])

        sut.resumeUpdates()
        XCTAssertTrue(sut.isDisplayTimerRunningForTesting)
    }
}
