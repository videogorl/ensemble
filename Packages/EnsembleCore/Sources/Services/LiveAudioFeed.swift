import Accelerate
import AVFoundation
import Foundation
import os
import QuartzCore

/// Recent mixed playback output for full-screen visualizers.
///
/// The playback engine taps its main mixer only while at least one reader is
/// active, so the feed costs nothing when no visualizer is on screen. Tap
/// buffers arrive in chunks of 100 ms or more; readers play them out on the
/// host clock, one chunk behind, so motion stays smooth between deliveries.
public final class LiveAudioFeed: @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        /// Total mono samples written since capture started.
        var writtenCount = 0
        var sampleRate: Double = 44_100
        /// Host time, in seconds, at which `writtenCount` is heard.
        var writtenEndHostSeconds: Double = 0
        var chunkDuration: Double = 0.1
        var outputLatency: Double = 0
        var lastIngestSeconds: Double = -.infinity
        var mixBuffer: [Float] = []
    }

    /// About 2.7 s at 48 kHz, enough to cover AirPlay output latency.
    static let capacity = 1 << 17
    private static let silenceTimeout: Double = 0.35

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var activeReaders = Set<UUID>()

    /// Called on the main actor when capture should start or stop.
    var onCaptureChanged: ((Bool) -> Void)?

    public init() {}

    @MainActor
    public var isCapturing: Bool { !activeReaders.isEmpty }

    /// Registers or removes an on-screen reader. Capture runs while any reader is active.
    @MainActor
    public func setReader(_ id: UUID, isActive: Bool) {
        let wasCapturing = isCapturing
        if isActive {
            activeReaders.insert(id)
        } else {
            activeReaders.remove(id)
        }
        let capturing = isCapturing
        guard wasCapturing != capturing else { return }
        state.withLockUnchecked { state in
            state = State()
            if capturing {
                state.samples = [Float](repeating: 0, count: Self.capacity)
            }
        }
        onCaptureChanged?(capturing)
    }

    func setOutputLatency(_ latency: TimeInterval) {
        state.withLockUnchecked { $0.outputLatency = max(0, latency) }
    }

    /// Appends a tap buffer, mixed to mono. Called on the engine's tap thread.
    func ingest(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return }
        let sampleRate = buffer.format.sampleRate
        let now = CACurrentMediaTime()
        let chunkDuration = Double(frameCount) / sampleRate
        let startHostSeconds = time.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: time.hostTime)
            : now - chunkDuration

        state.withLockUnchecked { state in
            guard state.samples.count == Self.capacity else { return }
            if state.mixBuffer.count < frameCount {
                state.mixBuffer = [Float](repeating: 0, count: frameCount)
            }
            state.mixBuffer.withUnsafeMutableBufferPointer { mix in
                let mixBase = mix.baseAddress!
                memcpy(mixBase, channels[0], frameCount * MemoryLayout<Float>.size)
                for channel in 1..<max(1, channelCount) {
                    vDSP_vadd(mixBase, 1, channels[channel], 1, mixBase, 1, vDSP_Length(frameCount))
                }
                if channelCount > 1 {
                    var scale = 1 / Float(channelCount)
                    vDSP_vsmul(mixBase, 1, &scale, mixBase, 1, vDSP_Length(frameCount))
                }
                state.samples.withUnsafeMutableBufferPointer { ring in
                    var remaining = frameCount
                    var source = mixBase
                    var writeIndex = state.writtenCount % Self.capacity
                    while remaining > 0 {
                        let run = min(remaining, Self.capacity - writeIndex)
                        memcpy(ring.baseAddress! + writeIndex, source, run * MemoryLayout<Float>.size)
                        remaining -= run
                        source += run
                        writeIndex = (writeIndex + run) % Self.capacity
                    }
                }
            }
            state.writtenCount += frameCount
            state.sampleRate = sampleRate
            state.chunkDuration = chunkDuration
            state.writtenEndHostSeconds = startHostSeconds + chunkDuration
            state.lastIngestSeconds = now
        }
    }

    /// Copies the samples being heard right now into `destination`, oldest first.
    /// Returns false, leaving `destination` untouched, when output is silent or stalled.
    func copyCurrentWindow(into destination: inout [Float]) -> Bool {
        let length = destination.count
        guard length > 0, length <= Self.capacity else { return false }
        let now = CACurrentMediaTime()
        return state.withLockUnchecked { state in
            guard state.samples.count == Self.capacity,
                  state.writtenCount >= length,
                  now - state.lastIngestSeconds < Self.silenceTimeout else { return false }

            // Play out one chunk behind the newest delivery so reads never run dry.
            let heardSeconds = now - state.outputLatency - state.chunkDuration
            let offsetFromEnd = Int(((state.writtenEndHostSeconds - heardSeconds) * state.sampleRate).rounded())
            let oldestEnd = max(length, state.writtenCount - Self.capacity + length)
            let endIndex = min(state.writtenCount, max(oldestEnd, state.writtenCount - offsetFromEnd))

            state.samples.withUnsafeBufferPointer { ring in
                destination.withUnsafeMutableBufferPointer { output in
                    var readIndex = (endIndex - length) % Self.capacity
                    var copied = 0
                    while copied < length {
                        let run = min(length - copied, Self.capacity - readIndex)
                        memcpy(output.baseAddress! + copied, ring.baseAddress! + readIndex, run * MemoryLayout<Float>.size)
                        copied += run
                        readIndex = (readIndex + run) % Self.capacity
                    }
                }
            }
            return true
        }
    }

    var sampleRate: Double {
        state.withLockUnchecked { $0.sampleRate }
    }
}

/// Turns the feed's current window into a waveform and a log-spaced spectrum.
/// Owned by one renderer and used from one thread.
public final class LiveAudioAnalyzer {
    public static let waveformLength = 512
    public static let spectrumBandCount = 64

    private static let fftLog2 = 11
    private static let fftSize = 1 << fftLog2
    private static let lowestFrequency: Double = 40
    private static let highestFrequency: Double = 16_000
    private static let floorDecibels: Float = -72
    /// Loud mastered music sits well above a lone sine in each band; keep it below the top.
    private static let headroomDecibels: Float = 12

    /// Mono samples in -1...1, oldest first.
    public private(set) var waveform = [Float](repeating: 0, count: waveformLength)
    /// Band levels in 0...1, bass first.
    public private(set) var spectrum = [Float](repeating: 0, count: spectrumBandCount)
    /// Overall loudness in 0...1.
    public private(set) var level: Float = 0

    private let feed: LiveAudioFeed
    private let fft = vDSP.FFT(log2n: vDSP_Length(fftLog2), radix: .radix2, ofType: DSPSplitComplex.self)
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
    private var samples = [Float](repeating: 0, count: fftSize)
    private var windowed = [Float](repeating: 0, count: fftSize)
    private var real = [Float](repeating: 0, count: fftSize / 2)
    private var imaginary = [Float](repeating: 0, count: fftSize / 2)
    private var power = [Float](repeating: 0, count: fftSize / 2)
    private var bandBins: [Range<Int>] = []
    private var bandSampleRate: Double = 0

    public init(feed: LiveAudioFeed) {
        self.feed = feed
    }

    /// Refreshes the waveform and spectrum. Returns false when there is no live audio.
    @discardableResult
    public func update() -> Bool {
        guard feed.copyCurrentWindow(into: &samples), let fft else {
            vDSP.fill(&waveform, with: 0)
            vDSP.fill(&spectrum, with: 0)
            level = 0
            return false
        }

        let stride = Self.fftSize / Self.waveformLength
        for index in 0..<Self.waveformLength {
            waveform[index] = samples[index * stride]
        }
        level = min(1, vDSP.rootMeanSquare(samples) * 2.5)

        vDSP.multiply(samples, window, result: &windowed)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                let input = split
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }

        refreshBandBins(sampleRate: feed.sampleRate)
        // A full-scale sine peaks at (N/2)^2 in this packed, Hann-windowed FFT.
        let fullScalePower = Float(Self.fftSize / 2) * Float(Self.fftSize / 2)
        for (band, bins) in bandBins.enumerated() {
            var peak: Float = 0
            for bin in bins { peak = max(peak, power[bin]) }
            // Tilt +3 dB per octave so cymbals and vocals register next to the bass.
            let tilt = 3 * log2(Float(band + 1) / Float(Self.spectrumBandCount) * 8 + 1)
            let decibels = 10 * log10(max(peak / fullScalePower, 1e-12)) + tilt - Self.headroomDecibels
            spectrum[band] = max(0, min(1, 1 - decibels / Self.floorDecibels))
        }
        return true
    }

    private func refreshBandBins(sampleRate: Double) {
        guard sampleRate != bandSampleRate, sampleRate > 0 else { return }
        bandSampleRate = sampleRate
        let binWidth = sampleRate / Double(Self.fftSize)
        let maxBin = Self.fftSize / 2 - 1
        let ratio = Self.highestFrequency / Self.lowestFrequency
        bandBins = (0..<Self.spectrumBandCount).map { band in
            let low = Self.lowestFrequency * pow(ratio, Double(band) / Double(Self.spectrumBandCount))
            let high = Self.lowestFrequency * pow(ratio, Double(band + 1) / Double(Self.spectrumBandCount))
            let lowBin = min(maxBin, max(1, Int(low / binWidth)))
            let highBin = min(maxBin, max(lowBin + 1, Int(high / binWidth)))
            return lowBin..<highBin
        }
    }
}
