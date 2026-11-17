@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanSizesOverlapFromOutgoingDecayAndNeverSkipsIncomingAudio() {
        // outroDecay, trailing silence, leading silence -> duration, outgoing start, incoming start, filtered
        let cases: [(Double, Double, Double, Double, Double, Double, Bool)] = [
            (0, 0, 0, 2, 178, 0, false),      // cold ending: shortest overlap, right at the end
            (6, 0, 0, 6, 174, 0, false),      // fade-out: overlap covers the fade
            (25, 0, 0, 10, 170, 0, true),     // long fade: capped
            (6, 7, 0, 6, 167, 0, false),      // trailing silence is trimmed before the overlap
            (0, 0, 3, 2, 178, 3, false),      // incoming starts at its first sound
        ]

        for (decay, trailing, leading, duration, outgoingStart, incomingStart, filtered) in cases {
            let plan = SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: trailing, analyzedDuration: 180, outroDecay: decay),
                incomingAnalysis: SmartMixAnalysis(leadingSilence: leading, trailingSilence: 0, analyzedDuration: 200)
            )

            XCTAssertEqual(plan?.transitionDuration, duration, "decay \(decay)")
            XCTAssertEqual(plan?.outgoingStartTime, outgoingStart, "decay \(decay)")
            XCTAssertEqual(plan?.incomingStartTime, incomingStart, "decay \(decay)")
            XCTAssertEqual(plan?.outgoingHighPassSweep != nil, filtered, "decay \(decay)")
            XCTAssertEqual(plan?.metadataPromotionTime, duration / 2, "decay \(decay)")
        }
    }

    func testPlanClampsOverlapToHalfOfShortTracks() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 14, outroDecay: 10),
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertEqual(plan?.metadataPromotionTime, 3.5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 3.5)
    }

    func testEndingEstimatorMeasuresHowLongTheTrackDiesAway() {
        let sampleRate = 8_000.0
        func track(fadeSeconds: Double) -> [Float] {
            let total = Int(sampleRate * 30)
            let fadeStart = total - Int(sampleRate * fadeSeconds)
            return (0 ..< total).map { index in
                let level = index < fadeStart ? 1 : max(0, 1 - Double(index - fadeStart) / (sampleRate * fadeSeconds))
                return Float(level * sin(Double(index) * 0.3))
            }
        }

        XCTAssertEqual(SmartMixEndingEstimator.decayDuration(monoSamples: track(fadeSeconds: 0.01), sampleRate: sampleRate), 0, accuracy: 0.11)
        // A linear 8 s fade is 10 dB down for its last 2.5 s.
        XCTAssertEqual(SmartMixEndingEstimator.decayDuration(monoSamples: track(fadeSeconds: 8), sampleRate: sampleRate), 2.5, accuracy: 0.2)
        XCTAssertEqual(SmartMixEndingEstimator.decayDuration(monoSamples: [], sampleRate: sampleRate), 0)
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
                outroDecay: 10,
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
                outroDecay: 10,
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
                outroDecay: 10,
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
                outroDecay: 10,
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
                outroDecay: 10,
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
                outroDecay: 10,
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
                    outroDecay: 10,
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
                outroDecay: 10,
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

    func testTempoEstimatorDetectsSyntheticPulseTempo() {
        let estimate = SmartMixTempoEstimator.estimateEnvelope(
            pulseEnvelope(bpm: 120, duration: 20),
            envelopeSampleRate: 50
        )

        XCTAssertEqual(estimate?.bpm ?? 0, 120, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(estimate?.confidence ?? 0, SmartMixPlanner.minimumTempoConfidence)
        XCTAssertEqual(estimate?.beatAnchorOffset ?? -1, 0.5, accuracy: 0.001)
    }

    func testTempoEstimatorReturnsNilForFlatEnvelope() {
        let estimate = SmartMixTempoEstimator.estimateEnvelope(
            [Float](repeating: 0.2, count: 1_000),
            envelopeSampleRate: 50
        )

        XCTAssertNil(estimate)
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

    private func pulseEnvelope(
        bpm: Double,
        duration: TimeInterval,
        sampleRate: Double = 50
    ) -> [Float] {
        let count = Int(duration * sampleRate)
        let interval = 60 / bpm
        var envelope = [Float](repeating: 0, count: count)
        var beatTime = 0.5
        while beatTime < duration {
            let index = Int(beatTime * sampleRate)
            if envelope.indices.contains(index) {
                envelope[index] = 1
            }
            beatTime += interval
        }
        return envelope
    }
}
