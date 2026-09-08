import EnsembleAPI
@testable import EnsembleCore
import XCTest

final class MutationReplayClassificationTests: XCTestCase {
    @MainActor
    func testTemporaryReplayFailuresNeverConsumePermanentFailureBudget() {
        for error: Error in [URLError(.networkConnectionLost), URLError(.cancelled),
                             PlexAPIError.networkError(URLError(.notConnectedToInternet)),
                             PlexAPIError.httpError(statusCode: 503), PlexAPIError.httpError(statusCode: 429)] {
            XCTAssertEqual(MutationCoordinator.ReplayResult.failure(error), .deferred)
        }
        XCTAssertEqual(MutationCoordinator.ReplayResult.failure(PlexAPIError.httpError(statusCode: 400)), .rejected)
    }
}
