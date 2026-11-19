import AVFoundation
import CoreML
import EnsembleSupport
import Foundation

/// Experiment: a song's beats and bar lines from the Beat This! network (CPJKU, MIT licence; the small model),
/// in place of `SmartMixBeatGrid`'s onset tracking. On only under automation, with
/// `ENSEMBLE_AUTOMATION_SMARTMIX_NEURAL_BEATS=1`.
enum SmartMixNeuralBeats {
    static let isEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["ENSEMBLE_AUTOMATION_MODE"] == "1" && environment["ENSEMBLE_AUTOMATION_SMARTMIX_NEURAL_BEATS"] == "1"
    }()

    private static let rate = 22_050.0
    private static let hop = 441
    private static let frameRate = rate / Double(hop)
    /// The network reads 30 s at a time and its outermost frames are discarded.
    private static let chunkFrames = 1_500
    private static let border = 6
    /// Frame k of a chunk is centred on sample 512 + 441 k of its audio.
    private static let chunkSamples = (chunkFrames - 1) * hop + 1_024

    private static let model: MLModel? = {
        guard let url = Bundle.module.url(forResource: "BeatThis", withExtension: "mlmodelc") else { return nil }
        return try? MLModel(contentsOf: url)
    }()

    static func analyze(fileURL: URL) -> SmartMixBeatGrid? {
        guard let model, let samples = mono(fileURL: fileURL), samples.count >= Int(rate * 8) else { return nil }
        let frames = samples.count / hop + 1
        guard let logits = logits(samples, frames: frames, model: model) else { return nil }
        let beats = fillGaps(peaks(logits.beat))
        guard beats.count >= 2 * SmartMixBeatGrid.beatsPerBar + 1 else { return nil }

        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }
        let median = intervals.sorted()[intervals.count / 2]
        let steady = intervals.filter { abs($0 / median - 1) <= 0.1 }.count
        // A bar line counts for the beat it lands on; the grid takes the phase most bar lines agree on.
        var phases = [Int](repeating: 0, count: SmartMixBeatGrid.beatsPerBar)
        var beat = 0
        for bar in peaks(logits.downbeat) {
            while beat + 1 < beats.count, abs(beats[beat + 1] - bar) <= abs(beats[beat] - bar) { beat += 1 }
            if abs(beats[beat] - bar) <= median / 4 { phases[beat % SmartMixBeatGrid.beatsPerBar] += 1 }
        }
        let bars = phases.reduce(0, +)
        let phase = phases.indices.max { phases[$0] < phases[$1] } ?? 0
        return SmartMixBeatGrid(
            beatTimes: beats,
            firstDownbeatIndex: phase,
            bpm: 60 / median,
            // Against Apple Music's grids, 76% of songs keep 90% of their beats on a steady tempo and 82% of those
            // match Apple's beats; this puts that 90% at `SmartMixBeatGrid.trustedConfidence`.
            confidence: min(1, max(0, (Double(steady) / Double(intervals.count) - 0.75) / 0.25)),
            barConfidence: bars > 0 ? Double(phases[phase]) / Double(bars) : 0
        )
    }

    /// Frame-by-frame beat and bar-line scores for the whole song. Chunks overlap by their discarded borders,
    /// and the last one is moved back to end with the song.
    private static func logits(_ samples: [Float], frames: Int, model: MLModel) -> (beat: [Float], downbeat: [Float])? {
        let step = chunkFrames - 2 * border
        var starts = Array(stride(from: -border, to: frames - border, by: step))
        if frames > step { starts[starts.count - 1] = frames - (chunkFrames - border) }
        var beat = [Float](repeating: -1_000, count: frames)
        var downbeat = beat
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: chunkSamples)], dataType: .float32) else { return nil }
        let audio = input.dataPointer.bindMemory(to: Float.self, capacity: chunkSamples)
        // Later chunks first, so an earlier chunk's frames win where two overlap.
        for start in starts.reversed() {
            let first = start * hop - 512
            for index in 0 ..< chunkSamples {
                let sample = first + index
                audio[index] = sample >= 0 && sample < samples.count ? samples[sample] : 0
            }
            guard let provider = try? MLDictionaryFeatureProvider(dictionary: ["audio": input]),
                  let output = try? model.prediction(from: provider),
                  let beats = output.featureValue(for: "beat")?.multiArrayValue,
                  let bars = output.featureValue(for: "downbeat")?.multiArrayValue else { return nil }
            for frame in border ..< chunkFrames - border where start + frame >= 0 && start + frame < frames {
                beat[start + frame] = beats[frame].floatValue
                downbeat[start + frame] = bars[frame].floatValue
            }
        }
        return (beat, downbeat)
    }

    /// Times of the frames that score above zero and highest within 70 ms either side; neighbouring frames merge.
    private static func peaks(_ logits: [Float]) -> [TimeInterval] {
        var times: [TimeInterval] = []
        var run: [Int] = []
        func flush() {
            guard !run.isEmpty else { return }
            times.append(Double(run.reduce(0, +)) / Double(run.count) / frameRate)
            run = []
        }
        for frame in logits.indices where logits[frame] > 0 {
            let neighbours = logits[max(0, frame - 3) ... min(logits.count - 1, frame + 3)]
            guard logits[frame] >= neighbours.max() ?? 0 else { continue }
            if let last = run.last, frame - last > 1 { flush() }
            run.append(frame)
        }
        flush()
        return times
    }

    /// The network marks no beats where it hears none (breaks, quiet passages); the grid counts through them.
    private static func fillGaps(_ beats: [TimeInterval]) -> [TimeInterval] {
        guard beats.count > 2 else { return beats }
        let intervals = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = intervals[intervals.count / 2]
        var filled = [beats[0]]
        for beat in beats.dropFirst() {
            let previous = filled[filled.count - 1]
            let count = ((beat - previous) / median).rounded()
            if count >= 2, abs((beat - previous) / (count * median) - 1) <= 0.1 {
                filled.append(contentsOf: (1 ..< Int(count)).map { previous + (beat - previous) * Double($0) / count })
            }
            filled.append(beat)
        }
        return filled
    }

    /// The whole file as mono at the network's 22.05 kHz.
    private static func mono(fileURL: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: fileURL),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768) else { return nil }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) / file.processingFormat.sampleRate * rate) + 1)
        while true {
            let status = converter.convert(to: output, error: nil) { _, inputStatus in
                guard (try? file.read(into: input)) != nil, input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }
            if let data = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            }
            if status != .haveData { break }
        }
        return samples.isEmpty ? nil : samples
    }
}
