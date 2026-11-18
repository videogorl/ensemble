import Accelerate
import AVFoundation
import Foundation

public enum SmartMixTempoStatus: String, Equatable, Sendable {
    case unavailable
    case lowConfidence
    case analyzed
}

public struct SmartMixTempoAnalysis: Equatable, Sendable {
    public let estimatedBPM: Double?
    public let confidence: Double
    public let beatAnchorTime: TimeInterval?
    public let windowStartTime: TimeInterval
    public let windowDuration: TimeInterval
    public let status: SmartMixTempoStatus

    public static let unavailable = SmartMixTempoAnalysis(
        estimatedBPM: nil,
        confidence: 0,
        beatAnchorTime: nil,
        windowStartTime: 0,
        windowDuration: 0,
        status: .unavailable
    )

    public init(
        estimatedBPM: Double?,
        confidence: Double,
        beatAnchorTime: TimeInterval?,
        windowStartTime: TimeInterval,
        windowDuration: TimeInterval,
        status: SmartMixTempoStatus
    ) {
        let bpm = estimatedBPM.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        }
        self.estimatedBPM = bpm
        self.confidence = min(max(confidence, 0), 1)
        self.beatAnchorTime = beatAnchorTime.flatMap { value in
            value.isFinite && value >= 0 ? value : nil
        }
        self.windowStartTime = max(0, windowStartTime)
        self.windowDuration = max(0, windowDuration)
        if bpm == nil {
            self.status = .unavailable
        } else if self.confidence < SmartMixPlanner.minimumTempoConfidence {
            self.status = .lowConfidence
        } else {
            self.status = status
        }
    }
}

public struct SmartMixAnalysis: Equatable, Sendable {
    public let leadingSilence: TimeInterval
    public let trailingSilence: TimeInterval
    public let analyzedDuration: TimeInterval
    /// Seconds at the end of the file that stay at or below `SmartMixLoudness.quietLevel`.
    public let quietEnding: TimeInterval
    /// Length of the final fade when the track dies away steadily; nil for a cold ending.
    public let fadeOutDuration: TimeInterval?
    /// How much of that fade can still be heard (above `SmartMixLoudness.inaudibleLevel`).
    public let fadeOutAudibleDuration: TimeInterval?
    /// Where the first louder section starts when the track opens with a quieter intro.
    public let bodyStartTime: TimeInterval?
    /// Average loudness of the opening and of the last full-level stretch, for the beat-matched blend.
    public let introLoudness: Float
    public let outroLoudness: Float
    public let introTempo: SmartMixTempoAnalysis
    public let outroTempo: SmartMixTempoAnalysis

    public static let unavailable = SmartMixAnalysis(leadingSilence: 0, trailingSilence: 0, analyzedDuration: 0)

    public init(
        leadingSilence: TimeInterval,
        trailingSilence: TimeInterval,
        analyzedDuration: TimeInterval,
        quietEnding: TimeInterval = 0,
        fadeOutDuration: TimeInterval? = nil,
        fadeOutAudibleDuration: TimeInterval? = nil,
        bodyStartTime: TimeInterval? = nil,
        introLoudness: Float = SmartMixLoudness.floor,
        outroLoudness: Float = SmartMixLoudness.floor,
        introTempo: SmartMixTempoAnalysis = .unavailable,
        outroTempo: SmartMixTempoAnalysis = .unavailable
    ) {
        self.leadingSilence = max(0, leadingSilence)
        self.trailingSilence = max(0, trailingSilence)
        self.analyzedDuration = max(0, analyzedDuration)
        self.quietEnding = quietEnding.isFinite ? max(0, quietEnding) : 0
        self.fadeOutDuration = fadeOutDuration
        self.fadeOutAudibleDuration = fadeOutAudibleDuration
        self.bodyStartTime = bodyStartTime
        self.introLoudness = introLoudness
        self.outroLoudness = outroLoudness
        self.introTempo = introTempo
        self.outroTempo = outroTempo
    }
}

/// How the two songs are treated across the overlap. Each case follows the Apple Music AutoMix
/// style of the same number (docs/investigations/2026-11-17-automix-findings.md).
public enum SmartMixStyle: String, Equatable, Sendable {
    /// Style 0: the next song starts at full level over the outgoing song's dying tail.
    case gapless
    /// Style 1: a short equal-power cross-fade, used when nothing is known about the audio.
    case crossfade
    /// Style 3: both songs at full level; the outgoing one rings out on its own fade.
    case overlap
    /// Style 4: as `overlap`, with the next song eased in over two seconds.
    case easeIn
    /// Style 8: beat-matched; the outgoing song closes a low-pass while the next one opens up from the top.
    case filterBlend
}

/// What one deck should be doing at a moment of the overlap.
public struct SmartMixDeckState: Equatable, Sendable {
    public var gain: Float = 1
    public var rate: Float = 1
    /// Cutoffs in Hz; nil leaves the filter out of the path.
    public var lowPass: Float?
    public var highPass: Float?
    /// Reverb send level, 0 for none.
    public var reverb: Float = 0
}

public struct SmartMixPlan: Equatable, Sendable {
    public static let edgeFadeDuration: TimeInterval = 0.3
    public static let easeInDuration: TimeInterval = 2
    /// Apple's styles 33 and 44: the outgoing song's reverb send reaches this level over `easeInDuration`.
    public static let reverbSend: Float = 0.75

    public let style: SmartMixStyle
    public let transitionDuration: TimeInterval
    public let outgoingStartTime: TimeInterval
    public let incomingStartTime: TimeInterval
    public let metadataPromotionTime: TimeInterval
    public let skipToIncomingThreshold: TimeInterval
    /// Speed the outgoing song reaches by the end of the overlap, and the speed the incoming one
    /// starts it at. Both glide linearly, so the two keep one shared tempo throughout. 1 unless beat-matched.
    public let outgoingEndRate: Double
    public let incomingStartRate: Double
    /// The outgoing song's ending is too short to cover the overlap on its own, so reverb carries it.
    public let outgoingReverb: Bool

    public init(
        style: SmartMixStyle = .crossfade,
        transitionDuration: TimeInterval,
        outgoingStartTime: TimeInterval,
        incomingStartTime: TimeInterval,
        metadataPromotionTime: TimeInterval,
        skipToIncomingThreshold: TimeInterval,
        outgoingEndRate: Double = 1,
        incomingStartRate: Double = 1,
        outgoingReverb: Bool = false
    ) {
        self.style = style
        self.outgoingReverb = outgoingReverb
        self.transitionDuration = transitionDuration
        self.outgoingStartTime = outgoingStartTime
        self.incomingStartTime = incomingStartTime
        self.metadataPromotionTime = metadataPromotionTime
        self.skipToIncomingThreshold = skipToIncomingThreshold
        self.outgoingEndRate = outgoingEndRate.isFinite && outgoingEndRate > 0 ? outgoingEndRate : 1
        self.incomingStartRate = incomingStartRate.isFinite && incomingStartRate > 0 ? incomingStartRate : 1
    }

    /// Position in the incoming song `elapsed` seconds into the overlap, allowing for its speed glide.
    public func incomingPosition(elapsed: TimeInterval) -> TimeInterval {
        let time = max(0, elapsed)
        let gliding = min(time, transitionDuration)
        let glide = transitionDuration > 0 ? (1 - incomingStartRate) * gliding * gliding / (2 * transitionDuration) : 0
        return incomingStartTime + incomingStartRate * gliding + glide + (time - gliding)
    }

    public func deckStates(elapsed: TimeInterval) -> (outgoing: SmartMixDeckState, incoming: SmartMixDeckState) {
        let duration = max(transitionDuration, 0.001)
        let time = min(max(elapsed, 0), duration)
        let progress = time / duration
        let remaining = duration - time
        var outgoing = SmartMixDeckState()
        var incoming = SmartMixDeckState()

        switch style {
        case .gapless:
            outgoing.gain = Float(min(1, remaining / Self.edgeFadeDuration).squareRoot())
        case .crossfade:
            outgoing.gain = Float((1 - progress).squareRoot())
            incoming.gain = Float(progress.squareRoot())
        case .overlap:
            break
        case .easeIn:
            incoming.gain = Float(min(1, time / Self.easeInDuration).squareRoot())
        case .filterBlend:
            outgoing.gain = Float(min(1, remaining / Self.edgeFadeDuration))
            incoming.gain = Float(min(1, time / Self.edgeFadeDuration))
            outgoing.rate = Float(1 + (outgoingEndRate - 1) * progress)
            incoming.rate = Float(incomingStartRate + (1 - incomingStartRate) * progress)
            // The crossover between the two songs sweeps down from the top of the spectrum.
            let closing = 1 - (1 - progress) * (1 - progress)
            outgoing.lowPass = Float(20_000 - 19_800 * closing)
            incoming.highPass = Float(20_000 - 19_990 * closing)
            incoming.lowPass = Float(1_200 + 18_800 * pow(progress, 4))
        }
        if outgoingReverb {
            outgoing.reverb = Self.reverbSend * Float(min(1, time / Self.easeInDuration))
        }
        return (outgoing, incoming)
    }
}

public enum SmartMixPlanner {
    /// Bounds on the overlap of each style, as Apple Music's AutoMix plans them for the same songs.
    public static let minimumGaplessDuration: TimeInterval = 1
    public static let maximumGaplessDuration: TimeInterval = 10
    public static let maximumFadeOverlapDuration: TimeInterval = 20
    /// A fade heard for no longer than this gets reverb to carry it through the overlap.
    public static let maximumReverbedFade: TimeInterval = 5
    public static let fallbackDuration: TimeInterval = 2
    public static let minimumTrackDuration: TimeInterval = 10
    /// A silent opening longer than this is treated as part of the song.
    public static let maximumSkippedSilence: TimeInterval = 5
    public static let minimumTempoConfidence: Double = 0.65
    public static let transitionStartTolerance: TimeInterval = 0.35

    // Beat-matched blend.
    public static let minimumBlendTempoConfidence: Double = 0.82
    public static let blendRateRange: ClosedRange<Double> = 0.92 ... 1.08
    public static let blendBeats: Double = 32
    public static let minimumBlendLoudness: Float = -15
    public static let maximumDroppedEnding: TimeInterval = 12
    /// Each song keeps at least this much outside the blend.
    public static let untouchedDuration: TimeInterval = 30

    public static func plan(
        outgoingDuration: TimeInterval,
        incomingDuration: TimeInterval,
        outgoingAnalysis: SmartMixAnalysis?,
        incomingAnalysis: SmartMixAnalysis?,
        beatBlendAllowed: Bool = false
    ) -> SmartMixPlan? {
        guard outgoingDuration.isFinite, incomingDuration.isFinite else { return nil }
        guard outgoingDuration >= minimumTrackDuration, incomingDuration >= minimumTrackDuration else { return nil }
        let longestOverlap = min(outgoingDuration, incomingDuration) / 2

        func plan(
            _ style: SmartMixStyle,
            duration: TimeInterval,
            outgoingStart: TimeInterval? = nil,
            incomingStart: TimeInterval,
            outgoingEndRate: Double = 1,
            outgoingReverb: Bool = false
        ) -> SmartMixPlan {
            SmartMixPlan(
                style: style,
                transitionDuration: duration,
                outgoingStartTime: outgoingStart ?? outgoingDuration - duration,
                incomingStartTime: min(incomingStart, max(0, incomingDuration - 2 * duration)),
                metadataPromotionTime: duration / 2,
                skipToIncomingThreshold: min(5, duration / 2),
                outgoingEndRate: outgoingEndRate,
                incomingStartRate: 1 / outgoingEndRate,
                outgoingReverb: outgoingReverb
            )
        }

        guard let outgoing = outgoingAnalysis, outgoing.analyzedDuration > 0 else {
            return plan(.crossfade, duration: min(fallbackDuration, longestOverlap), incomingStart: 0)
        }
        let silence = incomingAnalysis?.leadingSilence ?? 0
        let audibleStart = silence <= maximumSkippedSilence ? silence : 0

        if beatBlendAllowed, let incoming = incomingAnalysis,
           let blend = beatBlend(outgoingDuration: outgoingDuration, incomingDuration: incomingDuration, outgoing: outgoing, incoming: incoming, incomingStart: audibleStart) {
            return plan(.filterBlend, duration: blend.duration, outgoingStart: blend.outgoingStart, incomingStart: blend.incomingStart, outgoingEndRate: blend.outgoingEndRate)
        }

        // A fade-out into a song with an intro: the intro plays under the fade.
        if let fade = outgoing.fadeOutDuration, let incoming = incomingAnalysis, let bodyStart = incoming.bodyStartTime {
            // Enter two bars before the louder section, one if only one fits, else from the top.
            let tempo = incoming.introTempo
            let bar = tempo.confidence >= minimumTempoConfidence ? 240 / (tempo.estimatedBPM ?? 120) : 2
            let entry = [bodyStart - 2 * bar, bodyStart - bar].first { $0 >= audibleStart } ?? audibleStart
            return plan(
                entry > audibleStart + 0.25 ? .easeIn : .overlap,
                duration: min(fade, maximumFadeOverlapDuration, longestOverlap),
                incomingStart: entry,
                outgoingReverb: (outgoing.fadeOutAudibleDuration ?? fade) <= maximumReverbedFade
            )
        }

        // Otherwise the next song starts where the outgoing one has gone quiet.
        let duration = min(max(outgoing.quietEnding, minimumGaplessDuration), maximumGaplessDuration, longestOverlap)
        return plan(.gapless, duration: duration, incomingStart: audibleStart)
    }

    public static func shouldStartTransition(
        currentTime: TimeInterval,
        plan: SmartMixPlan,
        tolerance: TimeInterval = transitionStartTolerance
    ) -> Bool {
        currentTime + tolerance >= plan.outgoingStartTime
    }

    /// Genres a beat-matched blend suits, after Apple's list: electronic, dance, pop, hip-hop, R&B,
    /// country, reggae and world music, but not rock, alternative, jazz or classical.
    public static func genresSuitBeatBlend(outgoing: [String], incoming: [String]) -> Bool {
        let suited = ["electro", "dance", "house", "techno", "trance", "disco", "synth", "edm", "dubstep", "drum", "garage",
                      "pop", "hip hop", "hip-hop", "rap", "r&b", "soul", "funk", "reggae", "country", "latin", "world"]
        func suits(_ genres: [String]) -> Bool {
            guard let main = genres.first?.lowercased() else { return false }
            return suited.contains { main.contains($0) }
        }
        return suits(outgoing) && suits(incoming)
    }

    public static func normalizedIncomingTempo(
        outgoingBPM: Double,
        incomingBPM: Double
    ) -> Double? {
        guard outgoingBPM.isFinite, incomingBPM.isFinite, outgoingBPM > 0, incomingBPM > 0 else {
            return nil
        }

        let candidates = [incomingBPM / 2, incomingBPM, incomingBPM * 2]
            .filter { $0 >= 70 && $0 <= 180 }
        guard !candidates.isEmpty else { return incomingBPM }

        return candidates.min { lhs, rhs in
            abs(outgoingBPM / lhs - 1) < abs(outgoingBPM / rhs - 1)
        }
    }

    /// Eight bars in which the tempo glides from the outgoing song's to the incoming one's. The
    /// outgoing song's fade or silence is left out; the incoming song starts on a matching beat.
    private static func beatBlend(
        outgoingDuration: TimeInterval,
        incomingDuration: TimeInterval,
        outgoing: SmartMixAnalysis,
        incoming: SmartMixAnalysis,
        incomingStart: TimeInterval
    ) -> (duration: TimeInterval, outgoingStart: TimeInterval, incomingStart: TimeInterval, outgoingEndRate: Double)? {
        guard outgoing.outroTempo.confidence >= minimumBlendTempoConfidence,
              incoming.introTempo.confidence >= minimumBlendTempoConfidence,
              let outgoingBPM = outgoing.outroTempo.estimatedBPM,
              let incomingEstimate = incoming.introTempo.estimatedBPM,
              let incomingBPM = normalizedIncomingTempo(outgoingBPM: outgoingBPM, incomingBPM: incomingEstimate),
              let outgoingAnchor = outgoing.outroTempo.beatAnchorTime,
              let incomingAnchor = incoming.introTempo.beatAnchorTime,
              blendRateRange.contains(incomingBPM / outgoingBPM),
              outgoing.outroLoudness >= minimumBlendLoudness,
              incoming.introLoudness >= minimumBlendLoudness
        else {
            return nil
        }

        let droppedEnding = outgoing.fadeOutDuration ?? outgoing.quietEnding
        let endRate = incomingBPM / outgoingBPM
        let duration = blendBeats * 60 / ((outgoingBPM + incomingBPM) / 2)
        let outgoingStart = outgoingDuration - droppedEnding - duration * (1 + endRate) / 2
        guard droppedEnding <= maximumDroppedEnding,
              outgoingStart >= untouchedDuration,
              incomingDuration - incomingStart - duration >= untouchedDuration
        else {
            return nil
        }

        // Start the incoming song at the same point within a beat as the outgoing one.
        let outgoingBeat = 60 / outgoingBPM
        let incomingBeat = 60 / incomingBPM
        let outgoingPhase = positiveRemainder(outgoingStart - outgoingAnchor, outgoingBeat) / outgoingBeat
        let incomingPhase = positiveRemainder(incomingStart - incomingAnchor, incomingBeat) / incomingBeat
        let delay = positiveRemainder(outgoingPhase - incomingPhase, 1) * incomingBeat
        return (duration, outgoingStart, incomingStart + delay, endRate)
    }

    private static func positiveRemainder(_ value: TimeInterval, _ divisor: TimeInterval) -> TimeInterval {
        let remainder = value.truncatingRemainder(dividingBy: divisor)
        return remainder >= 0 ? remainder : remainder + divisor
    }
}

public struct SmartMixTempoEstimate: Equatable, Sendable {
    public let bpm: Double
    public let confidence: Double
    public let beatAnchorOffset: TimeInterval?

    public init(bpm: Double, confidence: Double, beatAnchorOffset: TimeInterval?) {
        self.bpm = bpm
        self.confidence = min(max(confidence, 0), 1)
        self.beatAnchorOffset = beatAnchorOffset
    }
}

/// Tempo from spectral onset strength: autocorrelation reinforced at 2x and 4x the period,
/// weighted toward 120 BPM. Mirrors the `spectral` estimator in scripts/automix-lab/tempo_eval.py.
public enum SmartMixTempoEstimator {
    public static let minimumBPM: Double = 70
    public static let maximumBPM: Double = 180

    private static let analysisRate = 11_025.0
    private static let window = 1024
    private static let hop = 128
    private static let bandCount = 24

    public static func estimate(
        monoSamples: [Float],
        sampleRate: Double
    ) -> SmartMixTempoEstimate? {
        guard sampleRate > 0, monoSamples.count >= Int(sampleRate * 4) else { return nil }

        let factor = max(1, Int((sampleRate / analysisRate).rounded()))
        let reducedCount = monoSamples.count / factor
        var reduced = [Float](repeating: 0, count: reducedCount)
        let averaging = [Float](repeating: 1 / Float(factor), count: factor)
        vDSP_desamp(monoSamples, vDSP_Stride(factor), averaging, &reduced, vDSP_Length(reducedCount), vDSP_Length(factor))

        let frameRate = sampleRate / Double(factor) / Double(hop)
        return estimate(onsetStrength: onsetStrength(reduced), frameRate: frameRate)
    }

    /// Estimates tempo from an onset-strength curve sampled at `frameRate` frames per second.
    static func estimate(onsetStrength flux: [Float], frameRate: Double) -> SmartMixTempoEstimate? {
        let count = flux.count
        let minLag = Int(frameRate * 60 / maximumBPM)
        let maxLag = Int(frameRate * 60 / minimumBPM)
        let reach = min(count, 4 * maxLag + 1)
        guard minLag >= 1, maxLag < reach, (flux.max() ?? 0) > 1e-4 else { return nil }

        let centered = vDSP.add(-vDSP.mean(flux), flux)
        let energy = vDSP.dot(centered, centered)
        guard energy > 1e-9 else { return nil }
        let acf = (0 ..< reach).map { vDSP.dot(centered[..<(count - $0)], centered[$0...]) / energy }

        let scores = (minLag ... maxLag).map { lag -> Float in
            var score = acf[lag]
            if 2 * lag < reach { score += 0.5 * acf[2 * lag] }
            if 4 * lag < reach { score += 0.25 * acf[4 * lag] }
            let octaves = log2(frameRate * 60 / Double(lag) / 120) / 0.9
            return score * Float(exp(-0.5 * octaves * octaves))
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }

        var lag = Double(minLag + best)
        if best > 0, best < scores.count - 1 {
            let (a, b, c) = (scores[best - 1], scores[best], scores[best + 1])
            if a - 2 * b + c != 0 { lag += Double(0.5 * (a - c) / (a - 2 * b + c)) }
        }

        let integerLag = minLag + best
        let strength = (acf[integerLag] + acf[min(2 * integerLag, reach - 1)]) / 2
        // Strength 0.35 matched Apple's tempo 80% of the time on real songs, 0.49 matched 88%.
        let confidence = Double(min(1, max(0, strength / 0.6)))

        // The phase whose beats, one period apart, land on the most onset strength.
        let phase = (0 ..< Int(lag.rounded(.up))).max { beatStrength(flux, phase: $0, period: lag) < beatStrength(flux, phase: $1, period: lag) } ?? 0
        // A rise shows once a sound enters the window's trailing edge, so the beat is a window after the frame start.
        let anchor = (Double(phase + 1) + Double(window / hop)) / frameRate

        return SmartMixTempoEstimate(bpm: 60 * frameRate / lag, confidence: confidence, beatAnchorOffset: anchor)
    }

    private static func beatStrength(_ flux: [Float], phase: Int, period: Double) -> Float {
        var sum: Float = 0
        var index = phase
        var beat = 0.0
        while index < flux.count {
            sum += flux[index]
            beat += 1
            index = Int((Double(phase) + beat * period).rounded())
        }
        return sum
    }

    /// Rises in loudness across `bandCount` log-spaced frequency bands, minus a 87-frame running mean.
    private static func onsetStrength(_ samples: [Float]) -> [Float] {
        let frames = 1 + (samples.count - window) / hop
        let log2n = vDSP_Length(10)
        let half = window / 2
        guard frames >= 64, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let edges = Array(Set((0 ... bandCount).map { $0 == bandCount ? half : Int(2 * pow(Double(half / 2), Double($0) / Double(bandCount))) })).sorted()
        let hann = (0 ..< window).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(window - 1))) }
        let real = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let imag = UnsafeMutablePointer<Float>.allocate(capacity: half)
        let magnitude = UnsafeMutablePointer<Float>.allocate(capacity: half)
        defer { real.deallocate(); imag.deallocate(); magnitude.deallocate() }
        var split = DSPSplitComplex(realp: real, imagp: imag)

        var previous = [Float](repeating: 0, count: edges.count - 1)
        var flux = [Float](repeating: 0, count: frames - 1)
        for frame in 0 ..< frames {
            let windowed = vDSP.multiply(hann, samples[frame * hop ..< frame * hop + window])
            for index in 0 ..< half {
                real[index] = windowed[2 * index]
                imag[index] = windowed[2 * index + 1]
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            vDSP_zvabs(&split, 1, magnitude, 1, vDSP_Length(half))

            var rise: Float = 0
            for band in 0 ..< previous.count {
                var sum: Float = 0
                vDSP_sve(magnitude + edges[band], 1, &sum, vDSP_Length(edges[band + 1] - edges[band]))
                // The packed real FFT is twice numpy's rfft, hence 50 rather than 100.
                let level = log1pf(50 * sum)
                if frame > 0 { rise += max(0, level - previous[band]) }
                previous[band] = level
            }
            if frame > 0 { flux[frame - 1] = rise }
        }

        var prefix = [Double](repeating: 0, count: flux.count + 1)
        for index in flux.indices { prefix[index + 1] = prefix[index] + Double(flux[index]) }
        return flux.indices.map { index in
            let mean = (prefix[min(flux.count, index + 44)] - prefix[max(0, index - 43)]) / 87
            return max(0, flux[index] - Float(mean))
        }
    }
}

/// Loudness as the RMS level of the mono mix in dB, one value per half second. This is the scale
/// Apple's AutoMix thresholds are stated in: it matches Apple's loudness curve to within a fraction
/// of a dB on the same songs.
public enum SmartMixLoudness {
    public static let sampleDuration: TimeInterval = 0.5
    public static let floor: Float = -70
    public static let quietLevel: Float = -30
    /// Below this a fading song no longer counts as sounding.
    public static let inaudibleLevel: Float = -55
    /// A section counts as louder or quieter than its neighbour from this difference.
    public static let sectionStep: Float = 6
    public static let windowDuration: TimeInterval = 45

    /// `alignedToEnd` keeps whole half seconds counted back from the last sample rather than forward from the first.
    public static func curve(monoSamples: [Float], sampleRate: Double, alignedToEnd: Bool = false) -> [Float] {
        let length = Int(sampleRate * sampleDuration)
        guard length > 0, monoSamples.count >= length else { return [] }
        let count = monoSamples.count / length
        let offset = alignedToEnd ? monoSamples.count - count * length : 0
        return monoSamples.withUnsafeBufferPointer { buffer in
            (0 ..< count).map { index in
                var meanSquare: Float = 0
                vDSP_measqv(buffer.baseAddress! + offset + index * length, 1, &meanSquare, vDSP_Length(length))
                return max(floor, 10 * log10(meanSquare + 1e-10))
            }
        }
    }

    /// Seconds at the end of `curve` after the level last rose above `quietLevel`.
    public static func quietEnding(_ curve: [Float]) -> TimeInterval {
        let lastLoud = curve.lastIndex { $0 > quietLevel } ?? -1
        return TimeInterval(curve.count - 1 - lastLoud) * sampleDuration
    }

    /// Index where the final fall begins, when the curve ends in one: at least `sectionStep` below
    /// the ten seconds before it, falling 1 dB a second or faster without turning back up, and
    /// audible for two seconds. A cold ending has no such fall.
    public static func fadeOutStart(_ curve: [Float]) -> Int? {
        guard curve.count >= 8 else { return nil }
        var start = curve.count - 1
        while start > 0, directionChanges(curve[(start - 1)...]) < 2 { start -= 1 }
        // The fall proper starts where the level first drops by 1 dB a second.
        while start < curve.count - 2, curve[start + 1] >= curve[start] - 0.5 { start += 1 }

        let fall = curve[start...]
        let before = curve[max(0, start - 20) ..< start]
        guard before.count >= 4, fall.count >= 2,
              vDSP.mean(Array(fall)) - vDSP.mean(Array(before)) <= -sectionStep,
              slope(fall) <= -1,
              fall.filter({ $0 > quietLevel }).count >= 4
        else {
            return nil
        }
        return start
    }

    /// Index where the first louder section starts: the first rise of 2 dB or more after which ten
    /// seconds average at least `sectionStep` above everything before it. Only the first ten seconds
    /// are searched, so an intro left out of a transition is never more than a few bars.
    public static func bodyStart(_ curve: [Float]) -> Int? {
        (1 ..< max(1, min(curve.count - 20, 21))).first { index in
            curve[index] - curve[index - 1] >= 2
                && vDSP.mean(Array(curve[index ..< index + 20])) - vDSP.mean(Array(curve[..<index])) >= sectionStep
        }
    }

    private static func directionChanges(_ values: ArraySlice<Float>) -> Int {
        var changes = 0
        var previous: Float = 0
        for (lhs, rhs) in zip(values, values.dropFirst()) where rhs != lhs {
            let difference = rhs - lhs
            if previous != 0, (difference > 0) != (previous > 0) { changes += 1 }
            previous = difference
        }
        return changes
    }

    /// Least-squares slope in dB per second.
    private static func slope(_ values: ArraySlice<Float>) -> Float {
        let count = Float(values.count)
        guard count > 1 else { return 0 }
        let times = (0 ..< values.count).map { Float($0) * Float(sampleDuration) }
        let meanTime = vDSP.mean(times)
        let meanValue = vDSP.mean(Array(values))
        var numerator: Float = 0
        var denominator: Float = 0
        for (time, value) in zip(times, values) {
            numerator += (time - meanTime) * (value - meanValue)
            denominator += (time - meanTime) * (time - meanTime)
        }
        return denominator > 0 ? numerator / denominator : 0
    }
}

private actor SmartMixSerialAnalyzer {
    func analysis(fileURL: URL) -> SmartMixAnalysis {
        SmartMixAnalysisService.analyze(fileURL: fileURL)
    }
}

public final class SmartMixAnalysisService {
    private static let serialAnalyzer = SmartMixSerialAnalyzer()

    private let lock = NSLock()
    private var cachedAnalyses: [String: SmartMixAnalysis] = [:]
    private var analysisTasks: [String: Task<SmartMixAnalysis, Never>] = [:]

    public init() {}

    /// The next song change depends on this, so it runs as soon as it is asked for: during startup sync, during
    /// downloads and while the app is in the background. One file at a time keeps the cost to a fraction of a second.
    public func analysis(for trackId: String, fileURL: URL) async -> SmartMixAnalysis {
        let cacheKey = Self.cacheKey(trackId: trackId, fileURL: fileURL)
        if let cached = withLock({ cachedAnalyses[cacheKey] }) {
            return cached
        }

        if let task = withLock({ analysisTasks[cacheKey] }) {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            await Self.serialAnalyzer.analysis(fileURL: fileURL)
        }
        withLock { analysisTasks[cacheKey] = task }

        let analysis = await task.value
        withLock {
            cachedAnalyses[cacheKey] = analysis
            analysisTasks.removeValue(forKey: cacheKey)
        }
        return analysis
    }

    private static func cacheKey(trackId: String, fileURL: URL) -> String {
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        return "\(trackId)|\(Int(modified))|\(size)"
    }

    fileprivate static func analyze(fileURL: URL) -> SmartMixAnalysis {
        guard let file = try? AVAudioFile(forReading: fileURL) else {
            return .unavailable
        }

        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return .unavailable }

        let duration = TimeInterval(file.length) / sampleRate
        let windowDuration = min(15, duration / 2)
        guard windowDuration > 0 else { return .unavailable }

        let leading = scanSilence(
            file: file,
            startFrame: 0,
            frameCount: AVAudioFrameCount(windowDuration * sampleRate),
            direction: .forward
        )
        let trailingStart = max(0, file.length - AVAudioFramePosition(windowDuration * sampleRate))
        let trailing = scanSilence(
            file: file,
            startFrame: trailingStart,
            frameCount: AVAudioFrameCount(file.length - trailingStart),
            direction: .backward
        )
        let introTempoStart = min(max(leading, 0), max(0, duration - 1))
        let introTempoDuration = min(30, max(0, duration - introTempoStart))
        let introTempo = analyzeTempo(
            mono: readMono(file: file, startTime: introTempoStart, duration: introTempoDuration),
            sampleRate: sampleRate,
            startTime: introTempoStart
        )
        let outroTempoEnd = max(0, duration - trailing)
        let outroTempoDuration = min(30, outroTempoEnd)
        let outroTempoStart = max(0, outroTempoEnd - outroTempoDuration)
        let outroSamples = readMono(file: file, startTime: outroTempoStart, duration: outroTempoDuration)
        let outroTempo = analyzeTempo(mono: outroSamples, sampleRate: sampleRate, startTime: outroTempoStart)

        let window = SmartMixLoudness.windowDuration
        let step = SmartMixLoudness.sampleDuration
        let head = SmartMixLoudness.curve(monoSamples: readMono(file: file, startTime: 0, duration: window), sampleRate: sampleRate)
        let tail = SmartMixLoudness.curve(
            monoSamples: readMono(file: file, startTime: max(0, duration - window), duration: window),
            sampleRate: sampleRate,
            alignedToEnd: true
        )
        let fadeOutStart = SmartMixLoudness.fadeOutStart(tail)
        let quietEnding = SmartMixLoudness.quietEnding(tail)
        // The stretch a beat-matched blend would use: 16 s from the first sound, and 16 s up to the fade or the last sound.
        let blendSamples = Int(16 / step)
        let introFirst = min(Int(leading / step), head.count)
        let outroEnd = max(0, fadeOutStart ?? tail.count - Int(quietEnding / step))

        return SmartMixAnalysis(
            leadingSilence: leading,
            trailingSilence: trailing,
            analyzedDuration: duration,
            quietEnding: quietEnding,
            fadeOutDuration: fadeOutStart.map { TimeInterval(tail.count - $0) * step },
            fadeOutAudibleDuration: fadeOutStart.map { start in
                TimeInterval((tail.lastIndex { $0 > SmartMixLoudness.inaudibleLevel } ?? start - 1) - start + 1) * step
            },
            bodyStartTime: SmartMixLoudness.bodyStart(head).map { TimeInterval($0) * step },
            introLoudness: meanLoudness(head[introFirst ..< min(head.count, introFirst + blendSamples)]),
            outroLoudness: meanLoudness(tail[max(0, outroEnd - blendSamples) ..< outroEnd]),
            introTempo: introTempo,
            outroTempo: outroTempo
        )
    }

    private static func meanLoudness(_ curve: ArraySlice<Float>) -> Float {
        curve.isEmpty ? SmartMixLoudness.floor : vDSP.mean(Array(curve))
    }

    private enum ScanDirection {
        case forward
        case backward
    }

    private static func scanSilence(
        file: AVAudioFile,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        direction: ScanDirection
    ) -> TimeInterval {
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
              ) else {
            return 0
        }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            return 0
        }

        guard let channelData = buffer.floatChannelData else { return 0 }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return 0 }

        let threshold: Float = 0.006
        let requiredLoudFrames = max(128, Int(file.processingFormat.sampleRate * 0.015))
        var loudRun = 0

        let indices: AnySequence<Int>
        switch direction {
        case .forward:
            indices = AnySequence(0 ..< frames)
        case .backward:
            indices = AnySequence(stride(from: frames - 1, through: 0, by: -1))
        }

        for frame in indices {
            var peak: Float = 0
            for channel in 0 ..< channels {
                peak = max(peak, abs(channelData[channel][frame]))
            }

            if peak > threshold {
                loudRun += 1
                if loudRun >= requiredLoudFrames {
                    let loudFrame: Int
                    switch direction {
                    case .forward:
                        loudFrame = max(0, frame - requiredLoudFrames + 1)
                    case .backward:
                        loudFrame = min(frames - 1, frame + requiredLoudFrames - 1)
                    }
                    let silentFrames: Int
                    switch direction {
                    case .forward:
                        silentFrames = loudFrame
                    case .backward:
                        silentFrames = max(0, frames - loudFrame - 1)
                    }
                    return TimeInterval(silentFrames) / file.processingFormat.sampleRate
                }
            } else {
                loudRun = 0
            }
        }

        return TimeInterval(frames) / file.processingFormat.sampleRate
    }

    private static func readMono(file: AVAudioFile, startTime: TimeInterval, duration: TimeInterval) -> [Float] {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, duration > 0 else { return [] }

        let startFrame = max(0, AVAudioFramePosition(startTime * sampleRate))
        let remainingFrames = max(0, file.length - startFrame)
        let requestedFrames = AVAudioFrameCount(min(Double(remainingFrames), duration * sampleRate))
        guard requestedFrames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: requestedFrames)
        else {
            return []
        }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: requestedFrames)
        } catch {
            return []
        }

        guard let channelData = buffer.floatChannelData else { return [] }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return [] }

        var monoSamples = [Float](repeating: 0, count: frames)
        for channel in 0 ..< channels {
            vDSP_vadd(monoSamples, 1, channelData[channel], 1, &monoSamples, 1, vDSP_Length(frames))
        }
        if channels > 1 {
            var scale = Float(1) / Float(channels)
            vDSP_vsmul(monoSamples, 1, &scale, &monoSamples, 1, vDSP_Length(frames))
        }
        return monoSamples
    }

    private static func analyzeTempo(mono monoSamples: [Float], sampleRate: Double, startTime: TimeInterval) -> SmartMixTempoAnalysis {
        guard sampleRate > 0, Double(monoSamples.count) >= 4 * sampleRate else { return .unavailable }

        guard let estimate = SmartMixTempoEstimator.estimate(
            monoSamples: monoSamples,
            sampleRate: sampleRate
        ) else {
            return .unavailable
        }

        return SmartMixTempoAnalysis(
            estimatedBPM: estimate.bpm,
            confidence: estimate.confidence,
            beatAnchorTime: estimate.beatAnchorOffset.map { startTime + $0 },
            windowStartTime: startTime,
            windowDuration: TimeInterval(monoSamples.count) / sampleRate,
            status: estimate.confidence >= SmartMixPlanner.minimumTempoConfidence ? .analyzed : .lowConfidence
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
