import XCTest
@testable import EnsembleAPI

final class PlexAPIClientFailoverPolicyTests: XCTestCase {

    func testTransportErrorsTriggerFailoverAttempt() {
        let shouldFailover = PlexErrorClassification.classify(
            PlexAPIError.networkError(URLError(.timedOut))
        ).shouldFailover
        XCTAssertTrue(shouldFailover)
    }

    func testRealRequestTimeoutDoesNotSeedCurrentEndpointCooldown() {
        let shouldRecord = PlexErrorClassification.shouldRecordEndpointFailure(URLError(.timedOut))
        XCTAssertFalse(shouldRecord)
    }

    func testDefinitiveTransportFailureSeedsCurrentEndpointCooldown() {
        let shouldRecord = PlexErrorClassification.shouldRecordEndpointFailure(URLError(.cannotFindHost))
        XCTAssertTrue(shouldRecord)
    }

    func testHTTPErrorsDoNotTriggerFailoverAttempt() {
        let shouldFailover = PlexErrorClassification.classify(
            PlexAPIError.httpError(statusCode: 401)
        ).shouldFailover
        XCTAssertFalse(shouldFailover)
    }

    func testDecodingErrorsDoNotTriggerFailoverAttempt() {
        let shouldFailover = PlexErrorClassification.classify(
            PlexAPIError.decodingError(
                NSError(domain: "json", code: -1, userInfo: nil)
            )
        ).shouldFailover
        XCTAssertFalse(shouldFailover)
    }
}
