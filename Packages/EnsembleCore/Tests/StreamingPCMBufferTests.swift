import AVFoundation
@testable import EnsembleCore
import XCTest

final class StreamingPCMBufferTests: XCTestCase {
    func testReadPreservesFrameOrderAcrossWraparound() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let ring = try StreamingPCMBuffer(format: format, capacityFrames: 5)

        _ = try ring.write(makeBuffer(format: format, left: [1, 2, 3], right: [11, 12, 13]))
        _ = try ring.read(into: emptyBuffer(format: format, capacity: 2), frameCount: 2)
        _ = try ring.write(makeBuffer(format: format, left: [4, 5, 6, 7], right: [14, 15, 16, 17]))

        let output = try emptyBuffer(format: format, capacity: 5)
        let read = try ring.read(into: output, frameCount: 5)

        XCTAssertEqual(read, 5)
        XCTAssertEqual(samples(output, channel: 0), [3, 4, 5, 6, 7])
        XCTAssertEqual(samples(output, channel: 1), [13, 14, 15, 16, 17])
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testReadFillsUnderrunWithSilence() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let ring = try StreamingPCMBuffer(format: format, capacityFrames: 4)

        _ = try ring.write(makeBuffer(format: format, left: [1, 2], right: [3, 4]))
        let output = try emptyBuffer(format: format, capacity: 4)
        let read = try ring.read(into: output, frameCount: 4)

        XCTAssertEqual(read, 2)
        XCTAssertEqual(samples(output, channel: 0), [1, 2, 0, 0])
        XCTAssertEqual(samples(output, channel: 1), [3, 4, 0, 0])
    }

    func testWriteAppliesBackpressureAtCapacity() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let ring = try StreamingPCMBuffer(format: format, capacityFrames: 3)

        let written = try ring.write(makeBuffer(format: format, left: [1, 2, 3, 4], right: [5, 6, 7, 8]))

        XCTAssertEqual(written, 3)
        XCTAssertEqual(ring.availableFrames, 3)
        XCTAssertEqual(ring.remainingCapacity, 0)
    }

    private func makeBuffer(format: AVAudioFormat, left: [Float], right: [Float]) throws -> AVAudioPCMBuffer {
        XCTAssertEqual(left.count, right.count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        buffer.frameLength = AVAudioFrameCount(left.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in left.indices {
            channels[0][index] = left[index]
            channels[1][index] = right[index]
        }
        return buffer
    }

    private func emptyBuffer(format: AVAudioFormat, capacity: Int) throws -> AVAudioPCMBuffer {
        try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)))
    }

    private func samples(_ buffer: AVAudioPCMBuffer, channel: Int) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        return (0 ..< Int(buffer.frameLength)).map { channels[channel][$0] }
    }
}
