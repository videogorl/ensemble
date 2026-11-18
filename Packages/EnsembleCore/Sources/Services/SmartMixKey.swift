import Accelerate
import Foundation

/// A musical key estimated from decoded audio alone.
///
/// Pitch-class energy from 110 Hz to 1.76 kHz (log-compressed, whitened across semitones) is matched against
/// Albrecht and Shanahan's major and minor key profiles. Trust a key only when `isTrusted`.
public struct SmartMixKey: Equatable, Sendable, Codable {
    public enum Mode: String, Sendable, Codable { case major, minor }

    /// Against Apple Music's keys, about two in three song openings, endings and whole songs reach this,
    /// and 91-95% of those match Apple's key exactly.
    public static let trustedConfidence = 0.1

    /// Pitch class of the tonic, 0 = C ... 11 = B.
    public let tonic: Int
    public let mode: Mode
    /// How far the best key's profile correlation leads the runner-up's, 0...2 (in practice under 0.5).
    public let confidence: Double

    public var isTrusted: Bool { confidence >= Self.trustedConfidence }

    /// Whether mixing into `other` would clash under the harmonic-mixing (Camelot) rule: compatible keys are
    /// the same key, the relative major or minor, or the same mode a fifth up or down. Confidence is not
    /// considered.
    public func clashes(with other: SmartMixKey) -> Bool {
        if mode == other.mode {
            return ![0, 5, 7].contains((other.tonic - tonic + 12) % 12)
        }
        return relativeMajorTonic != other.relativeMajorTonic
    }

    private var relativeMajorTonic: Int { mode == .major ? tonic : (tonic + 3) % 12 }
}

/// The keys of a song's opening, whole and ending, as Apple Music's analysis reports them.
public struct SmartMixKeys: Equatable, Sendable, Codable {
    /// Opening and ending keys cover this much sounding audio; it best reproduces Apple's beginning and ending keys.
    public static let edgeDuration: TimeInterval = 45

    public let opening: SmartMixKey
    public let main: SmartMixKey
    public let ending: SmartMixKey

    public static func analyze(monoSamples: [Float], sampleRate: Double) -> SmartMixKeys? {
        guard sampleRate > 0, monoSamples.count >= Int(sampleRate * 8) else { return nil }
        let factor = max(1, Int((sampleRate / SmartMixTempoEstimator.analysisRate).rounded()))
        let rate = sampleRate / Double(factor)
        var reduced = [Float](repeating: 0, count: monoSamples.count / factor)
        let averaging = [Float](repeating: 1 / Float(factor), count: factor)
        vDSP_desamp(monoSamples, vDSP_Stride(factor), averaging, &reduced, vDSP_Length(reduced.count), vDSP_Length(factor))
        return analyze(reducedSamples: reduced, rate: rate)
    }

    /// Takes the same reduced (about 11 kHz) signal as `SmartMixBeatGrid`.
    static func analyze(reducedSamples samples: [Float], rate: Double) -> SmartMixKeys? {
        guard samples.count >= fftSize else { return nil }
        let (semitones, level) = semitoneSpectrogram(samples, rate: rate)

        // Log-compress against the song's loudest semitone, then keep only what stands above its octave.
        let peak = semitones.lazy.map { $0.max() ?? 0 }.max() ?? 0
        guard peak > 0 else { return nil }
        let scale = 100 / peak
        let chroma = semitones.map { frame -> [Float] in
            let compressed = frame.map { log1pf($0 * scale) }
            var classes = [Float](repeating: 0, count: 12)
            for index in 0 ..< semitoneCount {
                let neighbours = (index - 6 ... index + 5).map { compressed[min(max($0, 0), semitoneCount - 1)] }
                classes[(lowestNote + index) % 12] += max(0, compressed[index] - neighbours.reduce(0, +) / 12)
            }
            let norm = sqrt(vDSP.sumOfSquares(classes)) + 1e-9
            return vDSP.divide(classes, norm)
        }

        // Frames far quieter than the song's typical frame are silence or fades.
        let sorted = level.sorted()
        let floor = 0.05 * sorted[sorted.count / 2]
        let sounding = level.indices.filter { level[$0] > floor }
        guard let first = sounding.first, let last = sounding.last else { return nil }
        let edgeFrames = edgeDuration * rate / Double(hop)
        func key(_ frames: [Int]) -> SmartMixKey {
            var total = [Float](repeating: 0, count: 12)
            for frame in frames { total = vDSP.add(total, chroma[frame]) }
            return match(total)
        }
        return SmartMixKeys(
            opening: key(sounding.filter { Double($0 - first) < edgeFrames }),
            main: key(sounding),
            ending: key(sounding.filter { Double(last - $0) < edgeFrames })
        )
    }

    // MARK: - Spectra

    private static let fftSize = 8192
    private static let hop = 4096
    /// A2 (110 Hz) to below A6 (1.76 kHz): four whole octaves, so every pitch class gets the same number of notes.
    private static let lowestNote = 45
    private static let semitoneCount = 48

    /// Per frame: magnitude per semitone (root of summed bin power), and overall spectral level for the silence test.
    static func semitoneSpectrogram(_ samples: [Float], rate: Double) -> (semitones: [[Float]], level: [Float]) {
        let half = fftSize / 2
        let binWidth = rate / Double(fftSize)
        let note = (0 ..< half).map { bin -> Int in
            guard bin > 0 else { return -1 }
            let index = Int((69 + 12 * log2(Double(bin) * binWidth / 440)).rounded()) - lowestNote
            return index >= 0 && index < semitoneCount ? index : -1
        }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let hann = (0 ..< fftSize).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(fftSize - 1))) }
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)

        var semitones: [[Float]] = [], level: [Float] = []
        for start in stride(from: 0, through: samples.count - fftSize, by: hop) {
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
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                }
            }
            var frame = [Float](repeating: 0, count: semitoneCount)
            for bin in 0 ..< half where note[bin] >= 0 { frame[note[bin]] += power[bin] }
            semitones.append(frame.map { $0.squareRoot() })
            level.append(vDSP.sum(power).squareRoot())
        }
        return (semitones, level)
    }

    // MARK: - Profiles

    /// Albrecht and Shanahan (2013) major and minor key profiles, tonic first.
    private static let majorProfile: [Float] = [0.238, 0.006, 0.111, 0.006, 0.137, 0.094, 0.016, 0.214, 0.009, 0.080, 0.008, 0.081]
    private static let minorProfile: [Float] = [0.220, 0.006, 0.104, 0.123, 0.019, 0.103, 0.012, 0.214, 0.062, 0.022, 0.061, 0.052]

    /// The key whose profile best correlates with the pitch-class totals, with its lead over the runner-up.
    static func match(_ classes: [Float]) -> SmartMixKey {
        let observed = standardized(classes)
        var scores: [(tonic: Int, mode: SmartMixKey.Mode, correlation: Float)] = []
        for (mode, profile) in [(SmartMixKey.Mode.major, majorProfile), (.minor, minorProfile)] {
            let template = standardized(profile)
            for tonic in 0 ..< 12 {
                let rotated = (0 ..< 12).map { template[($0 - tonic + 12) % 12] }
                scores.append((tonic, mode, vDSP.dot(rotated, observed) / 12))
            }
        }
        scores.sort { $0.correlation > $1.correlation }
        return SmartMixKey(tonic: scores[0].tonic, mode: scores[0].mode, confidence: Double(scores[0].correlation - scores[1].correlation))
    }

    private static func standardized(_ values: [Float]) -> [Float] {
        let mean = vDSP.mean(values)
        let centered = vDSP.add(-mean, values)
        let deviation = sqrt(vDSP.sumOfSquares(centered) / Float(values.count))
        return vDSP.divide(centered, deviation + 1e-12)
    }
}
