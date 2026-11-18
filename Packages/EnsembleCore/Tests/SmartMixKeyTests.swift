@testable import EnsembleCore
import XCTest

final class SmartMixKeyTests: XCTestCase {
    func testKeyDetectorFindsTheKeyOfASynthesizedChordProgression() throws {
        // tonic, mode, chords (pitch classes, root first): E major I-IV-V-I; F# minor i-iv-V-i (harmonic minor).
        let cases: [(Int, SmartMixKey.Mode, [[Int]])] = [
            (4, .major, [[4, 8, 11], [9, 1, 4], [11, 3, 6], [4, 8, 11]]),
            (6, .minor, [[6, 9, 1], [11, 2, 6], [1, 5, 8], [6, 9, 1]]),
        ]
        for (tonic, mode, chords) in cases {
            let keys = try XCTUnwrap(SmartMixKeys.analyze(monoSamples: progression(chords), sampleRate: 11_025))
            for key in [keys.opening, keys.main, keys.ending] {
                XCTAssertEqual(key.tonic, tonic)
                XCTAssertEqual(key.mode, mode)
                XCTAssertTrue(key.isTrusted, "confidence \(key.confidence)")
            }
        }

        let cMajor = SmartMixKey(tonic: 0, mode: .major, confidence: 1)
        let compatible = [(0, SmartMixKey.Mode.major), (7, .major), (5, .major), (9, .minor)]
        let clashing = [(0, SmartMixKey.Mode.minor), (2, .major), (6, .major), (4, .minor)]
        for (tonic, mode) in compatible { XCTAssertFalse(cMajor.clashes(with: SmartMixKey(tonic: tonic, mode: mode, confidence: 1))) }
        for (tonic, mode) in clashing { XCTAssertTrue(cMajor.clashes(with: SmartMixKey(tonic: tonic, mode: mode, confidence: 1))) }

        XCTAssertNil(SmartMixKeys.analyze(monoSamples: [Float](repeating: 0, count: 11_025 * 20), sampleRate: 11_025))
    }

    /// Two-second chords with a bass root, each note a few decaying harmonics, repeated for 24 seconds.
    private func progression(_ chords: [[Int]], rate: Double = 11_025) -> [Float] {
        let chordLength = Int(2 * rate)
        var samples = [Float](repeating: 0, count: Int(24 * rate))
        for (position, start) in stride(from: 0, to: samples.count, by: chordLength).enumerated() {
            let chord = chords[position % chords.count]
            let frequencies = chord.map { 261.63 * pow(2, Double($0) / 12) } + [130.81 * pow(2, Double(chord[0]) / 12) / 2]
            for index in 0 ..< min(chordLength, samples.count - start) {
                let seconds = Double(index) / rate
                var sample = 0.0
                for frequency in frequencies {
                    for harmonic in 1 ... 4 { sample += 0.05 / Double(harmonic) * sin(2 * .pi * frequency * Double(harmonic) * seconds) }
                }
                samples[start + index] = Float(sample * exp(-seconds))
            }
        }
        return samples
    }
}
