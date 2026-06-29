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

    func testBlockingWriteWaitsForReaderAndPreservesOverflowFrames() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let ring = try StreamingPCMBuffer(format: format, capacityFrames: 2)
        let writerStarted = expectation(description: "writer started")
        let writerFinished = expectation(description: "writer finished")

        DispatchQueue.global(qos: .utility).async {
            writerStarted.fulfill()
            do {
                try ring.writeBlocking(
                    try self.makeBuffer(format: format, left: [1, 2, 3, 4], right: [5, 6, 7, 8])
                ) {
                    true
                }
                writerFinished.fulfill()
            } catch {
                XCTFail("blocking write failed: \(error)")
            }
        }

        wait(for: [writerStarted], timeout: 1)
        waitUntil(timeout: 1) {
            ring.availableFrames == 2
        }
        let first = try emptyBuffer(format: format, capacity: 2)
        XCTAssertEqual(ring.availableFrames, 2)
        XCTAssertEqual(try ring.read(into: first, frameCount: 2), 2)
        XCTAssertEqual(samples(first, channel: 0), [1, 2])

        wait(for: [writerFinished], timeout: 1)
        let second = try emptyBuffer(format: format, capacity: 2)
        XCTAssertEqual(try ring.read(into: second, frameCount: 2), 2)
        XCTAssertEqual(samples(second, channel: 0), [3, 4])
        XCTAssertEqual(samples(second, channel: 1), [7, 8])
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
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
