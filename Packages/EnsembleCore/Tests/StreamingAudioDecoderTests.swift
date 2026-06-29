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
