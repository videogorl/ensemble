import XCTest
@testable import EnsembleAPI

final class PlexResourcesSpecTests: XCTestCase {
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

    func testResourcesRequestIncludesIPv6RelayAndHTTPSFlags() async throws {
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "server-token",
                identifier: "server-id",
                name: "Server"
            ),
            keychain: TestKeychain()
        )

        let request = try await client.makeResourcesRequest(token: "user-token")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryMap = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components?.host, "plex.tv")
        XCTAssertEqual(components?.path, "/api/v2/resources")
        XCTAssertEqual(queryMap["includeHttps"], "1")
        XCTAssertEqual(queryMap["includeRelay"], "1")
        XCTAssertEqual(queryMap["includeIPv6"], "1")
    }

    func testResourcesRequestIncludesExpectedPlexHeaders() async throws {
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "server-token",
                identifier: "server-id",
                name: "Server"
            ),
            keychain: TestKeychain()
        )

        let request = try await client.makeResourcesRequest(token: "user-token")

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "user-token")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Product"), "Ensemble")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Version"), "1.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Provides"), "controller")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Platform"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Device"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Device-Name"))
    }
}
