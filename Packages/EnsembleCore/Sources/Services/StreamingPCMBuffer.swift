import AVFoundation
import Foundation

final class StreamingPCMBuffer {
    enum BufferError: Error {
        case unsupportedFormat
    }

    let format: AVAudioFormat
    let capacityFrames: Int

    private let lock = NSLock()
    private var channels: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedFrames = 0

    init(format: AVAudioFormat, capacityFrames: Int) throws {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.channelCount > 0,
              capacityFrames > 0 else {
            throw BufferError.unsupportedFormat
        }

        self.format = format
        self.capacityFrames = capacityFrames
        channels = Array(
            repeating: Array(repeating: 0, count: capacityFrames),
            count: Int(format.channelCount)
        )
    }

    var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedFrames
    }

    var remainingCapacity: Int {
        lock.lock()
        defer { lock.unlock() }
        return capacityFrames - storedFrames
    }

    @discardableResult
    func write(_ buffer: AVAudioPCMBuffer) throws -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == format.channelCount,
              let sourceChannels = buffer.floatChannelData else {
            throw BufferError.unsupportedFormat
        }

        lock.lock()
        defer { lock.unlock() }

        let framesToWrite = min(Int(buffer.frameLength), capacityFrames - storedFrames)
        guard framesToWrite > 0 else { return 0 }

        for frameOffset in 0 ..< framesToWrite {
            let targetIndex = (writeIndex + frameOffset) % capacityFrames
            for channelIndex in channels.indices {
                channels[channelIndex][targetIndex] = sourceChannels[channelIndex][frameOffset]
            }
        }

        writeIndex = (writeIndex + framesToWrite) % capacityFrames
        storedFrames += framesToWrite
        return framesToWrite
    }

    @discardableResult
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == format.channelCount,
              let targetChannels = buffer.floatChannelData else {
            throw BufferError.unsupportedFormat
        }

        lock.lock()
        defer { lock.unlock() }

        let requestedFrames = min(Int(frameCount), Int(buffer.frameCapacity))
        let framesToRead = min(requestedFrames, storedFrames)

        for frameOffset in 0 ..< requestedFrames {
            for channelIndex in channels.indices {
                if frameOffset < framesToRead {
                    let sourceIndex = (readIndex + frameOffset) % capacityFrames
                    targetChannels[channelIndex][frameOffset] = channels[channelIndex][sourceIndex]
                } else {
                    targetChannels[channelIndex][frameOffset] = 0
                }
            }
        }

        readIndex = (readIndex + framesToRead) % capacityFrames
        storedFrames -= framesToRead
        buffer.frameLength = AVAudioFrameCount(requestedFrames)
        return framesToRead
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        storedFrames = 0
    }
}
