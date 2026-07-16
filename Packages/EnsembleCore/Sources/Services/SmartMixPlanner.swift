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
        introTempo: SmartMixTempoAnalysis = .unavailable,
        outroTempo: SmartMixTempoAnalysis = .unavailable
    ) {
        self.leadingSilence = max(0, leadingSilence)
        self.trailingSilence = max(0, trailingSilence)
        self.analyzedDuration = max(0, analyzedDuration)
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

    public var incomingPromotionPosition: TimeInterval {
        incomingStartTime + metadataPromotionTime * incomingPlaybackRate
    }

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
    public static let defaultTransitionDuration: TimeInterval = 10
    public static let minimumTransitionDuration: TimeInterval = 5
    public static let maximumIntroCut: TimeInterval = 10
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
        guard outgoingDuration >= minimumTransitionDuration * 2 else { return nil }
        guard incomingDuration >= minimumTransitionDuration * 2 else { return nil }

        let outgoingTrim = min(max(0, outgoingAnalysis?.trailingSilence ?? 0), maximumIntroCut)
        let incomingTrim = min(max(0, incomingAnalysis?.leadingSilence ?? 0), maximumIntroCut)

        let maxOutgoingWindow = max(minimumTransitionDuration, outgoingDuration - outgoingTrim)
        let desiredDuration = min(defaultTransitionDuration, maxOutgoingWindow / 2, incomingDuration / 2)
        let transitionDuration = min(
            defaultTransitionDuration,
            max(minimumTransitionDuration, desiredDuration)
        )

        let outgoingStart = max(0, outgoingDuration - outgoingTrim - transitionDuration)
        let introCut = min(maximumIntroCut, max(incomingTrim, transitionDuration))
        let baseIncomingStart = min(max(0, introCut), max(0, incomingDuration - transitionDuration))
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
            outgoingHighPassSweep: .subtle
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

    public static func tempoMatchDecision(
        outgoingStartTime: TimeInterval,
        baseIncomingStartTime: TimeInterval,
        incomingDuration: TimeInterval,
        transitionDuration: TimeInterval,
        outgoingTempo: SmartMixTempoAnalysis?,
        incomingTempo: SmartMixTempoAnalysis?,
        tempoMatchingAllowed: Bool = true
    ) -> (matched: Bool, incomingPlaybackRate: Double, outgoingPlaybackRate: Double, beatOffset: TimeInterval) {
        tempoDecision(
            outgoingStartTime: outgoingStartTime,
            baseIncomingStartTime: baseIncomingStartTime,
            incomingDuration: incomingDuration,
            transitionDuration: transitionDuration,
            outgoingTempo: outgoingTempo,
            incomingTempo: incomingTempo,
            tempoMatchingAllowed: tempoMatchingAllowed
        )
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

        let lowerBound = min(baseIncomingStartTime, max(minimumTransitionDuration, incomingTempo.windowStartTime))
        let upperBound = min(maximumIntroCut, max(lowerBound, incomingDuration - transitionDuration))
        let adjustedIncomingStart = min(max(baseIncomingStartTime + offset, lowerBound), upperBound)
        return adjustedIncomingStart - baseIncomingStartTime
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

public enum SmartMixTempoEstimator {
    public static let minimumBPM: Double = 70
    public static let maximumBPM: Double = 180

    public static func estimate(
        monoSamples: [Float],
        sampleRate: Double
    ) -> SmartMixTempoEstimate? {
        guard sampleRate > 0, monoSamples.count >= Int(sampleRate * 4) else { return nil }

        let hopSize = max(512, Int(sampleRate * 0.023))
        let frameCount = monoSamples.count / hopSize
        guard frameCount >= 16 else { return nil }

        var envelope: [Float] = []
        envelope.reserveCapacity(frameCount)

        var offset = 0
        while offset + hopSize <= monoSamples.count {
            var rms: Float = 0
            monoSamples.withUnsafeBufferPointer { buffer in
                if let baseAddress = buffer.baseAddress {
                    vDSP_rmsqv(baseAddress + offset, 1, &rms, vDSP_Length(hopSize))
                }
            }
            envelope.append(rms)
            offset += hopSize
        }

        return estimateEnvelope(envelope, envelopeSampleRate: sampleRate / Double(hopSize))
    }

    public static func estimateEnvelope(
        _ envelope: [Float],
        envelopeSampleRate: Double
    ) -> SmartMixTempoEstimate? {
        guard envelopeSampleRate > 0, envelope.count >= 16 else { return nil }

        var flux = [Float](repeating: 0, count: envelope.count)
        for index in 1 ..< envelope.count {
            flux[index] = max(0, envelope[index] - envelope[index - 1])
        }

        let maxFlux = flux.max() ?? 0
        guard maxFlux > 0.0001 else { return nil }

        let minLag = max(1, Int((60 / maximumBPM) * envelopeSampleRate))
        let maxLag = min(flux.count / 2, Int((60 / minimumBPM) * envelopeSampleRate))
        guard maxLag > minLag else { return nil }

        var bestLag = minLag
        var bestScore: Float = 0
        var scores: [Float] = []
        scores.reserveCapacity(maxLag - minLag + 1)

        for lag in minLag ... maxLag {
            var numerator: Float = 0
            var currentEnergy: Float = 0
            var laggedEnergy: Float = 0
            for index in lag ..< flux.count {
                let current = flux[index]
                let lagged = flux[index - lag]
                numerator += current * lagged
                currentEnergy += current * current
                laggedEnergy += lagged * lagged
            }
            let denominator = sqrt(currentEnergy * laggedEnergy)
            let score = denominator > 0 ? numerator / denominator : 0
            scores.append(score)
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }

        guard bestScore > 0 else { return nil }

        let meanScore = scores.reduce(Float(0), +) / Float(max(scores.count, 1))
        let contrast = meanScore > 0 ? Double(bestScore / meanScore) : 0
        let confidence = min(1, max(0, (contrast - 1.1) / 1.4))
        let bpm = 60 * envelopeSampleRate / Double(bestLag)
        guard bpm >= minimumBPM, bpm <= maximumBPM else { return nil }

        return SmartMixTempoEstimate(
            bpm: bpm,
            confidence: confidence,
            beatAnchorOffset: firstStrongOnsetOffset(
                flux: flux,
                envelopeSampleRate: envelopeSampleRate,
                maxFlux: maxFlux
            )
        )
    }

    private static func firstStrongOnsetOffset(
        flux: [Float],
        envelopeSampleRate: Double,
        maxFlux: Float
    ) -> TimeInterval? {
        let threshold = maxFlux * 0.55
        guard let index = flux.firstIndex(where: { $0 >= threshold }) else { return nil }
        return Double(index) / envelopeSampleRate
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
            file: file,
            startTime: introTempoStart,
            duration: introTempoDuration
        )
        let outroTempoEnd = max(0, duration - trailing)
        let outroTempoDuration = min(30, outroTempoEnd)
        let outroTempoStart = max(0, outroTempoEnd - outroTempoDuration)
        let outroTempo = analyzeTempo(
            file: file,
            startTime: outroTempoStart,
            duration: outroTempoDuration
        )

        return SmartMixAnalysis(
            leadingSilence: leading,
            trailingSilence: trailing,
            analyzedDuration: duration,
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

    private static func analyzeTempo(
        file: AVAudioFile,
        startTime: TimeInterval,
        duration: TimeInterval
    ) -> SmartMixTempoAnalysis {
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, duration >= 4 else { return .unavailable }

        let startFrame = max(0, AVAudioFramePosition(startTime * sampleRate))
        let remainingFrames = max(0, file.length - startFrame)
        let requestedFrames = AVAudioFrameCount(min(Double(remainingFrames), duration * sampleRate))
        guard requestedFrames > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: requestedFrames
              ) else {
            return .unavailable
        }

        do {
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: requestedFrames)
        } catch {
            return .unavailable
        }

        guard let channelData = buffer.floatChannelData else { return .unavailable }
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return .unavailable }

        var monoSamples = [Float](repeating: 0, count: frames)
        for channel in 0 ..< channels {
            for frame in 0 ..< frames {
                monoSamples[frame] += channelData[channel][frame]
            }
        }
        if channels > 1 {
            let scale = Float(1) / Float(channels)
            for frame in 0 ..< frames {
                monoSamples[frame] *= scale
            }
        }

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
            windowDuration: TimeInterval(frames) / sampleRate,
            status: estimate.confidence >= SmartMixPlanner.minimumTempoConfidence ? .analyzed : .lowConfidence
        )
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
