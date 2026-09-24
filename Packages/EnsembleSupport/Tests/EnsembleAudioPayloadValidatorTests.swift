import Foundation
import XCTest
@testable import EnsembleSupport

final class EnsembleAudioPayloadValidatorTests: XCTestCase {
    func testDetectsServerErrorBodies() {
        XCTAssertTrue(
            EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(
                Data(" <!doctype html><h1>404 Not Found</h1>".utf8)
            )
        )
        XCTAssertFalse(
            EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(
                Data([0x49, 0x44, 0x33, 0x04, 0x00])
            )
        )
        XCTAssertFalse(
            EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(
                Data("<h1>503 Service Unavailable</h1>".utf8)
            )
        )
        XCTAssertTrue(
            EnsembleAudioPayloadValidator.isClearlyInvalidLeadingText(
                Data("<h1>503 Service Unavailable</h1>".utf8),
                rejectingServiceUnavailable: true
            )
        )
    }
}
