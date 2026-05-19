import AVFoundation
import Foundation

public struct SmartMixAnalysis: Equatable, Sendable {
    public let leadingSilence: TimeInterval
    public let trailingSilence: TimeInterval
    public let analyzedDuration: TimeInterval

    public static let unavailable = SmartMixAnalysis(
        leadingSilence: 0,
        trailingSilence: 0,
        analyzedDuration: 0
    )

    public init(
        leadingSilence: TimeInterval,
        trailingSilence: TimeInterval,
        analyzedDuration: TimeInterval
    ) {
        self.leadingSilence = max(0, leadingSilence)
        self.trailingSilence = max(0, trailingSilence)
        self.analyzedDuration = max(0, analyzedDuration)
    }
}

public struct SmartMixPlan: Equatable, Sendable {
    public let transitionDuration: TimeInterval
    public let outgoingStartTime: TimeInterval
    public let incomingStartTime: TimeInterval
    public let metadataPromotionTime: TimeInterval
    public let skipToIncomingThreshold: TimeInterval

    public var incomingPromotionPosition: TimeInterval {
        incomingStartTime + metadataPromotionTime
    }
}

public enum SmartMixPlanner {
    public static let defaultTransitionDuration: TimeInterval = 10
    public static let minimumTransitionDuration: TimeInterval = 5
    public static let maximumIntroCut: TimeInterval = 10

    public static func plan(
        outgoingDuration: TimeInterval,
        incomingDuration: TimeInterval,
        outgoingAnalysis: SmartMixAnalysis?,
        incomingAnalysis: SmartMixAnalysis?
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
        let incomingStart = min(max(0, introCut), max(0, incomingDuration - transitionDuration))
        let promotionTime = transitionDuration / 2

        return SmartMixPlan(
            transitionDuration: transitionDuration,
            outgoingStartTime: outgoingStart,
            incomingStartTime: incomingStart,
            metadataPromotionTime: promotionTime,
            skipToIncomingThreshold: min(5, promotionTime)
        )
    }

    public static func shouldStartTransition(
        currentTime: TimeInterval,
        plan: SmartMixPlan,
        tolerance: TimeInterval = 0.35
    ) -> Bool {
        currentTime + tolerance >= plan.outgoingStartTime
    }
}

public protocol SmartMixAnalysisProviding: AnyObject {
    func analysis(for trackId: String, fileURL: URL) async -> SmartMixAnalysis
}

public final class SmartMixAnalysisService: SmartMixAnalysisProviding {
    private let lock = NSLock()
    private var cachedAnalyses: [String: SmartMixAnalysis] = [:]
    private var analysisTasks: [String: Task<SmartMixAnalysis, Never>] = [:]

    public init() {}

    public func analysis(for trackId: String, fileURL: URL) async -> SmartMixAnalysis {
        if let cached = withLock({ cachedAnalyses[trackId] }) {
            return cached
        }

        if let task = withLock({ analysisTasks[trackId] }) {
            return await task.value
        }

        let task = Task.detached(priority: .utility) {
            Self.analyze(fileURL: fileURL)
        }
        withLock { analysisTasks[trackId] = task }

        let analysis = await task.value
        withLock {
            cachedAnalyses[trackId] = analysis
            analysisTasks.removeValue(forKey: trackId)
        }
        return analysis
    }

    private static func analyze(fileURL: URL) -> SmartMixAnalysis {
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

        return SmartMixAnalysis(
            leadingSilence: leading,
            trailingSilence: trailing,
            analyzedDuration: duration
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

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
