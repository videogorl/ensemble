import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class MusicSourceAccountDetailViewModelTests: XCTestCase {
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

    private final class MockDiscoveryService: PlexAccountDiscoveryServiceProtocol, @unchecked Sendable {
        var result: PlexAccountDiscoveryResult?
        var failure: Error?

        func discoverAccount(authToken: String) async throws -> PlexAccountDiscoveryResult {
            if let failure {
                throw failure
            }
            guard let result else {
                throw NSError(domain: "tests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing discovery result"]) }
            return result
        }
    }

    private struct Harness {
        let accountManager: AccountManager
        let syncCoordinator: SyncCoordinator
        let libraryRepository: LibraryRepository
        let playlistRepository: PlaylistRepository
        let discoveryService: MockDiscoveryService
    }

    func testToggleLibraryPurgesOnlyUncheckedLibraryCache() async throws {
        let harness = makeHarness()
        let account = makeAccount(
            accountId: "account-1",
            serverId: "server-1",
            libraries: [
                ("lib-1", "Library One", true),
                ("lib-2", "Library Two", true)
            ]
        )
        harness.accountManager.addPlexAccount(account)
        harness.syncCoordinator.refreshProviders()

        let sourceOne = "plex:account-1:server-1:lib-1"
        let sourceTwo = "plex:account-1:server-1:lib-2"
        let serverSource = "plex:account-1:server-1"

        try await seedTrack(repository: harness.libraryRepository, ratingKey: "track-1", sourceCompositeKey: sourceOne)
        try await seedTrack(repository: harness.libraryRepository, ratingKey: "track-2", sourceCompositeKey: sourceTwo)
        try await seedPlaylist(repository: harness.playlistRepository, ratingKey: "playlist-1", sourceCompositeKey: serverSource)

        let viewModel = makeViewModel(accountId: account.id, harness: harness)
        let row = try XCTUnwrap(
            viewModel.sections
                .first(where: { $0.id == "server-1" })?
                .libraries
                .first(where: { $0.sourceIdentifier.libraryId == "lib-1" })
        )

        await viewModel.toggleLibrary(row)

        let tracks = try await harness.libraryRepository.fetchTracks()
        XCTAssertFalse(tracks.contains(where: { $0.sourceCompositeKey == sourceOne }))
        XCTAssertTrue(tracks.contains(where: { $0.sourceCompositeKey == sourceTwo }))

        let serverPlaylists = try await harness.playlistRepository.fetchPlaylists(sourceCompositeKey: serverSource)
        XCTAssertEqual(serverPlaylists.count, 1)

        let updatedAccount = try XCTUnwrap(harness.accountManager.plexAccounts.first)
        let updatedServer = try XCTUnwrap(updatedAccount.servers.first(where: { $0.id == "server-1" }))
        XCTAssertEqual(updatedServer.libraries.first(where: { $0.key == "lib-1" })?.isEnabled, false)
        XCTAssertEqual(updatedServer.libraries.first(where: { $0.key == "lib-2" })?.isEnabled, true)
    }

    func testToggleLastEnabledLibraryPurgesServerPlaylists() async throws {
        let harness = makeHarness()
        let account = makeAccount(
            accountId: "account-1",
            serverId: "server-1",
            libraries: [("lib-1", "Library One", true)]
        )
        harness.accountManager.addPlexAccount(account)
        harness.syncCoordinator.refreshProviders()

        let source = "plex:account-1:server-1:lib-1"
        let serverSource = "plex:account-1:server-1"

        try await seedTrack(repository: harness.libraryRepository, ratingKey: "track-1", sourceCompositeKey: source)
        try await seedPlaylist(repository: harness.playlistRepository, ratingKey: "playlist-1", sourceCompositeKey: serverSource)

        let viewModel = makeViewModel(accountId: account.id, harness: harness)
        let row = try XCTUnwrap(viewModel.sections.first?.libraries.first)

        await viewModel.toggleLibrary(row)

        let tracks = try await harness.libraryRepository.fetchTracks()
        XCTAssertFalse(tracks.contains(where: { $0.sourceCompositeKey == source }))

        let playlists = try await harness.playlistRepository.fetchPlaylists(sourceCompositeKey: serverSource)
        XCTAssertTrue(playlists.isEmpty)
    }

    func testRefreshReconcilesNewUncheckedAndRemovedPurged() async throws {
        let harness = makeHarness()
        let account = makeAccount(
            accountId: "account-1",
            serverId: "server-1",
            libraries: [
                ("lib-1", "Library One", true),
                ("lib-2", "Library Two", true)
            ]
        )
        harness.accountManager.addPlexAccount(account)

        let removedSource = "plex:account-1:server-1:lib-2"
        try await seedTrack(repository: harness.libraryRepository, ratingKey: "track-removed", sourceCompositeKey: removedSource)

        harness.discoveryService.result = PlexAccountDiscoveryResult(
            identity: PlexAccountIdentity(
                id: "account-1",
                email: "felicity@nysics.com",
                plexUsername: "felicity",
                displayTitle: "Felicity"
            ),
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Library One Renamed", isEnabled: false),
                        PlexLibraryConfig(id: "lib-3", key: "lib-3", title: "Library Three", isEnabled: false)
                    ]
                )
            ],
            serverLibraryErrors: [:]
        )

        let viewModel = makeViewModel(accountId: account.id, harness: harness)
        await viewModel.performInitialRefreshIfNeeded()

        let updatedAccount = try XCTUnwrap(harness.accountManager.plexAccounts.first)
        let updatedServer = try XCTUnwrap(updatedAccount.servers.first(where: { $0.id == "server-1" }))
        XCTAssertEqual(updatedServer.libraries.map(\.key), ["lib-1", "lib-3"])
        XCTAssertEqual(updatedServer.libraries.first(where: { $0.key == "lib-1" })?.title, "Library One Renamed")
        XCTAssertEqual(updatedServer.libraries.first(where: { $0.key == "lib-1" })?.isEnabled, true)
        XCTAssertEqual(updatedServer.libraries.first(where: { $0.key == "lib-3" })?.isEnabled, false)

        let tracks = try await harness.libraryRepository.fetchTracks()
        XCTAssertFalse(tracks.contains(where: { $0.sourceCompositeKey == removedSource }))
    }

    func testRefreshPartialFailureKeepsExistingLibraries() async throws {
        let harness = makeHarness()
        let account = makeAccount(
            accountId: "account-1",
            serverId: "server-1",
            libraries: [("lib-1", "Library One", true)]
        )
        harness.accountManager.addPlexAccount(account)

        harness.discoveryService.result = PlexAccountDiscoveryResult(
            identity: PlexAccountIdentity(id: "account-1", email: nil, plexUsername: "tester", displayTitle: nil),
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: []
                )
            ],
            serverLibraryErrors: ["server-1": "Library fetch failed"]
        )

        let viewModel = makeViewModel(accountId: account.id, harness: harness)
        await viewModel.performInitialRefreshIfNeeded()

        let updatedAccount = try XCTUnwrap(harness.accountManager.plexAccounts.first)
        let updatedServer = try XCTUnwrap(updatedAccount.servers.first(where: { $0.id == "server-1" }))
        XCTAssertEqual(updatedServer.libraries.map(\.key), ["lib-1"])
        XCTAssertEqual(updatedServer.libraries.first?.isEnabled, true)
        XCTAssertEqual(viewModel.serverLibraryErrors["server-1"], "Library fetch failed")
    }

    func testExpiredAccountBlocksDestructiveToggle() async throws {
        let harness = makeHarness()
        let expiredAccount = PlexAccountConfig(
            id: "account-1",
            email: "felicity@nysics.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "auth-token",
            authTokenMetadata: PlexAuthTokenMetadata(
                rawToken: "auth-token",
                issuedAt: Date(timeIntervalSince1970: 1000),
                expiresAt: Date(timeIntervalSince1970: 2000)
            ),
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Library One", isEnabled: true)
                    ]
                )
            ]
        )
        harness.accountManager.addPlexAccount(expiredAccount)

        let viewModel = makeViewModel(accountId: expiredAccount.id, harness: harness)
        await viewModel.performInitialRefreshIfNeeded()
        let row = try XCTUnwrap(viewModel.sections.first?.libraries.first)

        await viewModel.toggleLibrary(row)

        let updated = try XCTUnwrap(harness.accountManager.plexAccounts.first)
        let server = try XCTUnwrap(updated.servers.first)
        XCTAssertEqual(server.libraries.first?.isEnabled, true)
        XCTAssertEqual(viewModel.error, "Session expired. Re-authenticate this account.")
    }

    private func makeHarness() -> Harness {
        let keychain = TestKeychain()
        let accountManager = AccountManager(keychain: keychain)
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: ArtworkDownloadManager(coreDataStack: stack),
            networkMonitor: NetworkMonitor(
                debounceNanoseconds: 1_000,
                monitorQueue: DispatchQueue(label: "test.network.monitor"),
                monitorFactory: { SystemNetworkPathMonitor() }
            ),
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager)
        )
        let discoveryService = MockDiscoveryService()

        return Harness(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            discoveryService: discoveryService
        )
    }

    private func makeViewModel(accountId: String, harness: Harness) -> MusicSourceAccountDetailViewModel {
        MusicSourceAccountDetailViewModel(
            accountId: accountId,
            accountManager: harness.accountManager,
            accountDiscoveryService: harness.discoveryService,
            syncCoordinator: harness.syncCoordinator
        )
    }

    private func makeAccount(
        accountId: String,
        serverId: String,
        libraries: [(key: String, title: String, enabled: Bool)]
    ) -> PlexAccountConfig {
        PlexAccountConfig(
            id: accountId,
            email: "felicity@nysics.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: serverId,
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: libraries.map { item in
                        PlexLibraryConfig(id: item.key, key: item.key, title: item.title, isEnabled: item.enabled)
                    }
                )
            ]
        )
    }

    private func seedTrack(
        repository: LibraryRepository,
        ratingKey: String,
        sourceCompositeKey: String
    ) async throws {
        _ = try await repository.upsertTrack(
            ratingKey: ratingKey,
            key: ratingKey,
            title: "Track \(ratingKey)",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 120_000,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func seedPlaylist(
        repository: PlaylistRepository,
        ratingKey: String,
        sourceCompositeKey: String
    ) async throws {
        _ = try await repository.upsertPlaylist(
            ratingKey: ratingKey,
            key: "/playlists/\(ratingKey)",
            title: "Playlist \(ratingKey)",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: 0,
            trackCount: 0,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
