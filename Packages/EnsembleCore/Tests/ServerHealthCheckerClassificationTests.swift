import XCTest
@testable import EnsembleCore
@testable import EnsembleAPI

@MainActor
final class ServerHealthCheckerClassificationTests: XCTestCase {
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

    func testTLSFailuresClassifiedAsTLSPolicyBlocked() async {
        let accountManager = AccountManager(keychain: TestKeychain())
        let serverID = "server-1"
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth-token",
                servers: [
                    PlexServerConfig(
                        id: serverID,
                        name: "TLS Server",
                        url: "https://remote.example",
                        connections: [
                            PlexConnectionConfig(
                                uri: "https://remote.example",
                                local: false,
                                relay: false,
                                protocol: "https"
                            )
                        ],
                        token: "token",
                        libraries: [PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)]
                    )
                ]
            )
        )

        let failover = ConnectionFailoverManager(timeout: 0.1) { _ in
            throw URLError(.secureConnectionFailed)
        }
        let checker = ServerHealthChecker(
            accountManager: accountManager,
            failoverManager: failover,
            cacheTTL: 0,
            unavailableCacheTTL: 0,
            resourceRefreshCooldown: 60,
            nowProvider: { Date() }
        )

        let state = await checker.checkServer(accountId: "account-1", serverId: serverID, forceRefresh: true)
        let reason = checker.getServerFailureReason(accountId: "account-1", serverId: serverID)

        XCTAssertEqual(state, ServerConnectionState.offline)
        XCTAssertEqual(reason, ServerConnectionFailureReason.tlsPolicyBlocked)
    }

    func testLocalOnlyEndpointsClassifiedAsLocalOnlyReachable() async {
        let accountManager = AccountManager(keychain: TestKeychain())
        let serverID = "server-1"
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth-token",
                servers: [
                    PlexServerConfig(
                        id: serverID,
                        name: "Local Server",
                        url: "http://192.168.0.10:32400",
                        connections: [
                            PlexConnectionConfig(
                                uri: "http://192.168.0.10:32400",
                                local: true,
                                relay: false,
                                protocol: "http"
                            )
                        ],
                        token: "token",
                        libraries: [PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)]
                    )
                ]
            )
        )

        let failover = ConnectionFailoverManager(timeout: 0.1) { _ in
            throw URLError(.timedOut)
        }
        let checker = ServerHealthChecker(
            accountManager: accountManager,
            failoverManager: failover,
            cacheTTL: 0,
            unavailableCacheTTL: 0,
            resourceRefreshCooldown: 60,
            nowProvider: { Date() }
        )

        let state = await checker.checkServer(accountId: "account-1", serverId: serverID, forceRefresh: true)
        let reason = checker.getServerFailureReason(accountId: "account-1", serverId: serverID)

        XCTAssertEqual(state, ServerConnectionState.offline)
        XCTAssertEqual(reason, ServerConnectionFailureReason.localOnlyReachable)
    }
}
