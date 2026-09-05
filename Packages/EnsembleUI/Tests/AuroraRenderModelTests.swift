import XCTest
@testable import EnsembleUI

final class AuroraRenderModelTests: XCTestCase {
    func testDisplaySamplingTrimsSparseLowsAndMirrorsActiveRangeWithWidth() {
        let model = AuroraRenderModel()
        model.advance(targetBands: (0..<24).map { Double($0) / 23 }, at: 0)
        let source = model.renderedBands
        for (width, upperIndex) in [(390.0, 17.0), (665.0, 20.0), (900.0, 23.0), (1200.0, 23.0)] {
            for count in [24, 48] {
                let samples = model.displayBands(width: width, count: count)
                XCTAssertEqual(samples.count, count)
                XCTAssertEqual(samples.first!, source[Int(upperIndex)])
                XCTAssertEqual(samples.last!, source[Int(upperIndex)])
                XCTAssertEqual(samples[count / 2 - 1], source[7])
                XCTAssertEqual(samples[count / 2], source[7])
                for index in 0..<(count / 2) {
                    XCTAssertEqual(samples[index], samples[count - 1 - index], accuracy: 0.000001)
                    if index > 0 { XCTAssertLessThanOrEqual(samples[index], samples[index - 1]) }
                }
            }
        }
    }

    func testAttackAndReleasePreserveDynamicsAcrossUpdateRates() {
        for rate in [15, 30, 60] {
            let model = AuroraRenderModel()
            let quiet = Array(repeating: 0.1, count: 24)
            model.advance(targetBands: quiet, at: 0)
            let initial = model.renderedBands[12]
            for tick in 1...rate {
                model.advance(targetBands: Array(repeating: 0.8, count: 24), at: Double(tick) / Double(rate))
            }
            let peak = model.renderedBands[12]
            XCTAssertEqual(peak, 0.8 + (initial - 0.8) * exp(-1 / 0.10), accuracy: 0.000001)
            for tick in 1...rate {
                model.advance(targetBands: quiet, at: 1 + Double(tick) / Double(rate))
            }
            XCTAssertEqual(model.renderedBands[12], 0.1 + (peak - 0.1) * exp(-1 / 0.32), accuracy: 0.000001)
        }
    }
}
