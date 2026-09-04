import XCTest
@testable import EnsembleUI

final class AuroraRenderModelTests: XCTestCase {
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
