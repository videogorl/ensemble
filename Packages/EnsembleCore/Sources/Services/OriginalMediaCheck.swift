import AVFoundation
import Foundation

/// Judges a downloaded original by its own media, never by library metadata.
enum OriginalMediaCheck {
    /// Decodes the file start to end in small chunks. A decode error, or audio holding under half of the
    /// length the file's own container states, is damage. Stops with `CancellationError` once
    /// `shouldContinue` returns false.
    static func verify(at fileURL: URL, shouldContinue: () -> Bool = { true }) throws {
        func damaged(_ reason: String) -> Error { ProgressiveStreamError.damagedOriginal(reason: reason) }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) } catch { throw damaged("cannot be opened") }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else { return }
        var decoded: AVAudioFramePosition = 0
        do {
            while file.framePosition < file.length {
                guard shouldContinue() else { throw CancellationError() }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Running out of data reads as eofErr (-39); any other error is the decoder rejecting it.
            guard (error as NSError).code == -39 else { throw damaged("decoder error") }
        }
        let expected = Double(file.length) / sampleRate
        let actual = Double(decoded) / sampleRate
        guard expected > 10, actual < expected * 0.5, actual < expected - 10 else { return }
        throw damaged("audio ends at \(Int(actual)) of \(Int(expected)) seconds")
    }
}
