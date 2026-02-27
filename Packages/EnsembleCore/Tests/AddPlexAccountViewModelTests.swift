import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class AddPlexAccountViewModelTests: XCTestCase {
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

    private struct MockDiscoveryService: PlexAccountDiscoveryServiceProtocol {
        func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult {
            fatalError("Not used in these tests")
        }
    }

    private func makeViewModel(accountManager: AccountManager) -> AddPlexAccountViewModel {
        let stack = CoreDataStack.inMemory()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: LibraryRepository(coreDataStack: stack),
            playlistRepository: PlaylistRepository(coreDataStack: stack),
            artworkDownloadManager: ArtworkDownloadManager(coreDataStack: stack),
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        let viewModel = AddPlexAccountViewModel(
            authService: PlexAuthService(keychain: TestKeychain()),
            accountDiscoveryService: MockDiscoveryService(),
            accountManager: accountManager,
            syncCoordinator: syncCoordinator
        )
        viewModel.refreshProvidersHandlerForTesting = {}
        viewModel.syncAllHandlerForTesting = {}
        return viewModel
    }

    func testApplyDiscoveryDefaultsToAllLibrariesSelected() {
        let accountManager = AccountManager(keychain: TestKeychain())
        let viewModel = makeViewModel(accountManager: accountManager)

        let identity = PlexAccountIdentity(
            id: "user-1",
            email: "felicity@nysics.com",
            plexUsername: "felicity",
            displayTitle: "Felicity"
        )
        let servers = [
            makeServer(id: "server-1", name: "Server 1", libraries: [("1", "Library One"), ("2", "Library Two")]),
            makeServer(id: "server-2", name: "Server 2", libraries: [("10", "Library Ten")])
        ]

        viewModel.applyDiscoveryForTesting(authToken: "auth-token", identity: identity, servers: servers)

        XCTAssertEqual(viewModel.selectedLibraryCompositeKeys.count, 3)
        XCTAssertTrue(viewModel.selectedLibraryCompositeKeys.contains("server-1:1"))
        XCTAssertTrue(viewModel.selectedLibraryCompositeKeys.contains("server-1:2"))
        XCTAssertTrue(viewModel.selectedLibraryCompositeKeys.contains("server-2:10"))
    }

    func testConfirmLibrariesRejectsEmptySelection() {
        let accountManager = AccountManager(keychain: TestKeychain())
        let viewModel = makeViewModel(accountManager: accountManager)

        viewModel.applyDiscoveryForTesting(
            authToken: "auth-token",
            identity: PlexAccountIdentity(id: "user-1", email: nil, plexUsername: "felicity", displayTitle: "Felicity"),
            servers: [makeServer(id: "server-1", name: "Server 1", libraries: [("1", "Library One")])]
        )
        viewModel.selectedLibraryCompositeKeys = []

        viewModel.confirmLibraries()

        XCTAssertEqual(viewModel.error, "Please select at least one library")
        XCTAssertTrue(accountManager.plexAccounts.isEmpty)
    }

    func testConfirmLibrariesPersistsAllServersWithEnabledSelection() {
        let accountManager = AccountManager(keychain: TestKeychain())
        let viewModel = makeViewModel(accountManager: accountManager)

        let identity = PlexAccountIdentity(
            id: "user-1",
            email: "felicity@nysics.com",
            plexUsername: "felicity",
            displayTitle: "Felicity"
        )
        let servers = [
            makeServer(id: "server-1", name: "Server 1", libraries: [("1", "Library One"), ("2", "Library Two")]),
            makeServer(id: "server-2", name: "Server 2", libraries: [("10", "Library Ten")])
        ]
        viewModel.applyDiscoveryForTesting(authToken: "auth-token", identity: identity, servers: servers)

        viewModel.selectedLibraryCompositeKeys = ["server-1:2", "server-2:10"]
        viewModel.confirmLibraries()

        XCTAssertEqual(viewModel.state, .complete)
        XCTAssertEqual(accountManager.plexAccounts.count, 1)

        guard let account = accountManager.plexAccounts.first else {
            XCTFail("Expected account to be persisted")
            return
        }
        XCTAssertEqual(account.id, "user-1")
        XCTAssertEqual(account.email, "felicity@nysics.com")
        XCTAssertEqual(account.plexUsername, "felicity")
        XCTAssertEqual(account.displayTitle, "Felicity")
        XCTAssertEqual(account.servers.count, 2)

        let server1 = account.servers.first(where: { $0.id == "server-1" })
        XCTAssertEqual(server1?.libraries.first(where: { $0.key == "1" })?.isEnabled, false)
        XCTAssertEqual(server1?.libraries.first(where: { $0.key == "2" })?.isEnabled, true)

        let server2 = account.servers.first(where: { $0.id == "server-2" })
        XCTAssertEqual(server2?.libraries.first(where: { $0.key == "10" })?.isEnabled, true)
    }

    private func makeServer(
        id: String,
        name: String,
        libraries: [(String, String)]
    ) -> PlexServerConfig {
        PlexServerConfig(
            id: id,
            name: name,
            url: "https://\(id).example.com",
            connections: [
                PlexConnectionConfig(
                    uri: "https://\(id).example.com",
                    local: false,
                    relay: false,
                    protocol: "https"
                )
            ],
            token: "\(id)-token",
            platform: "macOS",
            libraries: libraries.map { key, title in
                PlexLibraryConfig(id: key, key: key, title: title, isEnabled: false)
            }
        )
    }
}
