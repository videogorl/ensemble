import AVFoundation
import Foundation

final class StreamingPCMBuffer {
    enum BufferError: Error {
        case unsupportedFormat
    }

    let format: AVAudioFormat
    let capacityFrames: Int

    private let condition = NSCondition()
    private var channels: [[Float]]
    private var readIndex = 0
    private var writeIndex = 0
    private var storedFrames = 0
    private var consumedFrames: Int64 = 0
    private var missingFrames: Int64 = 0
    private var rebuffering = false

    struct RenderProgress {
        let consumedFrames: Int64
        let missingFrames: Int64
        let bufferedFrames: Int
        let isRebuffering: Bool
    }

    var renderProgress: RenderProgress {
        condition.lock()
        defer { condition.unlock() }
        return RenderProgress(consumedFrames: consumedFrames, missingFrames: missingFrames,
                              bufferedFrames: storedFrames, isRebuffering: rebuffering)
    }

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
        condition.lock()
        defer { condition.unlock() }
        return storedFrames
    }

    var remainingCapacity: Int {
        condition.lock()
        defer { condition.unlock() }
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

        condition.lock()
        defer { condition.unlock() }

        let framesToWrite = min(Int(buffer.frameLength), capacityFrames - storedFrames)
        guard framesToWrite > 0 else { return 0 }

        writeLocked(sourceChannels: sourceChannels, sourceOffset: 0, frameCount: framesToWrite)
        condition.signal()
        return framesToWrite
    }

    func writeBlocking(
        _ buffer: AVAudioPCMBuffer,
        shouldContinue: () -> Bool
    ) throws {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == format.channelCount,
              let sourceChannels = buffer.floatChannelData else {
            throw BufferError.unsupportedFormat
        }

        let totalFrames = Int(buffer.frameLength)
        var writtenFrames = 0

        condition.lock()
        defer { condition.unlock() }

        while writtenFrames < totalFrames, shouldContinue() {
            let freeFrames = capacityFrames - storedFrames
            if freeFrames == 0 {
                condition.wait(until: Date().addingTimeInterval(0.05))
                continue
            }

            let framesToWrite = min(totalFrames - writtenFrames, freeFrames)
            writeLocked(sourceChannels: sourceChannels, sourceOffset: writtenFrames, frameCount: framesToWrite)
            writtenFrames += framesToWrite
            condition.signal()
        }
    }

    @discardableResult
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount) throws -> Int {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              buffer.format.channelCount == format.channelCount,
              let targetChannels = buffer.floatChannelData else {
            throw BufferError.unsupportedFormat
        }

        condition.lock()
        defer { condition.unlock() }

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
        if framesToRead > 0 {
            condition.signal()
        }
        return framesToRead
    }

    @discardableResult
    func read(
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: AVAudioFrameCount,
        resumeFrames: Int = 0,
        isComplete: Bool = false
    ) -> Int {
        condition.lock()
        defer { condition.unlock() }

        let requestedFrames = Int(frameCount)
        if isComplete || storedFrames >= min(capacityFrames, resumeFrames) {
            rebuffering = false
        }
        let framesToRead = rebuffering ? 0 : min(requestedFrames, storedFrames)
        if framesToRead < requestedFrames, !isComplete, resumeFrames > 0 {
            rebuffering = true
        }
        consumedFrames += Int64(framesToRead)
        missingFrames += Int64(requestedFrames - framesToRead)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)

        for channelIndex in 0 ..< min(buffers.count, channels.count) {
            let audioBuffer = buffers[channelIndex]
            guard let data = audioBuffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frameOffset in 0 ..< requestedFrames {
                if frameOffset < framesToRead {
                    let sourceIndex = (readIndex + frameOffset) % capacityFrames
                    data[frameOffset] = channels[channelIndex][sourceIndex]
                } else {
                    data[frameOffset] = 0
                }
            }
        }

        readIndex = (readIndex + framesToRead) % capacityFrames
        storedFrames -= framesToRead
        if framesToRead > 0 {
            condition.signal()
        }
        return framesToRead
    }

    func clear() {
        condition.lock()
        defer { condition.unlock() }
        readIndex = 0
        writeIndex = 0
        storedFrames = 0
        consumedFrames = 0
        missingFrames = 0
        rebuffering = false
        condition.broadcast()
    }

    func wakeWaiters() {
        condition.lock()
        condition.broadcast()
        condition.unlock()
    }

    private func writeLocked(
        sourceChannels: UnsafePointer<UnsafeMutablePointer<Float>>,
        sourceOffset: Int,
        frameCount: Int
    ) {
        for frameOffset in 0 ..< frameCount {
            let targetIndex = (writeIndex + frameOffset) % capacityFrames
            for channelIndex in channels.indices {
                channels[channelIndex][targetIndex] = sourceChannels[channelIndex][sourceOffset + frameOffset]
            }
        }

        writeIndex = (writeIndex + frameCount) % capacityFrames
        storedFrames += frameCount
    }
}
