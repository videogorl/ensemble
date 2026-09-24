import XCTest
@testable import EnsembleCore
import EnsembleAPI

@MainActor
final class ServerConnectionControllerTests: XCTestCase {

    private func makeAccountManager() -> AccountManager {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-1",
                displayTitle: "tester",
                authToken: "auth",
                servers: [
                    PlexServerConfig(
                        id: "server-1",
                        name: "Server",
                        url: "https://initial.example.com",
                        connections: [
                            PlexConnectionConfig(
                                uri: "https://initial.example.com",
                                local: false,
                                relay: false,
                                protocol: "https"
                            )
                        ],
                        token: "token",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)
                        ]
                    )
                ]
            )
        )
        return accountManager
    }

    private func makeNetworkMonitor() -> NetworkMonitor {
        NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
    }

    func testRefreshAPIClientConnectionsPrefersRegistryEndpoint() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let registry = ServerConnectionRegistry()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor,
            connectionRegistry: registry
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: registry
        )

        let apiClient = try XCTUnwrap(accountManager.makeAPIClient(accountId: "account-1", serverId: "server-1"))
        await registry.updateEndpoint(
            for: "account-1:server-1",
            endpoint: PlexEndpointDescriptor(url: "https://registry.example.com", local: false, relay: false),
            source: .healthCheck
        )

        var refreshCount = 0
        controller.onConnectionsRefreshed = {
            refreshCount += 1
        }

        await controller.refreshAPIClientConnections()

        let currentURL = await apiClient.getCurrentServerURL()
        XCTAssertEqual(currentURL, "https://registry.example.com")
        XCTAssertEqual(refreshCount, 1)
    }

    func testRegistryUpdateProcessingUpdatesAPIClientAndNotifiesListeners() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let registry = ServerConnectionRegistry()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor,
            connectionRegistry: registry
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: registry
        )
        let apiClient = try XCTUnwrap(accountManager.makeAPIClient(accountId: "account-1", serverId: "server-1"))

        var refreshCount = 0
        controller.onConnectionsRefreshed = {
            refreshCount += 1
        }

        await controller.processRegistryUpdateForTesting(
            ServerEndpointState(
                serverKey: "account-1:server-1",
                endpoint: PlexEndpointDescriptor(url: "https://switched.example.com", local: true, relay: false),
                source: .requestFailover
            )
        )

        let currentURL = await apiClient.getCurrentServerURL()
        XCTAssertEqual(currentURL, "https://switched.example.com")
        XCTAssertEqual(refreshCount, 1)
    }

    func testRefreshAPIClientConnectionsSkipsNotificationWhenEndpointUnchanged() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let registry = ServerConnectionRegistry()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor,
            connectionRegistry: registry
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: registry
        )

        await registry.updateEndpoint(
            for: "account-1:server-1",
            endpoint: PlexEndpointDescriptor(url: "https://initial.example.com", local: false, relay: false),
            source: .healthCheck
        )

        var refreshCount = 0
        controller.onConnectionsRefreshed = {
            refreshCount += 1
        }

        await controller.refreshAPIClientConnections()

        XCTAssertEqual(refreshCount, 0)
    }

    func testEnsureServerConnectionRejectsInvalidSourceKey() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )

        do {
            try await controller.ensureServerConnection(sourceKey: "invalid")
            XCTFail("Expected invalid source key to throw")
        } catch PlexAPIError.noServerSelected {
        } catch {
            XCTFail("Expected noServerSelected, got \(error)")
        }
    }

    func testServerFailureMessageReturnsNilForInvalidSourceKey() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )

        XCTAssertNil(controller.serverFailureMessage(sourceKey: "invalid"))
    }

    func testAPIClientLookupAcceptsServerAndLibrarySourceKeys() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )

        let serverScopedClient = try XCTUnwrap(controller.apiClient(sourceKey: "plex:account-1:server-1"))
        let libraryScopedClient = try XCTUnwrap(controller.apiClient(sourceKey: "plex:account-1:server-1:1"))

        XCTAssertTrue(serverScopedClient === libraryScopedClient)
    }

    func testRequireAPIClientRejectsInvalidOrUnknownSourceKey() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )

        XCTAssertThrowsError(try controller.requireAPIClient(sourceKey: "invalid")) { error in
            guard case PlexAPIError.noServerSelected = error else {
                return XCTFail("Expected noServerSelected, got \(error)")
            }
        }

        XCTAssertThrowsError(try controller.requireAPIClient(sourceKey: "plex:missing:server-1:1")) { error in
            guard case PlexAPIError.noServerSelected = error else {
                return XCTFail("Expected noServerSelected, got \(error)")
            }
        }
    }

    func testRefreshConnectionsThrowsWhenNoConfiguredClients() async throws {
        let accountManager = AccountManager(keychain: TestKeychain())
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )

        do {
            try await controller.refreshConnections()
            XCTFail("Expected refresh without configured clients to throw")
        } catch PlexAPIError.noServerSelected {
        } catch {
            XCTFail("Expected noServerSelected, got \(error)")
        }
    }

    func testConnectionStateAfterSuccessfulSyncUsesAPIClientURLAndPreservesDegradedState() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )
        let apiClient = try XCTUnwrap(accountManager.makeAPIClient(accountId: "account-1", serverId: "server-1"))
        await apiClient.updateCurrentServerURL("https://active.example.com")
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")

        let state = await controller.connectionStateAfterSuccessfulSync(
            for: source,
            fallback: .degraded(url: "https://old.example.com")
        )

        XCTAssertEqual(state, .degraded(url: "https://active.example.com"))
    }

    func testConnectionStateAfterSuccessfulSyncFallsBackToConfiguredServerURL() async throws {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )
        let apiClient = try XCTUnwrap(accountManager.makeAPIClient(accountId: "account-1", serverId: "server-1"))
        await apiClient.updateCurrentServerURL("   ")
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "1")

        let state = await controller.connectionStateAfterSuccessfulSync(
            for: source,
            fallback: .unknown
        )

        XCTAssertEqual(state, .connected(url: "https://initial.example.com"))
    }

    func testAppleMusicSuccessfulSyncSkipsPlexConnectionResolution() async {
        let accountManager = makeAccountManager()
        let networkMonitor = makeNetworkMonitor()
        let healthChecker = ServerHealthChecker(
            accountManager: accountManager,
            networkMonitor: networkMonitor
        )
        let controller = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: healthChecker,
            connectionRegistry: nil
        )
        var messages: [String] = []
        EnsembleCore.EnsembleLogger.fileLogHandler = { _, _, message in
            messages.append(message)
        }
        defer { EnsembleCore.EnsembleLogger.fileLogHandler = nil }

        let state = await controller.connectionStateAfterSuccessfulSync(
            for: .appleMusic,
            fallback: .connected(url: "music://local")
        )

        XCTAssertEqual(state, .connected(url: "music://local"))
        XCTAssertFalse(messages.contains { $0.contains("makeAPIClient") })
    }
}
