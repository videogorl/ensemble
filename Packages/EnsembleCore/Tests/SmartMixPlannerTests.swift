@testable import EnsembleCore
import XCTest

final class SmartMixPlannerTests: XCTestCase {
    func testPlanPicksTheStyleTheAudioCallsFor() throws {
        func outgoing(quiet: Double = 0, fade: Double? = nil) -> SmartMixAnalysis {
            SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, quietEnding: quiet, fadeOutDuration: fade)
        }
        func incoming(silence: Double = 0, body: Double? = nil, grid: SmartMixBeatGrid? = nil) -> SmartMixAnalysis {
            SmartMixAnalysis(leadingSilence: silence, trailingSilence: 0, analyzedDuration: 200, bodyStartTime: body, beatGrid: grid)
        }
        let trusted = grid(spacing: 0.6, confidence: 0.9)
        // outgoing, incoming -> style, overlap, incoming start
        let cases: [(SmartMixAnalysis?, SmartMixAnalysis?, SmartMixStyle, Double, Double)] = [
            (nil, incoming(), .crossfade, 2, 0),                                        // nothing known: short cross-fade
            (outgoing(), incoming(silence: 3), .gapless, 1, 3),                         // cold ending; silent opening skipped
            (outgoing(quiet: 6.5), incoming(silence: 9), .gapless, 6.5, 0),             // quiet tail covered; long silence kept
            (outgoing(quiet: 25), incoming(), .gapless, 10, 0),                         // capped
            (outgoing(quiet: 2, fade: 8), incoming(), .gapless, 2, 0),                  // fade but no intro to lay under it
            (outgoing(quiet: 2, fade: 8), incoming(body: 9, grid: trusted), .easeIn, 8, 4.2),   // two 2.4 s bars before the body
            (outgoing(quiet: 2, fade: 8), incoming(body: 3, grid: trusted), .easeIn, 8, 0.6),   // only one bar fits
            (outgoing(quiet: 2, fade: 8), incoming(body: 9, grid: grid(spacing: 0.6, confidence: 0.5)), .easeIn, 8, 5), // untrusted: 2 s bars
            (outgoing(quiet: 2, fade: 8), incoming(body: 1), .overlap, 8, 0),           // intro shorter than a bar
            (outgoing(quiet: 2, fade: 30), incoming(body: 1), .overlap, 20, 0),         // capped
        ]
        for (index, (outgoingAnalysis, incomingAnalysis, style, duration, incomingStart)) in cases.enumerated() {
            let plan = try XCTUnwrap(SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis
            ))
            XCTAssertEqual(plan.style, style, "case \(index)")
            XCTAssertEqual(plan.transitionDuration, duration, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.outgoingStartTime, 180 - duration, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.incomingStartTime, incomingStart, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.metadataPromotionTime, duration / 2, accuracy: 0.0001, "case \(index)")
            XCTAssertEqual(plan.outgoingEndRate, 1, "case \(index)")
        }

        // A 40 s silent tail after 4 s of quiet: the next song starts as the quiet part begins, 44 s early.
        let longTail = SmartMixAnalysis(leadingSilence: 0, trailingSilence: 40, analyzedDuration: 180, quietEnding: 44)
        let plan = try XCTUnwrap(SmartMixPlanner.plan(outgoingDuration: 180, incomingDuration: 200, outgoingAnalysis: longTail, incomingAnalysis: incoming()))
        XCTAssertEqual(plan.outgoingStartTime, 136, accuracy: 0.0001)
        XCTAssertEqual(plan.transitionDuration, 10, accuracy: 0.0001)

        // A fade heard for five seconds or less gets reverb to carry it (Apple's styles 33 and 44).
        for (audible, reverb) in [(4.0, true), (5.5, false)] {
            let fading = SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, fadeOutDuration: 7, fadeOutAudibleDuration: audible)
            let plan = try XCTUnwrap(SmartMixPlanner.plan(outgoingDuration: 180, incomingDuration: 200, outgoingAnalysis: fading, incomingAnalysis: incoming(body: 1)))
            XCTAssertEqual(plan.style, .overlap)
            XCTAssertEqual(plan.outgoingReverb, reverb)
        }
    }

    func testBeatBlendNeedsTrustedGridsCompatibleKeysAndNoOpeningVocal() throws {
        let cMajor = SmartMixKey(tonic: 0, mode: .major, confidence: 0.02)
        let gMajor = SmartMixKey(tonic: 7, mode: .major, confidence: 0.3)
        let trustedC = SmartMixKey(tonic: 0, mode: .major, confidence: 0.3)
        let fSharpMajor = SmartMixKey(tonic: 6, mode: .major, confidence: 0.3)
        // 120 BPM ending into 123 BPM, both with bar lines.
        func outgoing(confidence: Double = 0.9, bars: Double = 0.9, quiet: Double = 1, key: SmartMixKey? = cMajor) -> SmartMixAnalysis {
            SmartMixAnalysis(
                leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, quietEnding: quiet, fadeOutDuration: quiet > 10 ? nil : 6,
                beatGrid: grid(spacing: 0.5, start: 0.1, end: 180, confidence: confidence, barConfidence: bars, firstDownbeat: 1),
                keys: key.map { SmartMixKeys(opening: $0, main: $0, ending: $0) }
            )
        }
        func incoming(spacing: Double = 60 / 123, confidence: Double = 0.9, bars: Double = 0.9, opening: SmartMixKey = gMajor, vocalFreeUntil: TimeInterval? = 45) -> SmartMixAnalysis {
            SmartMixAnalysis(
                leadingSilence: 0.5, trailingSilence: 0, analyzedDuration: 200,
                beatGrid: grid(spacing: spacing, start: 0.2, end: 200, confidence: confidence, barConfidence: bars, firstDownbeat: 2),
                keys: SmartMixKeys(opening: opening, main: opening, ending: opening), vocalFreeUntil: vocalFreeUntil
            )
        }
        // outgoing, incoming, blends allowed -> style (a non-blend falls through to gapless)
        let cases: [(SmartMixAnalysis, SmartMixAnalysis, Bool, SmartMixStyle)] = [
            (outgoing(), incoming(), true, .filterBlend),
            (outgoing(), incoming(), false, .gapless),                                  // device saving power
            (outgoing(), incoming(vocalFreeUntil: nil), true, .filterBlend),            // unknown vocals do not block
            // The incoming song enters at 1.18 s; 32, 16 and 8 beats land at 16.8, 9.0 and 5.1 s.
            (outgoing(), incoming(vocalFreeUntil: 12), true, .popReverb),               // singing before 32 beats land
            (outgoing(), incoming(vocalFreeUntil: 6), true, .popEcho),                  // and before 16
            (outgoing(), incoming(vocalFreeUntil: 3), true, .gapless),                  // and before 8
            (outgoing(key: trustedC), incoming(), true, .filterExpansion),              // both keys trusted and a fifth apart
            (outgoing(key: trustedC), incoming(opening: fSharpMajor), true, .filterBlend),  // a clash never blocks
            (outgoing(key: nil), incoming(), true, .filterBlend),                       // key unknown
            (outgoing(confidence: 0.55), incoming(), true, .gapless),                   // grid not trusted
            (outgoing(), incoming(confidence: 0.55), true, .gapless),
            (outgoing(), incoming(spacing: 60 / 170.0), true, .gapless),                // tempos too far apart
            (outgoing(quiet: 20), incoming(), true, .gapless),                          // too much ending to drop
        ]
        for (index, (outgoingAnalysis, incomingAnalysis, allowed, style)) in cases.enumerated() {
            let plan = try XCTUnwrap(SmartMixPlanner.plan(
                outgoingDuration: 180,
                incomingDuration: 200,
                outgoingAnalysis: outgoingAnalysis,
                incomingAnalysis: incomingAnalysis,
                allowsBeatBlend: allowed
            ))
            XCTAssertEqual(plan.style, style, "case \(index)")
            guard style.isBeatMatched else { continue }
            let beats = style == .popEcho ? 8.0 : style == .popReverb ? 16 : 32
            XCTAssertEqual(plan.transitionDuration, beats * 60 / 121.5, accuracy: 0.001, "case \(index)")
            XCTAssertEqual(plan.outgoingEndRate, 1.025, accuracy: 0.0001, "case \(index)")
            // Both songs start on a beat, on a bar line when both grids trust theirs, and the outgoing song's
            // blended beats end before its fade.
            let outgoingGrid = try XCTUnwrap(outgoingAnalysis.beatGrid)
            let incomingGrid = try XCTUnwrap(incomingAnalysis.beatGrid)
            let onBars = outgoingGrid.hasTrustedBars && incomingGrid.hasTrustedBars
            let outgoingIndex = try XCTUnwrap(outgoingGrid.beatTimes.firstIndex { abs($0 - plan.outgoingStartTime) < 1e-9 }, "case \(index)")
            let incomingIndex = try XCTUnwrap(incomingGrid.beatTimes.firstIndex { abs($0 - plan.incomingStartTime) < 1e-9 }, "case \(index)")
            XCTAssertEqual(outgoingGrid.isDownbeat(outgoingIndex), onBars, "case \(index)")
            XCTAssertEqual(incomingGrid.isDownbeat(incomingIndex), onBars, "case \(index)")
            XCTAssertGreaterThanOrEqual(plan.incomingStartTime, 0.5, "case \(index)")
            let outgoingEnd = plan.outgoingStartTime + plan.transitionDuration * (1 + plan.outgoingEndRate) / 2
            XCTAssertLessThanOrEqual(outgoingEnd, 174 + 1e-9, "case \(index)")
            XCTAssertGreaterThan(outgoingEnd, 174 - 2, "case \(index)")
        }
    }

    func testBeatBlendGlidesBetweenTheTemposOfTheBeatsItPlays() throws {
        // The outgoing grid reads 110 BPM overall but its last minute is at 120; the incoming one at half of 123.
        let outgoingBeats = Array(stride(from: 0.1, to: 120, by: 60 / 110.0)) + Array(stride(from: 120.05, to: 180, by: 0.5))
        let plan = try XCTUnwrap(SmartMixPlanner.plan(
            outgoingDuration: 180,
            incomingDuration: 200,
            outgoingAnalysis: SmartMixAnalysis(
                leadingSilence: 0, trailingSilence: 0, analyzedDuration: 180, quietEnding: 1, fadeOutDuration: 6,
                beatGrid: SmartMixBeatGrid(beatTimes: outgoingBeats, firstDownbeatIndex: 0, bpm: 110, confidence: 0.8, barConfidence: 0),
                keys: SmartMixKeys(opening: key(0), main: key(0), ending: key(0))
            ),
            incomingAnalysis: SmartMixAnalysis(
                leadingSilence: 0.5, trailingSilence: 0, analyzedDuration: 200,
                beatGrid: grid(spacing: 60 / 61.5, start: 0.7, end: 200, confidence: 0.8, barConfidence: 0),
                keys: SmartMixKeys(opening: key(0), main: key(0), ending: key(0))
            ),
            allowsBeatBlend: true
        ))
        let duration = 32 * 60 / 121.5
        XCTAssertEqual(plan.style, .filterExpansion)
        XCTAssertEqual(plan.transitionDuration, duration, accuracy: 0.0001)
        XCTAssertEqual(plan.outgoingEndRate, 1.025, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingStartRate, 1 / 1.025, accuracy: 0.0001)
        // The latest beat whose 32 beats are over before the 6 s fade, and the incoming song's first beat.
        XCTAssertEqual(plan.outgoingStartTime, 157.55, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingStartTime, 0.7, accuracy: 0.0001)
        // By the end the incoming song has played the same number of beats and is back at full speed.
        XCTAssertEqual(plan.incomingPosition(elapsed: duration), 0.7 + duration * (1 + 1 / 1.025) / 2, accuracy: 0.0001)
        XCTAssertEqual(plan.incomingPosition(elapsed: duration + 3) - plan.incomingPosition(elapsed: duration), 3, accuracy: 0.0001)
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

        // With reverb the outgoing song's send rises to 0.75 over 2 s; the next song stays dry.
        let reverbed = SmartMixPlan(style: .overlap, transitionDuration: 8, outgoingStartTime: 100, incomingStartTime: 0, metadataPromotionTime: 4, skipToIncomingThreshold: 4, outgoingReverb: true)
        XCTAssertEqual(reverbed.deckStates(elapsed: 1).outgoing.reverb, 0.375, accuracy: 0.001)
        XCTAssertEqual(reverbed.deckStates(elapsed: 5).outgoing.reverb, 0.75)
        XCTAssertEqual(reverbed.deckStates(elapsed: 5).incoming, untouched)

        // Filter blend: the outgoing song keeps what is below a falling cutoff, the next one what is above it.
        // Filter expansion: both songs in full for the first half, the next one widening from 1 kHz.
        let expansion = plan(.filterExpansion).deckStates(elapsed: 2)
        XCTAssertNil(expansion.outgoing.lowPass)
        XCTAssertEqual(expansion.incoming.highPass ?? 0, 1_000, accuracy: 1)
        XCTAssertEqual(expansion.incoming.lowPass ?? 0, 4_486.5, accuracy: 1)
        let thinning = plan(.filterExpansion).deckStates(elapsed: 6)
        XCTAssertEqual(thinning.outgoing.lowPass ?? 0, 5_015, accuracy: 1)
        XCTAssertEqual(thinning.outgoing.highPass ?? 0, 200, accuracy: 1)
        XCTAssertEqual(thinning.incoming.gain, 1)
        XCTAssertNil(thinning.incoming.lowPass)

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

        // Pop echo (Apple's style 16, its first half): the song is cut at the midpoint and its last beat echoes on.
        let echo = plan(.popEcho, rate: 1.04)
        XCTAssertEqual(echo.deckStates(elapsed: 0).outgoing, SmartMixDeckState(gain: 1, rate: 1, lowPass: 20_000, echoDelay: 1))
        XCTAssertEqual(echo.deckStates(elapsed: 0).incoming.gain, 0)
        let closing = echo.deckStates(elapsed: 3)
        XCTAssertEqual(closing.outgoing.lowPass ?? 0, 7_625, accuracy: 1)
        XCTAssertEqual(closing.outgoing.echo, 0.375, accuracy: 0.0001)
        XCTAssertEqual(closing.outgoing.gain, 1)
        let cut = echo.deckStates(elapsed: 4)
        XCTAssertEqual(cut.outgoing.gain, 0)
        XCTAssertEqual(cut.outgoing.echo, 0.5)
        XCTAssertEqual(cut.outgoing.effectLevel, 1)
        XCTAssertEqual(cut.incoming.gain, 1 / 3, accuracy: 0.0001)
        XCTAssertEqual(cut.incoming.highPass ?? 0, 2_933.75, accuracy: 1)
        XCTAssertEqual(echo.deckStates(elapsed: 7).outgoing.effectLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(echo.deckStates(elapsed: 7).incoming.highPass, 20)
        XCTAssertEqual(echo.deckStates(elapsed: 8).outgoing.effectLevel, 0)
        XCTAssertEqual(echo.deckStates(elapsed: 8).outgoing.rate, 1.04, accuracy: 0.0001)

        // Pop reverb (Apple's style 20): the outgoing song is filtered into reverb while the next one opens up.
        let reverb = SmartMixPlan(style: .popReverb, transitionDuration: 16, outgoingStartTime: 100, incomingStartTime: 0, metadataPromotionTime: 8, skipToIncomingThreshold: 5)
        XCTAssertEqual(reverb.deckStates(elapsed: 0).outgoing, untouched)
        XCTAssertEqual(reverb.deckStates(elapsed: 0).incoming, SmartMixDeckState(gain: 0, highPass: 3_300))
        let middle16 = reverb.deckStates(elapsed: 8)
        XCTAssertEqual(middle16.outgoing.gain, 0.8072, accuracy: 0.0001)
        XCTAssertEqual(middle16.outgoing.effectLevel, middle16.outgoing.gain)
        XCTAssertEqual(middle16.outgoing.lowPass ?? 0, 1_268.75, accuracy: 0.5)
        XCTAssertEqual(middle16.outgoing.highPass ?? 0, 600, accuracy: 0.5)
        XCTAssertEqual(middle16.outgoing.reverb, 0.8 * 0.1875 / 0.2125, accuracy: 0.0001)
        XCTAssertEqual(middle16.incoming.gain, 0.75, accuracy: 0.0001)
        XCTAssertEqual(middle16.incoming.highPass ?? 0, 840, accuracy: 0.5)
        XCTAssertEqual(middle16.incoming.lowPass ?? 0, 1_268.75, accuracy: 0.5)
        XCTAssertEqual(reverb.deckStates(elapsed: 14).outgoing.gain, 0.2109, accuracy: 0.0001)
        let over = reverb.deckStates(elapsed: 16)
        XCTAssertEqual(over.outgoing.gain, 0)
        XCTAssertEqual(over.outgoing.effectLevel, 0)
        XCTAssertEqual(over.incoming, SmartMixDeckState(gain: 1, lowPass: 20_000, highPass: 20))
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

    func testSavedAnalysisLoadsBackOnlyForTheSameVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = SmartMixAnalysis(
            leadingSilence: 0.2, trailingSilence: 1, analyzedDuration: 200, quietEnding: 3, fadeOutDuration: 6,
            beatGrid: grid(spacing: 0.5, confidence: 0.8), keys: SmartMixKeys(opening: key(2), main: key(9), ending: key(4)), vocalFreeUntil: 31.5
        )
        let store = SmartMixAnalysisStore(directory: directory, version: 3)
        XCTAssertNil(store.load(key: "track|1|2"))
        store.save(analysis, key: "track|1|2")
        XCTAssertEqual(store.load(key: "track|1|2"), analysis)
        XCTAssertNil(store.load(key: "track|1|3"))
        XCTAssertNil(SmartMixAnalysisStore(directory: directory, version: 4).load(key: "track|1|2"))
        store.removeUnused(now: Date().addingTimeInterval(89 * 24 * 3600))
        XCTAssertNotNil(store.load(key: "track|1|2"))
        store.removeUnused(now: Date().addingTimeInterval(91 * 24 * 3600))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(key: "track|1|2").path))
        store.save(analysis, key: "track|1|2")
        try Data("not a plist".utf8).write(to: store.fileURL(key: "track|1|2"))
        XCTAssertNil(store.load(key: "track|1|2"))
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

    func testBeatGridFindsTempoAndBeatsInClickTracks() throws {
        let firstClick = 0.25
        for nominal in [90.0, 120, 150] {
            let (samples, period) = clickTrack(bpm: nominal, firstClick: firstClick)
            let bpm = 60 / period
            let grid = try XCTUnwrap(SmartMixBeatGrid.analyze(monoSamples: samples, sampleRate: 44_100), "\(nominal) BPM")
            XCTAssertEqual(grid.bpm, bpm, accuracy: bpm * 0.015, "\(nominal) BPM")
            // The grid's latency is set for music; these clicks out of silence register about 50 ms early.
            let clicks = Array(stride(from: firstClick + period, to: 19.5, by: period))
            XCTAssertTrue(clicks.allSatisfy { click in grid.beatTimes.contains { abs($0 - click) <= 0.06 } }, "\(nominal) BPM")
        }
    }

    func testBeatGridFindsBeatsAndBarLinesInAnAccentedClickTrack() throws {
        // One pickup beat, then bars of four whose first beat adds a bass thump and a new held chord.
        let rate = 44_100.0
        let firstClick = 0.25
        var (samples, period) = clickTrack(bpm: 120, firstClick: firstClick, duration: 60)
        let clicks = Array(stride(from: firstClick, to: 59.9, by: period))
        let downbeats = Array(clicks.dropFirst().enumerated().filter { $0.offset % 4 == 0 }.map(\.element))
        for (bar, start) in downbeats.enumerated() {
            let pitches: [Double] = bar % 2 == 0 ? [261.63, 329.63, 392] : [293.66, 369.99, 440]
            let first = Int(start * rate)
            for index in 0 ..< Int(4 * period * rate) where first + index < samples.count {
                let seconds = Double(index) / rate
                var sample = 0.6 * exp(-seconds * 12) * sin(2 * .pi * 60 * seconds)
                for pitch in pitches { sample += 0.05 * sin(2 * .pi * pitch * seconds) }
                samples[first + index] += Float(sample)
            }
        }

        let grid = try XCTUnwrap(SmartMixBeatGrid.analyze(monoSamples: samples, sampleRate: rate))
        XCTAssertEqual(grid.bpm, 60 / period, accuracy: 60 / period * 0.015)
        XCTAssertTrue(grid.hasTrustedBars, "confidence \(grid.confidence), bars \(grid.barConfidence)")
        func nearest(_ time: TimeInterval, in times: [TimeInterval]) -> TimeInterval {
            times.map { abs($0 - time) }.min() ?? .infinity
        }
        // The grid's latency is set for music; a click out of silence registers about 40 ms early.
        XCTAssertTrue(clicks.allSatisfy { nearest($0, in: grid.beatTimes) <= 0.05 })
        XCTAssertTrue(downbeats.allSatisfy { nearest($0, in: grid.downbeatTimes) <= 0.05 })
        XCTAssertEqual(grid.downbeatTimes.count, downbeats.count, accuracy: 1)

        XCTAssertNil(SmartMixBeatGrid.analyze(monoSamples: [Float](repeating: 0, count: 44_100 * 20), sampleRate: rate))
    }

    /// Evenly spaced beats; `firstDownbeat` is the index of the first bar line.
    private func grid(
        spacing: TimeInterval,
        start: TimeInterval = 0.1,
        end: TimeInterval = 200,
        confidence: Double,
        barConfidence: Double = 0,
        firstDownbeat: Int = 0
    ) -> SmartMixBeatGrid {
        SmartMixBeatGrid(
            beatTimes: Array(stride(from: start, to: end, by: spacing)),
            firstDownbeatIndex: firstDownbeat,
            bpm: 60 / spacing,
            confidence: confidence,
            barConfidence: barConfidence
        )
    }

    private func key(_ tonic: Int) -> SmartMixKey {
        SmartMixKey(tonic: tonic, mode: .major, confidence: 0.2)
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
