@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanPicksTheStyleTheAudioCallsFor() throws {
        let strong = tempo(bpm: 120, confidence: 0.9, beatAnchorTime: 0.2)
        func outgoing(quiet: Double = 0, fade: Double? = nil, tempo: SmartMixTempoAnalysis = .unavailable, loudness: Float = -10) -> SmartMixAnalysis {
            SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, quietEnding: quiet, fadeOutDuration: fade, outroLoudness: loudness, outroTempo: tempo)
        }
        func incoming(silence: Double = 0, body: Double? = nil, tempo: SmartMixTempoAnalysis = .unavailable, loudness: Float = -10) -> SmartMixAnalysis {
            SmartMixAnalysis(leadingSilence: silence, trailingSilence: 0, analyzedDuration: 200, bodyStartTime: body, introLoudness: loudness, introTempo: tempo)
        }
        // outgoing, incoming, blend allowed -> style, overlap, incoming start
        let cases: [(SmartMixAnalysis?, SmartMixAnalysis?, Bool, SmartMixStyle, Double, Double)] = [
            (nil, incoming(), true, .crossfade, 2, 0),                                       // nothing known: short cross-fade
            (outgoing(), incoming(silence: 3), false, .gapless, 1, 3),                        // cold ending; silent opening skipped
            (outgoing(quiet: 6.5), incoming(silence: 9), false, .gapless, 6.5, 0),            // quiet tail covered; long silence kept
            (outgoing(quiet: 25), incoming(), false, .gapless, 10, 0),                        // capped
            (outgoing(quiet: 2, fade: 8), incoming(), false, .gapless, 2, 0),                 // fade but no intro to lay under it
            (outgoing(quiet: 2, fade: 8), incoming(body: 9, tempo: strong), false, .easeIn, 8, 5),    // two bars before the body
            (outgoing(quiet: 2, fade: 8), incoming(body: 3, tempo: strong), false, .easeIn, 8, 1),    // only one bar fits
            (outgoing(quiet: 2, fade: 8), incoming(body: 1), false, .overlap, 8, 0),          // intro shorter than a bar
            (outgoing(quiet: 2, fade: 30), incoming(body: 1), false, .overlap, 20, 0),        // capped
            (outgoing(quiet: 1, tempo: strong), incoming(tempo: strong), false, .gapless, 1, 0),      // blend not allowed
            (outgoing(quiet: 1, tempo: strong), incoming(tempo: tempo(bpm: 120, confidence: 0.7, beatAnchorTime: 0)), true, .gapless, 1, 0),
            (outgoing(quiet: 1, tempo: strong), incoming(tempo: tempo(bpm: 140, confidence: 0.9, beatAnchorTime: 0)), true, .gapless, 1, 0),
            (outgoing(quiet: 1, tempo: strong), incoming(tempo: strong, loudness: -24), true, .gapless, 1, 0),
            (outgoing(quiet: 20, tempo: strong), incoming(tempo: strong), true, .gapless, 10, 0),     // too much ending to drop
        ]
        for (index, (outgoingAnalysis, incomingAnalysis, allowed, style, duration, incomingStart)) in cases.enumerated() {
            let plan = try XCTUnwrap(SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis,
                beatBlendAllowed: allowed
            ))
            XCTAssertEqual(plan.style, style, "case \(index)")
            XCTAssertEqual(plan.transitionDuration, duration, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.outgoingStartTime, 180 - duration, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.incomingStartTime, incomingStart, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.metadataPromotionTime, duration / 2, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.outgoingEndRate, 1, "case \(index)")
        }
    }

    func testBeatBlendGlidesBetweenTemposOverEightBarsAndStartsOnTheBeat() throws {
        // 120 BPM into a song read as 61.5 BPM (123 at half speed), whose fade the blend leaves out.
        let plan = try XCTUnwrap(SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, quietEnding: 1, fadeOutDuration: 6,
                outroLoudness: -9, outroTempo: tempo(bpm: 120, confidence: 0.9, beatAnchorTime: 150.1)
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0.5, trailingSilence: 0, analyzedDuration: 200,
                introLoudness: -11, introTempo: tempo(bpm: 61.5, confidence: 0.85, beatAnchorTime: 0.7)
            ),
            beatBlendAllowed: true
        ))
        let duration = 32 * 60 / 121.5
        XCTAssertEqual(plan.style, .filterBlend)
        XCTAssertEqual(plan.transitionDuration, duration, accuracy: 0.0001)
        XCTAssertEqual(plan.outgoingEndRate, 1.025, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingStartRate, 1 / 1.025, accuracy: 0.0001)
        // The outgoing song covers its last full-level stretch at an average of 1.0125x.
        XCTAssertEqual(plan.outgoingStartTime, 180 - 6 - duration * 1.0125, accuracy: 0.0001)
        // By the end the incoming song has played the same number of beats and is back at full speed.
        XCTAssertEqual(plan.incomingPosition(elapsed: duration), plan.incomingStartTime + duration * (1 + 1 / 1.025) / 2, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingPosition(elapsed: duration + 3) - plan.incomingPosition(elapsed: duration), 3, accuracy: 0.0001)
        // Both songs are the same fraction of the way through a beat when the blend starts.
        let outgoingPhase = ((plan.outgoingStartTime - 150.1) / 0.5).truncatingRemainder(dividingBy: 1)
        let incomingBeat = 60 / 123.0
        let incomingPhase = ((plan.incomingStartTime - 0.7) / incomingBeat).truncatingRemainder(dividingBy: 1)
        XCTAssertEqual((outgoingPhase - incomingPhase + 1.5).truncatingRemainder(dividingBy: 1), 0.5, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(plan.incomingStartTime, 0.5)
        XCTAssertLessThan(plan.incomingStartTime, 0.5 + incomingBeat)
    }

    func testEachStyleTreatsTheTwoSongsAsItsRecipeSays() {
        func plan(_ style: SmartMixStyle, rate: Double = 1) -> SmartMixPlan {
            SmartMixPlan(style: style, transitionDuration: 8, outgoingStartTime: 100, incomingStartTime: 0, metadataPromotionTime: 4, skipToIncomingThreshold: 4, outgoingEndRate: rate, incomingStartRate: 1 / rate)
        }
        let untouched = SmartMixDeckState()

        // Gapless: the next song is at full level throughout; the old one is only cut in its last 0.3 s.
        XCTAssertEqual(plan(.gapless).deckStates(elapsed: 0).incoming, untouched)
        XCTAssertEqual(plan(.gapless).deckStates(elapsed: 7.6).outgoing, untouched)
        XCTAssertEqual(plan(.gapless).deckStates(elapsed: 8).outgoing.gain, 0)

        // Cross-fade: equal power, so both sit 3 dB down at the midpoint.
        let middle = plan(.crossfade).deckStates(elapsed: 4)
        XCTAssertEqual(middle.outgoing.gain, 0.7071, accuracy: 0.001)
        XCTAssertEqual(middle.incoming.gain, 0.7071, accuracy: 0.001)

        // Overlap and ease-in leave the outgoing song alone; ease-in brings the next one up over 2 s.
        XCTAssertEqual(plan(.overlap).deckStates(elapsed: 3).outgoing, untouched)
        XCTAssertEqual(plan(.overlap).deckStates(elapsed: 0).incoming, untouched)
        XCTAssertEqual(plan(.easeIn).deckStates(elapsed: 8).outgoing, untouched)
        XCTAssertEqual(plan(.easeIn).deckStates(elapsed: 0).incoming.gain, 0)
        XCTAssertEqual(plan(.easeIn).deckStates(elapsed: 1).incoming.gain, 0.7071, accuracy: 0.001)
        XCTAssertEqual(plan(.easeIn).deckStates(elapsed: 2).incoming, untouched)

        // Filter blend: the outgoing song keeps what is below a falling cutoff, the next one what is above it.
        let blend = plan(.filterBlend, rate: 1.04)
        let start = blend.deckStates(elapsed: 0)
        XCTAssertEqual(start.outgoing, SmartMixDeckState(gain: 1, rate: 1, lowPass: 20_000, highPass: nil))
        XCTAssertEqual(start.incoming.gain, 0)
        XCTAssertEqual(start.incoming.rate, Float(1 / 1.04), accuracy: 0.0001)
        let half = blend.deckStates(elapsed: 4)
        XCTAssertEqual(half.outgoing.lowPass ?? 0, 5_150, accuracy: 1)
        XCTAssertEqual(half.incoming.highPass ?? 0, 5_007.5, accuracy: 1)
        XCTAssertEqual(half.incoming.lowPass ?? 0, 2_375, accuracy: 1)
        XCTAssertEqual(half.outgoing.rate, 1.02, accuracy: 0.0001)
        XCTAssertEqual(half.incoming.gain, 1)
        let end = blend.deckStates(elapsed: 8)
        XCTAssertEqual(end.outgoing.gain, 0)
        XCTAssertEqual(end.outgoing.lowPass ?? 0, 200, accuracy: 0.5)
        XCTAssertEqual(end.incoming, SmartMixDeckState(gain: 1, rate: 1, lowPass: 20_000, highPass: 10))
    }

    func testPlanClampsOverlapToHalfOfShortTracks() {
        let plan = SmartMixPlanner.plan(
            outgoingDuration: 14,
            incomingDuration: 16,
            outgoingAnalysis: SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 14, quietEnding: 10.5),
            incomingAnalysis: .unavailable
        )

        XCTAssertEqual(plan?.transitionDuration, 7)
        XCTAssertEqual(plan?.metadataPromotionTime, 3.5)
        XCTAssertEqual(plan?.skipToIncomingThreshold, 3.5)
    }

    func testLoudnessCurveFindsQuietEndingsFadeOutsAndIntros() {
        let sampleRate = 8_000.0
        /// 45 s of tone at `levels(time)` dB.
        func curve(alignedToEnd: Bool = false, _ level: (Double) -> Double) -> [Float] {
            let samples = (0 ..< Int(sampleRate * 45)).map { index -> Float in
                let amplitude = pow(10, level(Double(index) / sampleRate) / 20) * 2.squareRoot()
                return Float(amplitude * sin(Double(index) * 0.3))
            }
            return SmartMixLoudness.curve(monoSamples: samples, sampleRate: sampleRate, alignedToEnd: alignedToEnd)
        }

        let steady = curve { _ in -12 }
        XCTAssertEqual(steady.count, 90)
        XCTAssertEqual(steady[40], -12, accuracy: 0.1)
        XCTAssertEqual(SmartMixLoudness.quietEnding(steady), 0)
        XCTAssertNil(SmartMixLoudness.fadeOutStart(steady))
        XCTAssertNil(SmartMixLoudness.bodyStart(steady))

        // A cold stop followed by four seconds of silence.
        let coldStop = curve(alignedToEnd: true) { $0 < 41 ? -12 : -120 }
        XCTAssertEqual(SmartMixLoudness.quietEnding(coldStop), 4, accuracy: 0.01)
        XCTAssertNil(SmartMixLoudness.fadeOutStart(coldStop))

        // A fade of 5 dB a second over the last eight seconds: quiet for its last 4.4 s.
        let fade = curve(alignedToEnd: true) { $0 < 37 ? -12 : -12 - 5 * ($0 - 37) }
        XCTAssertEqual(SmartMixLoudness.quietEnding(fade), 4, accuracy: 0.51)
        XCTAssertEqual(Double(fade.count - (SmartMixLoudness.fadeOutStart(fade) ?? 0)) * 0.5, 8, accuracy: 0.51)

        // A soft intro that steps up 10 dB at 6 s; one that lasts 12 s is left alone.
        XCTAssertEqual(SmartMixLoudness.bodyStart(curve { $0 < 6 ? -22 : -12 }), 12)
        XCTAssertNil(SmartMixLoudness.bodyStart(curve { $0 < 12 ? -22 : -12 }))
    }

    func testBeatBlendIsForDanceableGenresOnly() {
        XCTAssertTrue(SmartMixPlanner.genresSuitBeatBlend(outgoing: ["Electronic", "Rock"], incoming: ["Synth-pop"]))
        XCTAssertTrue(SmartMixPlanner.genresSuitBeatBlend(outgoing: ["Hip-Hop/Rap"], incoming: ["R&B"]))
        XCTAssertFalse(SmartMixPlanner.genresSuitBeatBlend(outgoing: ["Rock", "Electronic"], incoming: ["Pop"]))
        XCTAssertFalse(SmartMixPlanner.genresSuitBeatBlend(outgoing: ["Pop"], incoming: []))
    }

    func testPlanRejectsTracksTooShortForSmartMix() {
        XCTAssertNil(SmartMixPlanner.plan(outgoingDuration: 8, incomingDuration: 180, outgoingAnalysis: .unavailable, incomingAnalysis: .unavailable))
        XCTAssertNil(SmartMixPlanner.plan(outgoingDuration: 180, incomingDuration: 8, outgoingAnalysis: .unavailable, incomingAnalysis: .unavailable))
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
