import XCTest
@testable import EnsembleAPI

final class PlexAPIClientFailoverPolicyTests: XCTestCase {

    private func makeClient() -> PlexAPIClient {
        PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                alternativeURLs: ["https://alt.example.com"],
                token: "token",
                identifier: "server-id",
                name: "Server"
            ),
            keychain: TestKeychain()
        )
    }

    func testTransportErrorsTriggerFailoverAttempt() async {
        let client = makeClient()
        let shouldFailover = await client.shouldAttemptFailoverForTesting(
            after: PlexAPIError.networkError(URLError(.timedOut))
        )
        XCTAssertTrue(shouldFailover)
    }

    func testRealRequestTimeoutDoesNotSeedCurrentEndpointCooldown() async {
        let client = makeClient()
        let shouldRecord = await client.shouldRecordCurrentEndpointFailureForTesting(
            URLError(.timedOut)
        )
        XCTAssertFalse(shouldRecord)
    }

    func testDefinitiveTransportFailureSeedsCurrentEndpointCooldown() async {
        let client = makeClient()
        let shouldRecord = await client.shouldRecordCurrentEndpointFailureForTesting(
            URLError(.cannotFindHost)
        )
        XCTAssertTrue(shouldRecord)
    }

    func testHTTPErrorsDoNotTriggerFailoverAttempt() async {
        let client = makeClient()
        let shouldFailover = await client.shouldAttemptFailoverForTesting(
            after: PlexAPIError.httpError(statusCode: 401)
        )
        XCTAssertFalse(shouldFailover)
    }

    func testDecodingErrorsDoNotTriggerFailoverAttempt() async {
        let client = makeClient()
        let shouldFailover = await client.shouldAttemptFailoverForTesting(
            after: PlexAPIError.decodingError(
                NSError(domain: "json", code: -1, userInfo: nil)
            )
        )
        XCTAssertFalse(shouldFailover)
    }
}
