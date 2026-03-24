import XCTest
import EnsembleAPI
@testable import EnsembleCore

final class PlexAccountDiscoveryServiceTests: XCTestCase {
    private struct MockClient: PlexAccountDiscoveryClientProtocol {
        let user: PlexUser
        let resources: [PlexDevice]
        let librariesByServerID: [String: Result<[PlexLibrarySection], Error>]

        func getUserInfo(token: String) async throws -> PlexUser {
            user
        }

        func getResources(token: String) async throws -> [PlexDevice] {
            resources
        }

        func getMusicLibrarySections(
            for device: PlexDevice,
            token: String,
            allowInsecurePolicy: AllowInsecureConnectionsPolicy
        ) async throws -> [PlexLibrarySection] {
            let result = librariesByServerID[device.clientIdentifier] ?? .success([])
            return try result.get()
        }

        func getServerCapabilities(
            for device: PlexDevice,
            token: String,
            allowInsecurePolicy: AllowInsecureConnectionsPolicy
        ) async throws -> PlexServerCapabilities {
            PlexServerCapabilities()
        }
    }

    private enum MockError: LocalizedError {
        case serverUnavailable

        var errorDescription: String? {
            "Server unavailable"
        }
    }

    func testDiscoverAccountNormalizesIdentityServersAndLibraries() async throws {
        let user = try decodeUser(
            """
            {
              "id": 42,
              "uuid": "user-uuid",
              "username": "felicity",
              "title": "Felicity",
              "email": "felicity@nysics.com"
            }
            """
        )

        let resources = try decodeResources(
            """
            [
              {
                "name": "Server B",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "macOS",
                "platformVersion": "14.0",
                "device": "Mac",
                "clientIdentifier": "server-b",
                "provides": "server",
                "owned": true,
                "accessToken": "server-b-token",
                "connections": [
                  { "uri": "http://10.0.0.5:32400", "local": true, "relay": false, "protocol": "http" },
                  { "uri": "https://remote-b.plex.direct:32400", "local": false, "relay": false, "protocol": "https" }
                ]
              },
              {
                "name": "Server A",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "Linux",
                "platformVersion": "6.0",
                "device": "Linux",
                "clientIdentifier": "server-a",
                "provides": "server",
                "owned": true,
                "accessToken": "server-a-token",
                "connections": [
                  { "uri": "https://remote-a.plex.direct:32400", "local": false, "relay": false, "protocol": "https" }
                ]
              }
            ]
            """
        )

        let service = PlexAccountDiscoveryService(
            client: MockClient(
                user: user,
                resources: resources,
                librariesByServerID: [
                    "server-a": .success(
                        try decodeSections(
                            """
                            [
                              { "key": "1", "title": "Music A", "type": "artist" },
                              { "key": "2", "title": "Movies A", "type": "movie" }
                            ]
                            """
                        )
                    ),
                    "server-b": .success(
                        try decodeSections(
                            """
                            [
                              { "key": "3", "title": "Music B", "type": "music" }
                            ]
                            """
                        )
                    )
                ]
            ),
            allowInsecurePolicyProvider: { .sameNetwork }
        )

        let result = try await service.discoverAccount(authToken: "auth-token")

        XCTAssertEqual(result.identity.id, "user-uuid")
        XCTAssertEqual(result.identity.email, "felicity@nysics.com")
        XCTAssertEqual(result.identity.plexUsername, "felicity")
        XCTAssertEqual(result.identity.displayTitle, "Felicity")

        XCTAssertEqual(result.serverLibraryErrors.count, 0)
        XCTAssertEqual(result.servers.count, 2)
        XCTAssertEqual(result.servers.map(\.name), ["Server A", "Server B"])

        let serverA = try XCTUnwrap(result.servers.first(where: { $0.id == "server-a" }))
        XCTAssertEqual(serverA.libraries.map(\.title), ["Music A"])
        XCTAssertTrue(serverA.libraries.allSatisfy { $0.isEnabled == false })

        let serverB = try XCTUnwrap(result.servers.first(where: { $0.id == "server-b" }))
        XCTAssertEqual(serverB.libraries.map(\.title), ["Music B"])
    }

    func testDiscoverAccountRetainsServersWhenLibraryFetchPartiallyFails() async throws {
        let user = try decodeUser(
            """
            {
              "id": 42,
              "uuid": "user-uuid",
              "username": "felicity",
              "title": "Felicity",
              "email": "felicity@nysics.com"
            }
            """
        )
        let resources = try decodeResources(
            """
            [
              {
                "name": "Healthy Server",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "macOS",
                "platformVersion": "14.0",
                "device": "Mac",
                "clientIdentifier": "server-ok",
                "provides": "server",
                "owned": true,
                "accessToken": "server-ok-token",
                "connections": [
                  { "uri": "https://ok.plex.direct:32400", "local": false, "relay": false, "protocol": "https" }
                ]
              },
              {
                "name": "Broken Server",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "Linux",
                "platformVersion": "6.0",
                "device": "Linux",
                "clientIdentifier": "server-bad",
                "provides": "server",
                "owned": true,
                "accessToken": "server-bad-token",
                "connections": [
                  { "uri": "https://bad.plex.direct:32400", "local": false, "relay": false, "protocol": "https" }
                ]
              }
            ]
            """
        )

        let service = PlexAccountDiscoveryService(
            client: MockClient(
                user: user,
                resources: resources,
                librariesByServerID: [
                    "server-ok": .success(
                        try decodeSections(
                            """
                            [
                              { "key": "1", "title": "Music OK", "type": "artist" }
                            ]
                            """
                        )
                    ),
                    "server-bad": .failure(MockError.serverUnavailable)
                ]
            ),
            allowInsecurePolicyProvider: { .sameNetwork }
        )

        let result = try await service.discoverAccount(authToken: "auth-token")

        XCTAssertEqual(result.servers.count, 2)
        XCTAssertTrue(result.hasPartialFailures)
        XCTAssertEqual(result.serverLibraryErrors["server-bad"], "Server unavailable")

        let healthy = try XCTUnwrap(result.servers.first(where: { $0.id == "server-ok" }))
        XCTAssertEqual(healthy.libraries.map(\.title), ["Music OK"])

        let broken = try XCTUnwrap(result.servers.first(where: { $0.id == "server-bad" }))
        XCTAssertEqual(broken.libraries.count, 0)
    }

    func testDiscoverAccountPropagatesCancellationError() async throws {
        let user = try decodeUser(
            """
            {
              "id": 42,
              "uuid": "user-uuid",
              "username": "felicity",
              "title": "Felicity",
              "email": "felicity@nysics.com"
            }
            """
        )
        let resources = try decodeResources(
            """
            [
              {
                "name": "Server A",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "Linux",
                "platformVersion": "6.0",
                "device": "Linux",
                "clientIdentifier": "server-a",
                "provides": "server",
                "owned": true,
                "accessToken": "server-a-token",
                "connections": [
                  { "uri": "https://remote-a.plex.direct:32400", "local": false, "relay": false, "protocol": "https" }
                ]
              }
            ]
            """
        )

        let service = PlexAccountDiscoveryService(
            client: MockClient(
                user: user,
                resources: resources,
                librariesByServerID: [
                    "server-a": .failure(CancellationError())
                ]
            ),
            allowInsecurePolicyProvider: { .sameNetwork }
        )

        do {
            _ = try await service.discoverAccount(authToken: "auth-token")
            XCTFail("Expected cancellation error")
        } catch is CancellationError {
            // Expected
        } catch {
            XCTFail("Expected CancellationError but got \(error)")
        }
    }

    private func decodeUser(_ json: String) throws -> PlexUser {
        try JSONDecoder().decode(PlexUser.self, from: Data(json.utf8))
    }

    private func decodeResources(_ json: String) throws -> [PlexDevice] {
        try JSONDecoder().decode([PlexDevice].self, from: Data(json.utf8))
    }

    private func decodeSections(_ json: String) throws -> [PlexLibrarySection] {
        try JSONDecoder().decode([PlexLibrarySection].self, from: Data(json.utf8))
    }
}
