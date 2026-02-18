import XCTest
@testable import EnsembleAPI

final class PlexAPIClientTests: XCTestCase {
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

    func testPlexModelsDecoding() throws {
        // Test PlexTrack decoding
        let trackJSON = """
        {
            "ratingKey": "12345",
            "key": "/library/metadata/12345",
            "title": "Test Song",
            "parentTitle": "Test Album",
            "grandparentTitle": "Test Artist",
            "duration": 180000
        }
        """

        let track = try JSONDecoder().decode(PlexTrack.self, from: trackJSON.data(using: .utf8)!)
        XCTAssertEqual(track.ratingKey, "12345")
        XCTAssertEqual(track.title, "Test Song")
        XCTAssertEqual(track.durationSeconds, 180.0)
    }

    func testPlexDeviceDecoding() throws {
        let deviceJSON = """
        {
            "name": "My Plex Server",
            "product": "Plex Media Server",
            "productVersion": "1.32.0",
            "platform": "Linux",
            "clientIdentifier": "abc123",
            "provides": "server",
            "owned": true,
            "connections": [
                {
                    "uri": "https://192.168.1.100:32400",
                    "local": true
                }
            ]
        }
        """

        let device = try JSONDecoder().decode(PlexDevice.self, from: deviceJSON.data(using: .utf8)!)
        XCTAssertEqual(device.name, "My Plex Server")
        XCTAssertTrue(device.isServer)
        XCTAssertNotNil(device.bestConnection)
    }

    func testDeletePlaylistBuildsDeleteRequest() async throws {
        let keychain = TestKeychain()
        let client = PlexAPIClient(
            connection: PlexServerConnection(
                url: "https://example.com",
                token: "token123",
                identifier: "server",
                name: "Server"
            ),
            keychain: keychain
        )

        let request = try await client.makeServerRequest(
            url: "https://example.com",
            method: "DELETE",
            path: "/playlists/abc123"
        )

        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/playlists/abc123")
        XCTAssertEqual(
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "X-Plex-Token" })?
                .value,
            "token123"
        )
    }
}
