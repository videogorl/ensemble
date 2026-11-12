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

    // MARK: - Deferred request validity

    private func waitForTimeline(_ sut: FrequencyAnalysisService, _ id: String) async throws {
        for _ in 0 ..< 100 where !sut.hasTimelineForTesting(id) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Requests that arrive while no surface is visible, then the surface appears.
    func testCurrentTrackIsAnalysedWhenSurfaceAppearsDespiteObsoleteAndStaleRequests() async throws {
        struct Case {
            let name: String
            let relevant: Set<String>?
            let requests: [(String, TaskPriority)]
            let expectedAnalysed: Set<String>
            let expectedMissing: Set<String>
        }
        let cases = [
            // Skipped during background: obsolete A and B must not run or block current C.
            Case(name: "skip during replay", relevant: ["C"],
                 requests: [("A", .utility), ("B", .utility)], expectedAnalysed: ["C"], expectedMissing: ["A", "B"]),
            // Old prefetch callbacks arrive after the current request (ten-second delay).
            Case(name: "stale prefetch after rapid skips", relevant: ["C", "D"],
                 requests: [("old1", .background), ("old2", .background)], expectedAnalysed: ["C"], expectedMissing: ["old1", "old2"]),
            // No relevance information: the cap must still protect the active track.
            Case(name: "cap keeps active track", relevant: nil,
                 requests: [("x", .utility), ("y", .utility)], expectedAnalysed: ["C"], expectedMissing: []),
        ]
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }

        for testCase in cases {
            let sut = FrequencyAnalysisService()
            sut.isTrackRelevant = testCase.relevant.map { relevant in { relevant.contains($0) } }
            sut.activateTimeline(for: "C")
            await sut.loadTimeline(for: "C", fileURL: url, priority: .background, throttled: true)
            for (id, priority) in testCase.requests {
                await sut.loadTimeline(for: id, fileURL: url, priority: priority, throttled: true)
            }

            sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)
            try await waitForTimeline(sut, "C")

            for id in testCase.expectedAnalysed { XCTAssertTrue(sut.hasTimelineForTesting(id), "\(testCase.name): \(id)") }
            try await Task.sleep(nanoseconds: 300_000_000)
            for id in testCase.expectedMissing { XCTAssertFalse(sut.hasTimelineForTesting(id), "\(testCase.name): \(id)") }
        }
    }

    /// A current-track request that finds the service busy runs next instead of being dropped.
    func testCurrentTrackRequestQueuesBehindRunningAnalysis() async throws {
        let url = try makeToneFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let sut = FrequencyAnalysisService()
        sut.setVisualizationConsumer(.nowPlayingSheet, isVisible: true)
        sut.activateTimeline(for: "C")

        let busy = Task { await sut.loadTimeline(for: "next", fileURL: url, priority: .utility, throttled: false) }
        await Task.yield()
        await sut.loadTimeline(for: "C", fileURL: url, priority: .background, throttled: true)

        try await waitForTimeline(sut, "C")
        XCTAssertTrue(sut.hasTimelineForTesting("C"))
        await busy.value
    }
}
