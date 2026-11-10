import AVFoundation
import XCTest

enum AudioFixtures {
    /// A mono 22.05 kHz FLAC of deterministic noise, so its size follows its length.
    static func flac(seconds: Int) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1))
        var seed: UInt32 = 12_345
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 22_050, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
            for _ in 0 ..< seconds {
                buffer.frameLength = 22_050
                for index in 0 ..< 22_050 {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    buffer.floatChannelData![0][index] = Float(Int32(bitPattern: seed) >> 18) / 8_192
                }
                try file.write(from: buffer)
            }
        }
        return try Data(contentsOf: url)
    }
}
