import AVFoundation
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

    // MARK: - Analysis demand

    private func makeToneFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0 ..< 44_100 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) }
        try file.write(from: buffer)
        return url
    }

    func testAnalysisWaitsForVisibleConsumerAndForegroundThenRuns() async throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sut = FrequencyAnalysisService()

        await sut.loadTimeline(for: "t1", fileURL: url, priority: .userInitiated, throttled: false)
        XCTAssertFalse(sut.hasTimelineForTesting("t1"), "no surface is visible")
        XCTAssertEqual(sut.deferredLoadCountForTesting, 1)

        sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)
        sut.enterBackground()
        await sut.loadTimeline(for: "t2", fileURL: url, priority: .utility, throttled: false)
        XCTAssertFalse(sut.hasTimelineForTesting("t2"), "backgrounded")

        sut.exitBackground()
        for _ in 0 ..< 100 where !(sut.hasTimelineForTesting("t1") && sut.hasTimelineForTesting("t2")) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sut.hasTimelineForTesting("t1"))
        XCTAssertTrue(sut.hasTimelineForTesting("t2"))
        XCTAssertEqual(sut.deferredLoadCountForTesting, 0)
    }

    func testTimelineCacheIsBounded() async throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sut = FrequencyAnalysisService()
        sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)

        for index in 0 ..< FrequencyAnalysisService.maxCachedTimelines + 3 {
            await sut.loadTimeline(for: "t\(index)", fileURL: url, priority: .userInitiated, throttled: false)
        }

        XCTAssertEqual(sut.cachedTimelineCountForTesting, FrequencyAnalysisService.maxCachedTimelines)
        XCTAssertFalse(sut.hasTimelineForTesting("t0"))
        XCTAssertTrue(sut.hasTimelineForTesting("t\(FrequencyAnalysisService.maxCachedTimelines + 2)"))
    }
}
