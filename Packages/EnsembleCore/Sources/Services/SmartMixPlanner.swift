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
    /// Seconds at the end of the file, silence included, that sit well below the track's usual
    /// level: under a second for a cold stop, several seconds for a fade-out.
    public let outroDecay: TimeInterval
    public let introTempo: SmartMixTempoAnalysis
    public let outroTempo: SmartMixTempoAnalysis

    public static let unavailable = SmartMixAnalysis(
        leadingSilence: 0,
        trailingSilence: 0,
        analyzedDuration: 0,
        introTempo: .unavailable,
        outroTempo: .unavailable
    )

    public init(
        leadingSilence: TimeInterval,
        trailingSilence: TimeInterval,
        analyzedDuration: TimeInterval,
        outroDecay: TimeInterval = 0,
        introTempo: SmartMixTempoAnalysis = .unavailable,
        outroTempo: SmartMixTempoAnalysis = .unavailable
    ) {
        self.leadingSilence = max(0, leadingSilence)
        self.trailingSilence = max(0, trailingSilence)
        self.analyzedDuration = max(0, analyzedDuration)
        self.outroDecay = outroDecay.isFinite ? max(0, outroDecay) : 0
        self.introTempo = introTempo
        self.outroTempo = outroTempo
    }
}

public struct SmartMixHighPassSweep: Equatable, Sendable {
    public let startFrequency: Float
    public let endFrequency: Float
    public let startProgress: Double

    public static let subtle = SmartMixHighPassSweep(
        startFrequency: 90,
        endFrequency: 1_400,
        startProgress: 0.25
    )

    public init(startFrequency: Float, endFrequency: Float, startProgress: Double) {
        self.startFrequency = max(20, startFrequency)
        self.endFrequency = max(self.startFrequency, endFrequency)
        self.startProgress = min(max(startProgress, 0), 1)
    }
}

public struct SmartMixPlan: Equatable, Sendable {
    public let transitionDuration: TimeInterval
    public let outgoingStartTime: TimeInterval
    public let incomingStartTime: TimeInterval
    public let metadataPromotionTime: TimeInterval
    public let skipToIncomingThreshold: TimeInterval
    public let tempoMatched: Bool
    public let incomingPlaybackRate: Double
    public let outgoingPlaybackRate: Double
    public let incomingBeatOffset: TimeInterval
    public let outgoingHighPassSweep: SmartMixHighPassSweep?

    public init(
        transitionDuration: TimeInterval,
        outgoingStartTime: TimeInterval,
        incomingStartTime: TimeInterval,
        metadataPromotionTime: TimeInterval,
        skipToIncomingThreshold: TimeInterval,
        tempoMatched: Bool = false,
        incomingPlaybackRate: Double = 1,
        outgoingPlaybackRate: Double = 1,
        incomingBeatOffset: TimeInterval = 0,
        outgoingHighPassSweep: SmartMixHighPassSweep? = .subtle
    ) {
        self.transitionDuration = transitionDuration
        self.outgoingStartTime = outgoingStartTime
        self.incomingStartTime = incomingStartTime
        self.metadataPromotionTime = metadataPromotionTime
        self.skipToIncomingThreshold = skipToIncomingThreshold
        self.tempoMatched = tempoMatched
        self.incomingPlaybackRate = incomingPlaybackRate.isFinite && incomingPlaybackRate > 0 ? incomingPlaybackRate : 1
        self.outgoingPlaybackRate = outgoingPlaybackRate.isFinite && outgoingPlaybackRate > 0 ? outgoingPlaybackRate : 1
        self.incomingBeatOffset = incomingBeatOffset.isFinite ? incomingBeatOffset : 0
        self.outgoingHighPassSweep = outgoingHighPassSweep
    }
}

public enum SmartMixPlanner {
    /// The overlap covers the outgoing track's own decay, within these bounds. The bounds and the
    /// lead-in match what Apple Music's AutoMix plans for the same songs
    /// (docs/investigations/2026-11-17-automix-findings.md).
    public static let maximumTransitionDuration: TimeInterval = 10
    public static let minimumTransitionDuration: TimeInterval = 1
    public static let decayLeadIn: TimeInterval = 0.5
    public static let minimumTrackDuration: TimeInterval = 10
    public static let minimumTempoTransitionDuration: TimeInterval = 8
    public static let minimumTempoConfidence: Double = 0.65
    public static let minimumStrongTempoConfidence: Double = 0.82
    public static let minimumSubtleTempoRate: Double = 0.96
    public static let maximumSubtleTempoRate: Double = 1.04
    public static let minimumAssertiveTempoRate: Double = 0.92
    public static let maximumAssertiveTempoRate: Double = 1.08
    public static let transitionStartTolerance: TimeInterval = 0.35

    public static func plan(
        outgoingDuration: TimeInterval,
        incomingDuration: TimeInterval,
        outgoingAnalysis: SmartMixAnalysis?,
        incomingAnalysis: SmartMixAnalysis?,
        tempoMatchingAllowed: Bool = true
    ) -> SmartMixPlan? {
        guard outgoingDuration.isFinite, incomingDuration.isFinite else { return nil }
        guard outgoingDuration >= minimumTrackDuration, incomingDuration >= minimumTrackDuration else { return nil }

        // Overlap only what the outgoing track is already giving up: a cold ending gets the
        // shortest blend, a fade-out or trailing silence is covered for as long as it lasts.
        let wantedDuration = min(
            maximumTransitionDuration,
            max(minimumTransitionDuration, (outgoingAnalysis?.outroDecay ?? 0) - decayLeadIn)
        )
        let transitionDuration = min(wantedDuration, outgoingDuration / 2, incomingDuration / 2)

        let outgoingStart = outgoingDuration - transitionDuration
        // The incoming track plays from its very start; nothing of it is skipped.
        let baseIncomingStart: TimeInterval = 0
        let promotionTime = transitionDuration / 2
        let tempoDecision = tempoDecision(
            outgoingStartTime: outgoingStart,
            baseIncomingStartTime: baseIncomingStart,
            incomingDuration: incomingDuration,
            transitionDuration: transitionDuration,
            outgoingTempo: outgoingAnalysis?.outroTempo,
            incomingTempo: incomingAnalysis?.introTempo,
            tempoMatchingAllowed: tempoMatchingAllowed
        )
        let incomingStart = baseIncomingStart + tempoDecision.beatOffset

        return SmartMixPlan(
            transitionDuration: transitionDuration,
            outgoingStartTime: outgoingStart,
            incomingStartTime: incomingStart,
            metadataPromotionTime: promotionTime,
            skipToIncomingThreshold: min(5, promotionTime),
            tempoMatched: tempoDecision.matched,
            incomingPlaybackRate: tempoDecision.incomingPlaybackRate,
            outgoingPlaybackRate: tempoDecision.outgoingPlaybackRate,
            incomingBeatOffset: tempoDecision.beatOffset,
            outgoingHighPassSweep: transitionDuration >= minimumTempoTransitionDuration ? .subtle : nil
        )
    }

    public static func shouldStartTransition(
        currentTime: TimeInterval,
        plan: SmartMixPlan,
        tolerance: TimeInterval = transitionStartTolerance
    ) -> Bool {
        currentTime + tolerance >= plan.outgoingStartTime
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

    private static func tempoDecision(
        outgoingStartTime: TimeInterval,
        baseIncomingStartTime: TimeInterval,
        incomingDuration: TimeInterval,
        transitionDuration: TimeInterval,
        outgoingTempo: SmartMixTempoAnalysis?,
        incomingTempo: SmartMixTempoAnalysis?,
        tempoMatchingAllowed: Bool
    ) -> (matched: Bool, incomingPlaybackRate: Double, outgoingPlaybackRate: Double, beatOffset: TimeInterval) {
        guard tempoMatchingAllowed,
              transitionDuration >= minimumTempoTransitionDuration,
              let outgoingTempo,
              let incomingTempo,
              outgoingTempo.confidence >= minimumTempoConfidence,
              incomingTempo.confidence >= minimumTempoConfidence,
              let outgoingBPM = outgoingTempo.estimatedBPM,
              let incomingBPM = incomingTempo.estimatedBPM,
              let normalizedIncomingBPM = normalizedIncomingTempo(
                outgoingBPM: outgoingBPM,
                incomingBPM: incomingBPM
        )
        else {
            return (false, 1, 1, 0)
        }

        let beatOffset = beatAlignedOffset(
            outgoingStartTime: outgoingStartTime,
            baseIncomingStartTime: baseIncomingStartTime,
            incomingDuration: incomingDuration,
            transitionDuration: transitionDuration,
            outgoingTempo: outgoingTempo,
            incomingTempo: incomingTempo,
            normalizedIncomingBPM: normalizedIncomingBPM
        )

        let incomingRate = outgoingBPM / normalizedIncomingBPM
        let outgoingRate = normalizedIncomingBPM / outgoingBPM
        let strongConfidence = outgoingTempo.confidence >= minimumStrongTempoConfidence
            && incomingTempo.confidence >= minimumStrongTempoConfidence

        if strongConfidence,
           outgoingRate >= minimumAssertiveTempoRate,
           outgoingRate <= maximumAssertiveTempoRate {
            return (true, 1, outgoingRate, beatOffset)
        }

        guard incomingRate >= minimumSubtleTempoRate, incomingRate <= maximumSubtleTempoRate else {
            return (false, 1, 1, 0)
        }

        return (true, incomingRate, 1, beatOffset)
    }

    private static func beatAlignedOffset(
        outgoingStartTime: TimeInterval,
        baseIncomingStartTime: TimeInterval,
        incomingDuration: TimeInterval,
        transitionDuration: TimeInterval,
        outgoingTempo: SmartMixTempoAnalysis,
        incomingTempo: SmartMixTempoAnalysis,
        normalizedIncomingBPM: Double
    ) -> TimeInterval {
        guard let outgoingAnchor = outgoingTempo.beatAnchorTime,
              let incomingAnchor = incomingTempo.beatAnchorTime,
              normalizedIncomingBPM > 0
        else {
            return 0
        }

        let beatDuration = 60 / normalizedIncomingBPM
        guard beatDuration.isFinite, beatDuration > 0 else { return 0 }

        let outgoingPhase = positiveRemainder(outgoingStartTime - outgoingAnchor, beatDuration)
        let incomingPhase = positiveRemainder(baseIncomingStartTime - incomingAnchor, beatDuration)
        var offset = outgoingPhase - incomingPhase
        if offset > beatDuration / 2 {
            offset -= beatDuration
        } else if offset < -beatDuration / 2 {
            offset += beatDuration
        }

        // Alignment may delay the incoming track by up to half a beat; it never skips further in.
        let latestStart = max(baseIncomingStartTime, incomingDuration - transitionDuration)
        return min(max(0, offset), latestStart - baseIncomingStartTime)
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

public enum SmartMixEndingEstimator {
    public static let windowDuration: TimeInterval = 45
    public static let decayThreshold: Float = 0.158 // -16 dB against the track's usual level
    public static let frameDuration: TimeInterval = 0.05

    /// Seconds at the end of `monoSamples` after the last moment at the usual level. `monoSamples`
    /// should run to the end of the file and cover `windowDuration` where the track is that long.
    public static func decayDuration(monoSamples: [Float], sampleRate: Double) -> TimeInterval {
        let frameLength = Int(sampleRate * frameDuration)
        guard frameLength > 0 else { return 0 }
        let frameCount = monoSamples.count / frameLength
        guard frameCount >= 160 else { return 0 }

        var levels = [Float](repeating: 0, count: frameCount)
        let offset = monoSamples.count - frameCount * frameLength
        monoSamples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in 0 ..< frameCount {
                vDSP_rmsqv(base + offset + frame * frameLength, 1, &levels[frame], vDSP_Length(frameLength))
            }
        }

        // The usual level comes from the part of the window before the ending itself.
        let reference = levels[..<(frameCount * 5 / 9)].sorted()
        let usual = reference[reference.count / 2]
        guard usual > 0 else { return 0 }
        guard let lastLoud = levels.lastIndex(where: { $0 >= usual * decayThreshold }) else { return 0 }
        return TimeInterval(frameCount - 1 - lastLoud) * frameDuration
    }
}

private actor SmartMixSerialAnalyzer {
    func analysis(fileURL: URL) -> SmartMixAnalysis {
        SmartMixAnalysisService.analyze(fileURL: fileURL)
    }
}

public final class SmartMixAnalysisService {
    private static let serialAnalyzer = SmartMixSerialAnalyzer()

    private weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    private let lock = NSLock()
    private var cachedAnalyses: [String: SmartMixAnalysis] = [:]
    private var analysisTasks: [String: Task<SmartMixAnalysis, Never>] = [:]

    public init(foregroundWorkScheduler: ForegroundWorkScheduling? = nil) {
        self.foregroundWorkScheduler = foregroundWorkScheduler
    }

    public func analysis(for trackId: String, fileURL: URL) async -> SmartMixAnalysis {
        let cacheKey = Self.cacheKey(trackId: trackId, fileURL: fileURL)
        if let cached = withLock({ cachedAnalyses[cacheKey] }) {
            return cached
        }

        if let task = withLock({ analysisTasks[cacheKey] }) {
            return await task.value
        }

        let scheduler = foregroundWorkScheduler
        let task = Task.detached(priority: .utility) {
            if let scheduler {
                guard await scheduler.waitUntilAllowed(.smartMixAnalysis, policy: .playbackSafe) else {
                    return SmartMixAnalysis.unavailable
                }
                return await Self.serialAnalyzer.analysis(fileURL: fileURL)
            }
            return Self.analyze(fileURL: fileURL)
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

        return SmartMixAnalysis(
            leadingSilence: leading,
            trailingSilence: trailing,
            analyzedDuration: duration,
            outroDecay: SmartMixEndingEstimator.decayDuration(
                monoSamples: readMono(
                    file: file,
                    startTime: max(0, duration - SmartMixEndingEstimator.windowDuration),
                    duration: SmartMixEndingEstimator.windowDuration
                ),
                sampleRate: sampleRate
            ),
            introTempo: introTempo,
            outroTempo: outroTempo
        )
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
