@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanUsesDefaultTenSecondTransitionForNormalTracks() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 10)
        XCTAssertEqual(plan?.outgoingStartTime, 170)
        XCTAssertEqual(plan?.incomingStartTime, 10)
        XCTAssertEqual(plan?.metadataPromotionTime, 5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 5)
        XCTAssertFalse(plan?.tempoMatched ?? true)
        XCTAssertEqual(plan?.incomingPlaybackRate, 1)
    }

    func testPlanTrimsOutgoingSilenceBeforeChoosingTransitionStart() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 7, analyzedDuration: 180),
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 10)
        XCTAssertEqual(plan?.outgoingStartTime, 163)
    }

    func testPlanCutsIntoIncomingPastDetectedIntroSilence() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: SmartMixAnalysis(leadingSilence: 6, trailingSilence: 0, analyzedDuration: 200)
        )

        XCTAssertEqual(plan?.incomingStartTime, 10)
    }

    func testPlanClampsShortTracksBelowDefaultTransition() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: .unavailable,
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertEqual(plan?.metadataPromotionTime, 3.5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 3.5)
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
        XCTAssertEqual(plan?.incomingPlaybackRate ?? 0, 120.0 / 123.0, accuracy: 0.0001)
        XCTAssertEqual(plan?.incomingBeatOffset ?? 0, 0, accuracy: 0.0001)
    }

    func testPlanDisablesTempoMatchForLowConfidence() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
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
    }

    func testPlanDisablesTempoMatchWhenRateIsOutsideSubtleRange() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
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
    }

    func testPlanBeatOffsetStaysInsideIntroCutBounds() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 180,
                outroTempo: tempo(bpm: 120, confidence: 0.9, beatAnchorTime: 0)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 200,
                introTempo: tempo(bpm: 120, confidence: 0.9, beatAnchorTime: 0.25)
            )
        )

        XCTAssertTrue(plan?.tempoMatched ?? false)
        XCTAssertEqual(plan?.incomingBeatOffset ?? 0, -0.25, accuracy: 0.0001)
        XCTAssertEqual(plan?.incomingStartTime ?? 0, 9.75, accuracy: 0.0001)
    }

    func testPlanDisablesTempoMatchForShortTransition() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0,
                trailingSilence: 0,
                analyzedDuration: 14,
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
