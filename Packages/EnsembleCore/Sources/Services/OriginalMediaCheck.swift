import AVFoundation
import Foundation

/// Judges an original by its own media, never by library metadata, with the decoder that plays it.
enum OriginalMediaCheck {
    /// What a decoder error says about the file: an index at the end of the file ('optm') is a layout
    /// the streaming parser cannot read, not damage; any other parse failure is damage.
    static func classify(decoderError error: Error) -> ProgressiveStreamError? {
        guard let decoderError = error as? StreamingAudioDecoder.DecoderError else { return nil }
        if case let .parseFailed(status) = decoderError, status == optimizeFormatStatus {
            return .unstreamableOriginal(reason: "the index is at the end of the file")
        }
        if case let .parseFailed(status) = decoderError { return .damagedOriginal(reason: "decoder status \(status)") }
        return .damagedOriginal(reason: "decoder error")
    }

    /// What decoding to the end says: nothing decoded from a stream that formed a format cannot be
    /// streamed; audio holding under half of the length the container states is damage.
    static func classify(decodedFrames: Int64, sampleRate: Double, containerSeconds: TimeInterval?) -> ProgressiveStreamError? {
        guard sampleRate > 0 else { return nil }
        if decodedFrames == 0 { return .unstreamableOriginal(reason: "the decoder produced no audio") }
        guard let expected = containerSeconds, expected > 10 else { return nil }
        let decoded = Double(decodedFrames) / sampleRate
        guard decoded < expected * 0.5, decoded < expected - 10 else { return nil }
        return .damagedOriginal(reason: "audio ends at \(Int(decoded)) of \(Int(expected)) seconds")
    }

    /// The length the file's own container states, when Core Audio can read one.
    static func containerSeconds(of fileURL: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0 else { return nil }
        return Double(file.length) / sampleRate
    }

    /// Streams the file through the playback decoder in small chunks, start to end. Stops with
    /// `CancellationError` once `shouldContinue` returns false.
    static func verify(at fileURL: URL, fileExtension: String, shouldContinue: () -> Bool = { true }) throws {
        let decoder: StreamingAudioDecoder
        do { decoder = try StreamingAudioDecoder(fileExtension: fileExtension) } catch {
            throw classify(decoderError: error) ?? error
        }
        var sampleRate = 0.0
        var frames: Int64 = 0
        decoder.onFormatReady = { sampleRate = $0.sampleRate }
        decoder.onPCMBuffer = { frames += Int64($0.frameLength) }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard shouldContinue() else { throw CancellationError() }
            do { try decoder.append(chunk) } catch { throw classify(decoderError: error) ?? error }
        }
        guard sampleRate > 0 else { throw ProgressiveStreamError.damagedOriginal(reason: "no audio format") }
        if let verdict = classify(decodedFrames: frames, sampleRate: sampleRate, containerSeconds: containerSeconds(of: fileURL)) {
            throw verdict
        }
    }

    /// kAudioFileStreamError_NotOptimized, 'optm'.
    private static let optimizeFormatStatus: OSStatus = 0x6F70_746D
}
