import AVFoundation
@testable import EnsembleCore
import XCTest

final class StreamingAudioDecoderTests: XCTestCase {
    func testDecoderEmitsPCMBeforeEndOfM4AFile() throws {
        let fixtureURL = URL(fileURLWithPath: "/System/Library/CoreServices/Language Chooser.app/Contents/Resources/VOInstructions-en.m4a")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("System M4A fixture is unavailable on this macOS install")
        }

        let data = try Data(contentsOf: fixtureURL)
        let decoder = try StreamingAudioDecoder(fileExtension: "m4a")
        var sawFormat = false
        var sawPacket = false
        var firstPCMByteOffset: Int?
        var decodedFrames: AVAudioFrameCount = 0
        var bytesFed = 0

        decoder.onFormatReady = { _ in sawFormat = true }
        decoder.onFirstPacket = { sawPacket = true }
        decoder.onFirstPCM = { firstPCMByteOffset = bytesFed }
        decoder.onPCMBuffer = { buffer in decodedFrames += buffer.frameLength }

        for chunkStart in stride(from: 0, to: data.count, by: 4096) {
            let chunkEnd = min(chunkStart + 4096, data.count)
            try decoder.append(data[chunkStart ..< chunkEnd])
            bytesFed = chunkEnd
            if decodedFrames > 0 { break }
        }

        XCTAssertTrue(sawFormat)
        XCTAssertTrue(sawPacket)
        XCTAssertGreaterThan(decodedFrames, 0)
        XCTAssertNotNil(firstPCMByteOffset)
        XCTAssertLessThan(firstPCMByteOffset ?? data.count, data.count)
    }

    func testDecoderEmitsPCMBeforeEndOfGeneratedMP3File() throws {
        let fixtureURL = try makeMP3Fixture(duration: 5)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let data = try Data(contentsOf: fixtureURL)
        let decoder = try StreamingAudioDecoder(fileExtension: "mp3")
        var decodedFrames: AVAudioFrameCount = 0
        var bytesFed = 0
        var firstPCMByteOffset: Int?

        decoder.onFirstPCM = { firstPCMByteOffset = bytesFed }
        decoder.onPCMBuffer = { buffer in decodedFrames += buffer.frameLength }

        for chunkStart in stride(from: 0, to: data.count, by: 1024) {
            let chunkEnd = min(chunkStart + 1024, data.count)
            try decoder.append(data[chunkStart ..< chunkEnd])
            bytesFed = chunkEnd
            if decodedFrames > 0 { break }
        }

        XCTAssertGreaterThan(decodedFrames, 0)
        XCTAssertNotNil(firstPCMByteOffset)
        XCTAssertLessThan(firstPCMByteOffset ?? data.count, data.count)
    }

    func testDecoderDrainsFullMP3ToExpectedDuration() throws {
        let fixtureDuration: TimeInterval = 5
        let fixtureURL = try makeMP3Fixture(duration: fixtureDuration)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let data = try Data(contentsOf: fixtureURL)
        let decoder = try StreamingAudioDecoder(fileExtension: "mp3")
        var decodedFrames: AVAudioFrameCount = 0
        var outputSampleRate: Double?

        decoder.onFormatReady = { format in outputSampleRate = format.sampleRate }
        decoder.onPCMBuffer = { buffer in decodedFrames += buffer.frameLength }

        for chunkStart in stride(from: 0, to: data.count, by: 1024) {
            let chunkEnd = min(chunkStart + 1024, data.count)
            try decoder.append(data[chunkStart ..< chunkEnd])
        }

        let sampleRate = try XCTUnwrap(outputSampleRate)
        let decodedDuration = Double(decodedFrames) / sampleRate
        XCTAssertGreaterThan(decodedDuration, fixtureDuration - 0.5)
        XCTAssertLessThan(decodedDuration, fixtureDuration + 0.5)
    }

    /// PCM and constant-bitrate streams arrive without packet descriptions and
    /// must not reach the variable-bitrate compressed buffer initializer, which raises.
    func testDecoderDrainsPCMAndConstantBitrateFilesToExpectedDuration() throws {
        let fixtureDuration: TimeInterval = 2
        let pcm16: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let cases: [(name: String, fileExtension: String, settings: [String: Any])] = [
            ("WAV 16-bit PCM", "wav", pcm16.merging([AVLinearPCMIsBigEndianKey: false]) { $1 }),
            ("WAV 24-bit PCM", "wav", pcm16.merging([AVLinearPCMBitDepthKey: 24, AVLinearPCMIsBigEndianKey: false]) { $1 }),
            ("AIFF 16-bit PCM", "aiff", pcm16.merging([AVLinearPCMIsBigEndianKey: true]) { $1 }),
            ("CAF 32-bit float PCM", "caf", [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]),
            ("CAF µ-law", "caf", [AVFormatIDKey: kAudioFormatULaw]),
            ("WAV A-law", "wav", [AVFormatIDKey: kAudioFormatALaw]),
            ("CAF IMA4", "caf", [AVFormatIDKey: kAudioFormatAppleIMA4])
        ]

        for testCase in cases {
            let fixtureURL = try makeSineFixture(
                fileExtension: testCase.fileExtension,
                settings: testCase.settings,
                duration: fixtureDuration
            )
            defer { try? FileManager.default.removeItem(at: fixtureURL) }

            let data = try Data(contentsOf: fixtureURL)
            let decoder = try StreamingAudioDecoder(fileExtension: testCase.fileExtension)
            var decodedFrames: AVAudioFrameCount = 0
            var outputSampleRate: Double?
            decoder.onFormatReady = { format in outputSampleRate = format.sampleRate }
            decoder.onPCMBuffer = { buffer in decodedFrames += buffer.frameLength }

            for chunkStart in stride(from: 0, to: data.count, by: 4096) {
                try decoder.append(data[chunkStart ..< min(chunkStart + 4096, data.count)])
            }

            let sampleRate = try XCTUnwrap(outputSampleRate, testCase.name)
            let decodedDuration = Double(decodedFrames) / sampleRate
            XCTAssertEqual(decodedDuration, fixtureDuration, accuracy: 0.1, testCase.name)
        }
    }

    private func makeSineFixture(
        fileExtension: String,
        settings: [String: Any],
        duration: TimeInterval
    ) throws -> URL {
        let sampleRate = 44100.0
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-decoder-\(UUID().uuidString).\(fileExtension)")
        let fileSettings = settings.merging([
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2
        ]) { $1 }
        let file = try AVAudioFile(forWriting: fixtureURL, settings: fileSettings)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        for channel in 0 ..< 2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0 ..< Int(frameCount) {
                samples[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return fixtureURL
    }

    private func findExecutable(named name: String) -> URL? {
        let paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        return paths
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func makeMP3Fixture(duration: TimeInterval) throws -> URL {
        guard let ffmpegURL = findExecutable(named: "ffmpeg") else {
            throw XCTSkip("ffmpeg is unavailable for generated MP3 fixture")
        }

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-decoder-\(UUID().uuidString).mp3")
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-f", "lavfi",
            "-i", "sine=frequency=440:duration=\(duration)",
            "-codec:a", "libmp3lame",
            "-q:a", "7",
            "-map_metadata", "-1",
            "-id3v2_version", "0",
            fixtureURL.path
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ffmpeg could not generate MP3 fixture")
        }
        return fixtureURL
    }
}
