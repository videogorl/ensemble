import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class ServerHealthCheckerClassificationTests: XCTestCase {
    func testFailedConnectionsPreserveUsefulAvailabilityReasons() async {
        let defaults = UserDefaults.standard
        let savedState = defaults.object(forKey: "lastKnownNetworkState")
        let savedConstrained = defaults.object(forKey: "lastKnownNetworkWasConstrained")
        defer {
            if let savedState { defaults.set(savedState, forKey: "lastKnownNetworkState") }
            else { defaults.removeObject(forKey: "lastKnownNetworkState") }
            if let savedConstrained { defaults.set(savedConstrained, forKey: "lastKnownNetworkWasConstrained") }
            else { defaults.removeObject(forKey: "lastKnownNetworkWasConstrained") }
        }
        let cases: [(name: String, local: Bool, relay: Bool, error: URLError.Code, reason: ServerConnectionFailureReason)] = [
            ("tls", false, false, .secureConnectionFailed, .tlsPolicyBlocked),
            ("local-only", true, false, .timedOut, .localOnlyReachable),
            ("relay-only", false, true, .timedOut, .relayUnavailable),
            ("remote", false, false, .timedOut, .remoteAccessUnavailable)
        ]
        for testCase in cases {
            let fixture = AccountConnectionFixture { request in
                if request.url?.host == "plex.tv" { return [] as [[String: Any]] }
                throw URLError(testCase.error)
            }
            defer { fixture.close() }
            let monitor = NetworkMonitor()
            monitor.injectNetworkStateForTesting(.online(.cellular), debounced: false)
            let accountManager = AccountManager(keychain: TestKeychain(), networkMonitor: monitor, urlSession: fixture.session)
            let url = "https://\(testCase.name).invalid"
            accountManager.addPlexAccount(PlexAccountConfig(
                id: "account",
                displayTitle: "Account",
                authToken: "auth-token",
                servers: [PlexServerConfig(
                    id: "server",
                    name: testCase.name,
                    url: url,
                    connections: [PlexConnectionConfig(uri: url, local: testCase.local, relay: testCase.relay, protocol: "https")],
                    token: "server-token",
                    libraries: [PlexLibraryConfig(id: "library", key: "1", title: "Music", isEnabled: true)]
                )]
            ))
            let checker = ServerHealthChecker(accountManager: accountManager, cacheTTL: 0, unavailableCacheTTL: 0)

            let state = await checker.checkServer(accountId: "account", serverId: "server", forceRefresh: true)
            XCTAssertEqual(state, .offline, testCase.name)
            XCTAssertEqual(checker.getServerFailureReason(accountId: "account", serverId: "server"), testCase.reason, testCase.name)
            let probes = fixture.requests.filter { $0.url?.path == "/identity" }
            if testCase.local {
                XCTAssertTrue(probes.isEmpty, "Remote routing must not probe local-only endpoints")
            } else {
                XCTAssertFalse(probes.isEmpty, "Failure classification must come from an attempted connection")
            }
        }
    }
}
