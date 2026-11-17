@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanSizesOverlapFromOutgoingDecayAndNeverSkipsIncomingAudio() {
        // outroDecay -> duration, outgoing start, filtered
        let cases: [(Double, Double, Double, Bool)] = [
            (0, 1, 179, false),       // cold ending: shortest overlap, right at the end
            (6.5, 6, 174, false),     // fade-out or trailing silence: overlap covers it
            (25, 10, 170, true),      // long fade: capped
        ]

        for (decay, duration, outgoingStart, filtered) in cases {
            let plan = SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 2, analyzedDuration: 180, outroDecay: decay),
                incomingAnalysis: SmartMixAnalysis(leadingSilence: 3, trailingSilence: 0, analyzedDuration: 200)
            )

            XCTAssertEqual(plan?.transitionDuration, duration, "decay \(decay)")
            XCTAssertEqual(plan?.outgoingStartTime, outgoingStart, "decay \(decay)")
            XCTAssertEqual(plan?.incomingStartTime, 0, "decay \(decay)")
            XCTAssertEqual(plan?.outgoingHighPassSweep != nil, filtered, "decay \(decay)")
            XCTAssertEqual(plan?.metadataPromotionTime, duration / 2, "decay \(decay)")
        }
    }

    func testPlanClampsOverlapToHalfOfShortTracks() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 14, outroDecay: 10.5),
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertEqual(plan?.metadataPromotionTime, 3.5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 3.5)
    }

    func testEndingEstimatorMeasuresHowLongTheTrackDiesAway() {
        let sampleRate = 8_000.0
        func track(fadeSeconds: Double, silenceSeconds: Double = 0) -> [Float] {
            let total = Int(sampleRate * 45)
            let silenceStart = total - Int(sampleRate * silenceSeconds)
            let fadeStart = silenceStart - Int(sampleRate * fadeSeconds)
            return (0 ..< total).map { index in
                guard index < silenceStart else { return 0 }
                let level = index < fadeStart ? 1 : 1 - Double(index - fadeStart) / (sampleRate * fadeSeconds)
                return Float(level * sin(Double(index) * 0.3))
            }
        }
        func decay(_ samples: [Float]) -> TimeInterval {
            SmartMixEndingEstimator.decayDuration(monoSamples: samples, sampleRate: sampleRate)
        }

        XCTAssertEqual(decay(track(fadeSeconds: 0.01)), 0, accuracy: 0.11)
        // A linear 10 s fade is 16 dB down for its last 1.6 s.
        XCTAssertEqual(decay(track(fadeSeconds: 10)), 1.6, accuracy: 0.15)
        XCTAssertEqual(decay(track(fadeSeconds: 0.01, silenceSeconds: 4)), 4, accuracy: 0.11)
        XCTAssertEqual(decay([]), 0)
    }

    func testPlanRejectsTracksTooShortForSmartMix() {
        XCTAssertNil(
            SmartMixPlanner.plan(
                outgoingDuration: 8,
                incomingDuration: 180,
                outgoingAnalysis: .unavailable,
                incomingAnalysis: .unavailable
            )
        )
        XCTAssertNil(
            SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 8,
                outgoingAnalysis: .unavailable,
                incomingAnalysis: .unavailable
            )
        )
    }

    func testShouldStartTransitionHonorsTolerance() {
        let plan = SmartMixPlan(
            transitionDuration: 10,
            outgoingStartTime: 170,
            incomingStartTime: 10,
            metadataPromotionTime: 5,
            skipToIncomingThreshold: 5
        )

        XCTAssertFalse(SmartMixPlanner.shouldStartTransition(currentTime: 169.5, plan: plan))
        XCTAssertTrue(SmartMixPlanner.shouldStartTransition(currentTime: 169.7, plan: plan))
        XCTAssertTrue(SmartMixPlanner.shouldStartTransition(currentTime: 170, plan: plan))
    }

    func testPlanTempoMatchesConfidentCloseTempos() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.9)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 123, confidence: 0.88)
            )
        )

        XCTAssertTrue(plan?.tempoMatched ?? false)
        XCTAssertEqual(plan?.incomingPlaybackRate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(plan?.outgoingPlaybackRate ?? 0, 123.0 / 120.0, accuracy: 0.0001)
        XCTAssertEqual(plan?.incomingBeatOffset ?? 0, 0, accuracy: 0.0001)
    }

    func testPlanUsesIncomingOnlyTempoMatchForModerateConfidence() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.75)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 123, confidence: 0.75)
            )
        )

        XCTAssertTrue(plan?.tempoMatched ?? false)
        XCTAssertEqual(plan?.incomingPlaybackRate ?? 0, 120.0 / 123.0, accuracy: 0.0001)
        XCTAssertEqual(plan?.outgoingPlaybackRate ?? 0, 1, accuracy: 0.0001)
    }

    func testPlanAllowsWiderOutgoingTempoMatchWhenConfidenceIsHigh() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.95)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 128.4, confidence: 0.95)
            )
        )

        XCTAssertTrue(plan?.tempoMatched ?? false)
        XCTAssertEqual(plan?.incomingPlaybackRate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(plan?.outgoingPlaybackRate ?? 0, 1.07, accuracy: 0.0001)
    }

    func testPlanDisablesTempoMatchForLowConfidence() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.5)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 122, confidence: 0.9)
            )
        )

        XCTAssertFalse(plan?.tempoMatched ?? true)
        XCTAssertEqual(plan?.incomingPlaybackRate, 1)
        XCTAssertEqual(plan?.outgoingPlaybackRate, 1)
    }

    func testPlanDisablesTempoMatchWhenRateIsOutsideSubtleRange() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.9)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 100, confidence: 0.9)
            )
        )

        XCTAssertFalse(plan?.tempoMatched ?? true)
        XCTAssertEqual(plan?.incomingPlaybackRate, 1)
    }

    func testPlanOctaveNormalizesIncomingTempo() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.9)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 60, confidence: 0.9)
            )
        )

        XCTAssertTrue(plan?.tempoMatched ?? false)
        XCTAssertEqual(plan?.incomingPlaybackRate ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(plan?.outgoingPlaybackRate ?? 0, 1, accuracy: 0.0001)
    }

    func testPlanBeatOffsetOnlyDelaysIncomingTrack() {
        // outgoing beat anchor -> incoming start. Alignment that would need an earlier start is dropped.
        for (outgoingAnchor, expectedStart) in [(0.4, 0.1), (0.1, 0.0)] {
            let plan = SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: SmartMixAnalysis(
                    leadingSilence: 0,
                    trailingSilence: 0,
                    analyzedDuration: 180,
                    outroDecay: 10.5,
                    outroTempo: tempo(bpm: 120, confidence: 0.9, beatAnchorTime: outgoingAnchor)
                ),
                incomingAnalysis: SmartMixAnalysis(
                    leadingSilence: 0,
                    trailingSilence: 0,
                    analyzedDuration: 200,
                    introTempo: tempo(bpm: 120, confidence: 0.9, beatAnchorTime: 0)
                )
            )

            XCTAssertTrue(plan?.tempoMatched ?? false)
            XCTAssertEqual(plan?.incomingStartTime ?? -1, expectedStart, accuracy: 0.0001)
        }
    }

    func testPlanDisablesTempoMatchForShortTransition() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 14,
                outroDecay: 10.5,
                outroTempo: tempo(bpm: 120, confidence: 0.9)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 16,
                introTempo: tempo(bpm: 121, confidence: 0.9)
            )
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertFalse(plan?.tempoMatched ?? true)
    }

    func testTempoEstimatorFindsTempoAndBeatsInClickTracks() throws {
        let firstClick = 0.25
        for nominal in [90.0, 120, 150] {
            let (samples, period) = clickTrack(bpm: nominal, firstClick: firstClick)
            let bpm = 60 / period
            let estimate = try XCTUnwrap(SmartMixTempoEstimator.estimate(monoSamples: samples, sampleRate: 44_100), "\(nominal) BPM")
            XCTAssertEqual(estimate.bpm, bpm, accuracy: bpm * 0.015, "\(nominal) BPM")
            XCTAssertGreaterThanOrEqual(estimate.confidence, 0.65, "\(nominal) BPM")
            let anchor = try XCTUnwrap(estimate.beatAnchorOffset)
            let drift = (anchor - firstClick).truncatingRemainder(dividingBy: period)
            let distance = min(abs(drift), period - abs(drift))
            XCTAssertLessThanOrEqual(distance, 0.04, "\(nominal) BPM anchor \(anchor)")
        }

        XCTAssertNil(SmartMixTempoEstimator.estimate(monoSamples: [Float](repeating: 0, count: 44_100 * 20), sampleRate: 44_100))
    }

    private func tempo(
        bpm: Double,
        confidence: Double,
        beatAnchorTime: TimeInterval? = nil
    ) -> SmartMixTempoAnalysis {
        SmartMixTempoAnalysis(
            estimatedBPM: bpm,
            confidence: confidence,
            beatAnchorTime: beatAnchorTime,
            windowStartTime: 0,
            windowDuration: 30,
            status: confidence >= SmartMixPlanner.minimumTempoConfidence ? .analyzed : .lowConfidence
        )
    }

    /// Beats are a short cluster of bursts, so each onset spans a few analysis frames as a real attack does.
    /// The period is a whole number of analysis hops (512 samples): a perfectly periodic train with a
    /// fractional hop count splits its autocorrelation peak between two lags and can read as half tempo.
    private func clickTrack(bpm: Double, firstClick: TimeInterval, duration: TimeInterval = 20) -> (samples: [Float], period: TimeInterval) {
        let rate = 44_100.0
        let period = (60 / bpm * rate / 512).rounded() * 512 / rate
        var samples = [Float](repeating: 0, count: Int(duration * rate))
        var time = firstClick
        while time < duration - 0.1 {
            for spread in [-0.012, 0, 0.012] {
                let start = Int((time + spread) * rate)
                for index in 0 ..< 2_000 where start + index < samples.count {
                    let seconds = Double(index) / rate
                    samples[start + index] += Float(exp(-seconds * 100) * sin(2 * .pi * 1_000 * seconds))
                }
            }
            time += period
        }
        return (samples, period)
    }
}
