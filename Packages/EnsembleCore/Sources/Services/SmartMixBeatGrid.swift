import Accelerate
import Foundation

/// A whole-song beat grid with bar lines, from decoded audio alone.
///
/// Beats come from dynamic-programming beat tracking (Ellis 2007) over `SmartMixTempoEstimator`'s onset
/// curve at its whole-song tempo. Bars are four beats long; the first bar line is the beat phase where
/// harmony, timbre and bass change most. Use the grid only when `isTrusted`.
public struct SmartMixBeatGrid: Equatable, Sendable, Codable {
    public static let beatsPerBar = 4
    /// Against Apple Music's grids, about 30% of songs reach 0.7 and 85% of those match Apple's beats; SmartMix
    /// blends on the looser 0.6.
    public static let trustedConfidence = 0.6
    public static let trustedBarConfidence = 0.5

    public let beatTimes: [TimeInterval]
    /// Bars start at `beatTimes[firstDownbeatIndex + n * beatsPerBar]`.
    public let firstDownbeatIndex: Int
    public let bpm: Double
    /// Tempo clarity x phase steadiness x agreement with a looser tracking of the same curve, 0...1.
    public let confidence: Double
    /// How clearly one bar phase beats the runner-up, 0...1.
    public let barConfidence: Double

    public var isTrusted: Bool { confidence >= Self.trustedConfidence }
    public var hasTrustedBars: Bool { isTrusted && barConfidence >= Self.trustedBarConfidence }

    /// Whether beat `index` starts a bar.
    public func isDownbeat(_ index: Int) -> Bool {
        index >= firstDownbeatIndex && (index - firstDownbeatIndex) % Self.beatsPerBar == 0
    }

    public var downbeatTimes: [TimeInterval] {
        stride(from: firstDownbeatIndex, to: beatTimes.count, by: Self.beatsPerBar).map { beatTimes[$0] }
    }

    public static func analyze(monoSamples: [Float], sampleRate: Double) -> SmartMixBeatGrid? {
        guard sampleRate > 0, monoSamples.count >= Int(sampleRate * 8) else { return nil }
        let factor = max(1, Int((sampleRate / SmartMixTempoEstimator.analysisRate).rounded()))
        let rate = sampleRate / Double(factor)
        var reduced = [Float](repeating: 0, count: monoSamples.count / factor)
        let averaging = [Float](repeating: 1 / Float(factor), count: factor)
        vDSP_desamp(monoSamples, vDSP_Stride(factor), averaging, &reduced, vDSP_Length(reduced.count), vDSP_Length(factor))
        return analyze(reducedSamples: reduced, rate: rate)
    }

    static func analyze(reducedSamples samples: [Float], rate: Double) -> SmartMixBeatGrid? {
        let hop = Double(SmartMixTempoEstimator.hop)
        let frameRate = rate / hop
        let flux = SmartMixTempoEstimator.onsetStrength(samples)
        guard let tempo = SmartMixTempoEstimator.estimate(onsetStrength: flux, frameRate: frameRate) else { return nil }
        let period = frameRate * 60 / tempo.bpm

        let frames = trackBeats(flux, period: period, tightness: 1_600)
        guard frames.count >= 2 * beatsPerBar + 1 else { return nil }
        // Flux index i is the rise into frame i + 1, which peaks as a sound reaches the window's middle.
        let lag = 1 + Double(SmartMixTempoEstimator.window) / (2 * hop)
        let times = frames.map { (Double($0) + lag) / frameRate }
        let loose = trackBeats(flux, period: period, tightness: 200).map { (Double($0) + lag) / frameRate }

        let steadiness = min(1, max(0, 1 - 4 * meanPhaseJump(frames)))
        let (firstDownbeat, barMargin) = barPhase(samples, rate: rate, beatTimes: times)
        return SmartMixBeatGrid(
            beatTimes: times,
            firstDownbeatIndex: firstDownbeat,
            bpm: tempo.bpm,
            confidence: tempo.confidence * steadiness * fMeasure(times, loose),
            barConfidence: min(1, barMargin / 0.6)
        )
    }

    // MARK: - Beats

    /// Ellis's dynamic programme: each beat adds the smoothed onset strength at its frame and pays
    /// `tightness * log(interval / period)^2` for its distance from the previous beat.
    static func trackBeats(_ flux: [Float], period: Double, tightness: Double) -> [Int] {
        let count = flux.count
        guard period >= 2, count > Int(2 * period) else { return [] }
        let std = Double(standardDeviation(flux))
        let scale = Float(1 / (std + 1e-9))

        let reach = Int(period)
        let kernel = (-reach ... reach).map { Float(exp(-0.5 * pow(Double($0) * 32 / period, 2))) }
        var local = [Float](repeating: 0, count: count)
        for frame in 0 ..< count {
            var sum: Float = 0
            for (offset, weight) in zip(-reach ... reach, kernel) where frame + offset >= 0 && frame + offset < count {
                sum += flux[frame + offset] * weight
            }
            local[frame] = sum * scale
        }

        let offsets = Array(Int((-2 * period).rounded()) ... -Int((period / 2).rounded()))
        let penalties = offsets.map { Float(-tightness * pow(log(-Double($0) / period), 2)) }
        var score = local
        var previous = [Int](repeating: -1, count: count)
        for frame in 0 ..< count {
            var best = -Float.infinity
            for (offset, penalty) in zip(offsets, penalties) where frame + offset >= 0 {
                let candidate = score[frame + offset] + penalty
                if candidate > best { best = candidate; previous[frame] = frame + offset }
            }
            if previous[frame] >= 0 { score[frame] = local[frame] + best }
        }

        // The last beat is the best-scoring frame within the final period.
        var beat = (count - Int(period) ..< count).max { score[$0] < score[$1] } ?? count - 1
        var beats = [beat]
        while previous[beat] >= 0 {
            beat = previous[beat]
            beats.append(beat)
        }
        return beats.reversed()
    }

    /// Fits a line to each run of 32 beats and measures, in beats (0...0.5), how far the next run sits from
    /// where that line predicts it. A tracker that slides between the beat and the off-beat scores near 0.5.
    static func meanPhaseJump(_ beats: [Int], run: Int = 32) -> Double {
        let runs = beats.count / run
        guard runs >= 3 else { return 0.5 }
        var previous: (slope: Double, intercept: Double)?
        var total = 0.0
        for index in 0 ..< runs {
            let range = index * run ..< (index + 1) * run
            let xs = range.map(Double.init)
            let ys = range.map { Double(beats[$0]) }
            let meanX = xs.reduce(0, +) / Double(run)
            let meanY = ys.reduce(0, +) / Double(run)
            let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) } / xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
            if let line = previous {
                let shifts = zip(xs, ys).map { ($0.1 - (line.slope * $0.0 + line.intercept)) / line.slope }.sorted()
                let shift = (shifts[run / 2 - 1] + shifts[run / 2]) / 2
                total += abs(shift - shift.rounded())
            }
            previous = (slope, meanY - slope * meanX)
        }
        return total / Double(runs - 1)
    }

    /// Share of beats one-to-one within 70 ms of the other list (F-measure).
    static func fMeasure(_ estimated: [TimeInterval], _ reference: [TimeInterval], tolerance: TimeInterval = 0.07) -> Double {
        guard !estimated.isEmpty, !reference.isEmpty else { return 0 }
        var (i, j, hits) = (0, 0, 0)
        while i < estimated.count, j < reference.count {
            let difference = estimated[i] - reference[j]
            if abs(difference) <= tolerance {
                hits += 1; i += 1; j += 1
            } else if difference < 0 {
                i += 1
            } else {
                j += 1
            }
        }
        return 2 * Double(hits) / Double(estimated.count + reference.count)
    }

    // MARK: - Bars

    private static let fftSize = 2048

    /// The beat phase (0..<4) where, on average, chords, timbre and low-frequency energy change most, and
    /// that phase's lead over the runner-up in summed standard scores.
    static func barPhase(_ samples: [Float], rate: Double, beatTimes: [TimeInterval]) -> (phase: Int, margin: Double) {
        let half = fftSize / 2
        let binWidth = rate / Double(fftSize)
        let edges = Array(Set([0] + (0 ..< 16).map { Int((40 * pow(rate / 2 * 0.98 / 40, Double($0) / 15) / binWidth).rounded()) })).sorted()
        let pitchClass = (0 ..< half).map { bin -> Int in
            let frequency = Double(bin) * binWidth
            guard frequency >= 110, frequency <= 2200 else { return -1 }
            let semitones = Int((12 * log2(frequency / 261.626)).rounded())
            return (semitones % 12 + 12) % 12
        }
        let lowBins = 16

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return (0, 0) }
        defer { vDSP_destroy_fftsetup(setup) }
        let hann = (0 ..< fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1))) }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var magnitude = [Float](repeating: 0, count: half)
        func spectrum(at start: Int) -> [Float] {
            let windowed = vDSP.multiply(hann, samples[start ..< start + fftSize])
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imagPointer.baseAddress!)
                    for index in 0 ..< half {
                        realPointer[index] = windowed[2 * index]
                        imagPointer[index] = windowed[2 * index + 1]
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    imagPointer[0] = 0 // Nyquist, packed beside DC
                    vDSP_zvabs(&split, 1, &magnitude, 1, vDSP_Length(half))
                }
            }
            // The packed real FFT is twice numpy's rfft.
            return vDSP.multiply(0.5, magnitude)
        }

        let starts = beatTimes.map { Int($0 * rate) }
        var timbre: [[Float]] = [], chroma: [[Float]] = [], low: [Float] = []
        for index in 0 ..< starts.count - 1 {
            let begin = starts[index]
            let end = max(starts[index + 1], begin + fftSize)
            var windows = Array(stride(from: begin, through: end - fftSize, by: fftSize / 2).prefix(8).filter { $0 + fftSize <= samples.count })
            if windows.isEmpty { windows = [max(0, samples.count - fftSize)] }
            var mean = [Float](repeating: 0, count: half)
            for (position, start) in windows.enumerated() {
                let spectrum = spectrum(at: start)
                if position == 0 { low.append(log1pf(spectrum[..<lowBins].reduce(0, +))) }
                mean = vDSP.add(mean, spectrum)
            }
            mean = vDSP.divide(mean, Float(windows.count))
            timbre.append((0 ..< edges.count - 1).map { log1pf(mean[edges[$0] ..< edges[$0 + 1]].reduce(0, +)) })
            var classes = [Float](repeating: 0, count: 12)
            for bin in 0 ..< half where pitchClass[bin] >= 0 { classes[pitchClass[bin]] += mean[bin] }
            let norm = sqrt(vDSP.sumOfSquares(classes)) + 1e-9
            chroma.append(vDSP.divide(classes, norm))
        }

        let count = low.count
        let changes: [[Float]] = [
            [0] + (1 ..< count).map { sqrt(vDSP.distanceSquared(timbre[$0], timbre[$0 - 1])) },
            [0] + (1 ..< count).map { 1 - vDSP.dot(chroma[$0], chroma[$0 - 1]) },
            [0] + (1 ..< count).map { low[$0] - low[$0 - 1] },
        ]
        var totals = [Double](repeating: 0, count: beatsPerBar)
        for change in changes {
            let mean = vDSP.mean(change)
            let scale = 1 / (Double(standardDeviation(change)) + 1e-9)
            for phase in 0 ..< beatsPerBar {
                let members = stride(from: phase, to: count, by: beatsPerBar).map { Double(change[$0] - mean) * scale }
                totals[phase] += members.reduce(0, +) / Double(max(1, members.count))
            }
        }
        let ranked = totals.indices.sorted { totals[$0] > totals[$1] }
        return (ranked[0], totals[ranked[0]] - totals[ranked[1]])
    }

    /// `vDSP.standardDeviation` needs iOS 18; this is the same population figure.
    private static func standardDeviation(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mean = vDSP.mean(values)
        return max(0, vDSP.meanSquare(values) - mean * mean).squareRoot()
    }
}
