import XCTest
@testable import EnsembleAPI

final class MP3VBRHeaderUtilityTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal VBR MP3 file with ID3v2 tag and a few MPEG frames (no XING header).
    /// Uses MPEG1 Layer III, 44100Hz, Joint Stereo with varying bitrates.
    private func buildTestMP3(frameCount: Int = 10) -> Data {
        var data = Data()

        // ID3v2.4 tag: "ID3" + version(2) + flags(1) + syncsafe size(4)
        // Content: TSSE frame with "Test" (4 bytes + frame header)
        let id3Content = Data([
            0x54, 0x53, 0x53, 0x45, // "TSSE"
            0x00, 0x00, 0x00, 0x05, // Size: 5
            0x00, 0x00,             // Flags
            0x03,                   // UTF-8 encoding
            0x54, 0x65, 0x73, 0x74  // "Test"
        ])
        data.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        data.append(contentsOf: [0x04, 0x00])         // Version 2.4
        data.append(0x00)                             // Flags
        // Syncsafe size of id3Content
        let sz = id3Content.count
        data.append(UInt8((sz >> 21) & 0x7F))
        data.append(UInt8((sz >> 14) & 0x7F))
        data.append(UInt8((sz >> 7) & 0x7F))
        data.append(UInt8(sz & 0x7F))
        data.append(id3Content)

        // Alternate between 128kbps and 160kbps frames (VBR)
        let bitrates = [128, 160]
        for i in 0..<frameCount {
            let bitrate = bitrates[i % bitrates.count]
            let frame = buildMPEGFrame(bitrate: bitrate)
            data.append(frame)
        }

        return data
    }

    /// Build a single MPEG1 Layer III frame at a given bitrate (44100Hz, joint stereo).
    private func buildMPEGFrame(bitrate: Int) -> Data {
        // MPEG1, Layer III, no CRC, joint stereo
        // Byte 0: 0xFF
        // Byte 1: 0xFB (sync + MPEG1 + Layer III + no CRC)
        let bitrateIndex: UInt8
        switch bitrate {
        case 32:  bitrateIndex = 1
        case 40:  bitrateIndex = 2
        case 48:  bitrateIndex = 3
        case 56:  bitrateIndex = 4
        case 64:  bitrateIndex = 5
        case 80:  bitrateIndex = 6
        case 96:  bitrateIndex = 7
        case 112: bitrateIndex = 8
        case 128: bitrateIndex = 9
        case 160: bitrateIndex = 10
        case 192: bitrateIndex = 11
        case 224: bitrateIndex = 12
        case 256: bitrateIndex = 13
        case 320: bitrateIndex = 14
        default:  bitrateIndex = 9 // 128
        }

        // frame_size = 144 * bitrate_bps / sample_rate (no padding)
        let frameSize = 144 * bitrate * 1000 / 44100

        let b2: UInt8 = (bitrateIndex << 4) | 0x00 // SR index 0 (44100), no padding
        let b3: UInt8 = 0x44 // Joint stereo, mode ext 01

        var frame = Data(count: frameSize)
        frame[0] = 0xFF
        frame[1] = 0xFB
        frame[2] = b2
        frame[3] = b3

        return frame
    }

    // MARK: - Tests

    func testInjectsXingHeader() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_xing_\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let originalData = buildTestMP3(frameCount: 20)
        try originalData.write(to: fileURL)
        let originalSize = originalData.count

        // Inject XING header
        try MP3VBRHeaderUtility.injectXingHeaderIfNeeded(at: fileURL)

        // File should be larger (XING frame added)
        let newData = try Data(contentsOf: fileURL)
        XCTAssertGreaterThan(newData.count, originalSize, "File should be larger after XING injection")

        // Verify ID3v2 tag is preserved
        XCTAssertEqual(newData[0], 0x49) // 'I'
        XCTAssertEqual(newData[1], 0x44) // 'D'
        XCTAssertEqual(newData[2], 0x33) // '3'

        // Find audio start (skip ID3v2)
        let id3Size = (Int(newData[6]) << 21) | (Int(newData[7]) << 14)
                    | (Int(newData[8]) << 7)  | Int(newData[9])
        let audioOffset = 10 + id3Size

        // First audio frame should now be the XING frame
        XCTAssertEqual(newData[audioOffset], 0xFF, "XING frame should start with sync")
        XCTAssertTrue((newData[audioOffset + 1] & 0xE0) == 0xE0, "XING frame should have valid sync")

        // Check for XING tag at the correct offset (MPEG1 stereo = offset 36)
        let xingTagOffset = audioOffset + 36
        let xingTag = Array(newData[xingTagOffset..<(xingTagOffset + 4)])
        XCTAssertEqual(xingTag, [0x58, 0x69, 0x6E, 0x67], "Should contain 'Xing' tag")

        // Check flags (0x03 = frames + bytes)
        let flags = Array(newData[(xingTagOffset + 4)..<(xingTagOffset + 8)])
        XCTAssertEqual(flags, [0x00, 0x00, 0x00, 0x03], "Flags should indicate frames + bytes present")

        // Check frame count (should be 20)
        let frameCountOffset = xingTagOffset + 8
        let frameCount = (Int(newData[frameCountOffset]) << 24)
                       | (Int(newData[frameCountOffset + 1]) << 16)
                       | (Int(newData[frameCountOffset + 2]) << 8)
                       | Int(newData[frameCountOffset + 3])
        XCTAssertEqual(frameCount, 20, "XING header should report 20 frames")
    }

    func testNoOpIfXingAlreadyExists() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_xing_noop_\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let originalData = buildTestMP3(frameCount: 5)
        try originalData.write(to: fileURL)

        // First injection
        try MP3VBRHeaderUtility.injectXingHeaderIfNeeded(at: fileURL)
        let afterFirst = try Data(contentsOf: fileURL)

        // Second injection should be a no-op
        try MP3VBRHeaderUtility.injectXingHeaderIfNeeded(at: fileURL)
        let afterSecond = try Data(contentsOf: fileURL)

        XCTAssertEqual(afterFirst.count, afterSecond.count, "Second injection should not change file size")
        XCTAssertEqual(afterFirst, afterSecond, "Second injection should not modify file")
    }

    func testNoOpForNonMP3Data() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let fileURL = tmpDir.appendingPathComponent("test_xing_nonmp3_\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Write random non-MP3 data
        let randomData = Data((0..<1000).map { _ in UInt8.random(in: 0...255) })
        try randomData.write(to: fileURL)

        // Should not crash or modify the file
        try MP3VBRHeaderUtility.injectXingHeaderIfNeeded(at: fileURL)
        let afterData = try Data(contentsOf: fileURL)
        XCTAssertEqual(randomData, afterData, "Non-MP3 data should not be modified")
    }
}
