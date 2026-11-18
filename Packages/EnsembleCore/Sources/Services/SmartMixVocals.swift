#if canImport(SoundAnalysis)
import AVFoundation
import Foundation
import SoundAnalysis

/// Where singing, rapping or speech is in a stretch of a song, from decoded audio alone.
///
/// Runs Apple's built-in sound classifier (`SNClassifierIdentifier.version1`) over the stretch and scores
/// each analysis window by its most confident vocal class. Ask `hasVocals` for SmartMix's two questions:
/// is there a vocal in the opening stretch a blend would use, and in the closing stretch.
public struct SmartMixVocals: Equatable, Sendable {
    /// The classifier's vocal classes, as named in `SNClassifySoundRequest.knownClassifications`.
    public static let vocalClasses = [
        "singing", "choir_singing", "rapping", "humming", "yodeling",
        "speech", "shout", "yell", "screaming", "whispering",
    ]
    public static let windowDuration: TimeInterval = 3
    /// Windows start this far apart, so each overlaps its neighbour by half.
    public static let hop: TimeInterval = 1.5
    /// A window counts as vocal at this score. Against Apple Music's vocal activity (medium or stronger),
    /// windows at or above it are vocal 77% of the time and catch 91% of Apple's vocal time.
    public static let vocalScore: Float = 0.2
    /// A stretch has vocals when this much of it (one window) scores as vocal. Over 308 songs, a 30 s
    /// opening or closing stretch without vocals by this rule had Apple vocals in about 15% of cases.
    public static let minimumVocalSeconds: TimeInterval = 1.5

    /// The analysed stretch of the song, in seconds.
    public let range: Range<TimeInterval>
    /// The vocal score (0...1) of each window; window `i` starts at `range.lowerBound + i * hop`.
    public let windowScores: [Float]

    public var vocalWindowCount: Int { windowScores.lazy.filter { $0 >= Self.vocalScore }.count }
    /// Seconds of the stretch that score as vocal, counting each vocal window's own `hop`.
    public var vocalSeconds: TimeInterval { Double(vocalWindowCount) * Self.hop }
    /// Share of the stretch that scores as vocal, 0...1.
    public var vocalShare: Double { windowScores.isEmpty ? 0 : Double(vocalWindowCount) / Double(windowScores.count) }
    public var hasVocals: Bool { vocalSeconds >= Self.minimumVocalSeconds }

    public init(range: Range<TimeInterval>, windowScores: [Float]) {
        self.range = range
        self.windowScores = windowScores
    }

    /// Classifies `range` of the file at `url`; the range is clamped to the file.
    public static func analyze(url: URL, range: Range<TimeInterval>) async throws -> SmartMixVocals {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        let firstFrame = max(0, min(file.length, AVAudioFramePosition(range.lowerBound * rate)))
        let endFrame = max(firstFrame, min(file.length, AVAudioFramePosition(range.upperBound * rate)))
        let clamped = Double(firstFrame) / rate ..< Double(endFrame) / rate

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: windowDuration, preferredTimescale: CMTimeScale(rate))
        request.overlapFactor = 1 - hop / windowDuration
        let observer = Observer()
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: observer)

        file.framePosition = firstFrame
        let chunk = AVAudioFrameCount(rate)
        var position = firstFrame
        while position < endFrame {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(AVAudioFramePosition(chunk), endFrame - position))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            // Compressed files can report a few more frames than they decode; stop at the real end.
            do { try file.read(into: buffer, frameCount: count) } catch where position > firstFrame { break }
            guard buffer.frameLength > 0 else { break }
            analyzer.analyze(buffer, atAudioFramePosition: position - firstFrame)
            position += AVAudioFramePosition(buffer.frameLength)
        }
        analyzer.completeAnalysis()
        if let error = observer.error { throw error }
        return SmartMixVocals(range: clamped, windowScores: observer.scores())
    }

    /// Collects window scores; SoundAnalysis calls it on its own queue.
    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [(start: Double, score: Float)] = []
        private var failure: Error?

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let score = SmartMixVocals.vocalClasses.reduce(Float(0)) { best, identifier in
                max(best, Float(result.classification(forIdentifier: identifier)?.confidence ?? 0))
            }
            lock.withLock { windows.append((result.timeRange.start.seconds, score)) }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock { failure = error }
        }

        var error: Error? { lock.withLock { failure } }

        func scores() -> [Float] {
            lock.withLock { windows.sorted { $0.start < $1.start }.map(\.score) }
        }
    }
}
#endif
