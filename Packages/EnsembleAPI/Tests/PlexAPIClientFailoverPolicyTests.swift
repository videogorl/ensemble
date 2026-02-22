import XCTest
@testable import EnsembleAPI

final class PlexAPIClientFailoverPolicyTests: XCTestCase {
    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

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
