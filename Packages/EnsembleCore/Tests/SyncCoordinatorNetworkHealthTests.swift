import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorNetworkHealthTests: XCTestCase {
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

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func upsertArtist(ratingKey: String, key: String, name: String, summary: String?, thumbPath: String?, artPath: String?, dateAdded: Date?, dateModified: Date?, sourceCompositeKey: String?) async throws -> CDArtist { throw MockError.unimplemented }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
        func upsertAlbum(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, sourceCompositeKey: String?) async throws -> CDAlbum { throw MockError.unimplemented }
        func fetchTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchFavoriteTracks() async throws -> [CDTrack] { [] }
        func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, rating: Int?, playCount: Int?, sourceCompositeKey: String?) async throws -> CDTrack { throw MockError.unimplemented }
        func fetchGenres() async throws -> [CDGenre] { [] }
        func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { throw MockError.unimplemented }
        func searchTracks(query: String) async throws -> [CDTrack] { [] }
        func searchArtists(query: String) async throws -> [CDArtist] { [] }
        func searchAlbums(query: String) async throws -> [CDAlbum] { [] }
        func fetchMusicSources() async throws -> [CDMusicSource] { [] }
        func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { throw MockError.unimplemented }
        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
        func deleteAllData(forSourceCompositeKey: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    }

    private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw MockError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
    }

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int { 0 }
        func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int { 0 }
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private func makeCoordinator() -> (SyncCoordinator, NetworkMonitor) {
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
                        url: "https://example.com",
                        token: "token",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)
                        ]
                    )
                ]
            )
        )

        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.network.monitor"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: MockPlaylistRepository(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        return (coordinator, networkMonitor)
    }

    func testReconnectAndInterfaceSwitchTriggerHealthRefresh() async {
        let (coordinator, _) = makeCoordinator()
        var now = Date(timeIntervalSince1970: 10_000)
        coordinator.nowProviderForTesting = { now }

        var invocations: [(force: Bool, keys: Set<String>)] = []
        coordinator.healthCheckRunnerForTesting = { force, keys in
            invocations.append((force, keys))
            return ServerHealthChecker.CheckSummary(checkedCount: keys.count, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        await coordinator.handleObservedNetworkStateForTesting(.offline)
        await coordinator.awaitHealthRefreshForTesting()

        now = now.addingTimeInterval(31)
        await coordinator.handleObservedNetworkStateForTesting(.online(.wifi))
        await coordinator.awaitHealthRefreshForTesting()

        now = now.addingTimeInterval(31)
        await coordinator.handleObservedNetworkStateForTesting(.online(.cellular))
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(invocations.count, 2)
        XCTAssertTrue(invocations.allSatisfy { $0.force })
        XCTAssertEqual(invocations.first?.keys, Set(["account-1:server-1"]))
    }

    func testSameInterfaceOnlineTransitionDoesNotTriggerHealthRefresh() async {
        let (coordinator, _) = makeCoordinator()
        var now = Date(timeIntervalSince1970: 20_000)
        coordinator.nowProviderForTesting = { now }

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        await coordinator.handleObservedNetworkStateForTesting(.online(.wifi))
        await coordinator.awaitHealthRefreshForTesting()

        healthRefreshCount = 0
        now = now.addingTimeInterval(31)

        await coordinator.handleObservedNetworkStateForTesting(.online(.wifi))
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 0)
    }

    func testCooldownSuppressesRedundantHealthRefresh() async {
        let (coordinator, _) = makeCoordinator()
        var now = Date(timeIntervalSince1970: 30_000)
        coordinator.nowProviderForTesting = { now }

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        await coordinator.handleObservedNetworkStateForTesting(.offline)
        await coordinator.awaitHealthRefreshForTesting()

        now = now.addingTimeInterval(31)
        await coordinator.handleObservedNetworkStateForTesting(.online(.wifi))
        await coordinator.awaitHealthRefreshForTesting()

        now = now.addingTimeInterval(5)
        await coordinator.handleObservedNetworkStateForTesting(.offline)
        await coordinator.awaitHealthRefreshForTesting()
        await coordinator.handleObservedNetworkStateForTesting(.online(.cellular))
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 1)
    }

    func testForegroundRefreshHonorsStalenessThreshold() async {
        let (coordinator, networkMonitor) = makeCoordinator()
        let now = Date(timeIntervalSince1970: 40_000)
        coordinator.nowProviderForTesting = { now }
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        coordinator.setLastHealthRefreshForTesting(now.addingTimeInterval(-30))
        await coordinator.handleAppWillEnterForeground()
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 0)

        coordinator.setLastHealthRefreshForTesting(now.addingTimeInterval(-61))
        await coordinator.handleAppWillEnterForeground()
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 1)
    }

    func testOfflineTransitionUpdatesStateWithoutHealthRefresh() async {
        let (coordinator, _) = makeCoordinator()

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }

        await coordinator.handleObservedNetworkStateForTesting(.offline)
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertTrue(coordinator.isOffline)
        XCTAssertEqual(healthRefreshCount, 0)
    }

    func testConcurrentTransitionEventsCoalesceToSingleHealthRefreshTask() async {
        let (coordinator, _) = makeCoordinator()
        var now = Date(timeIntervalSince1970: 50_000)
        coordinator.nowProviderForTesting = { now }

        var startedCount = 0
        coordinator.healthCheckRunnerForTesting = { _, keys in
            startedCount += 1
            try? await Task.sleep(nanoseconds: 80_000_000)
            return ServerHealthChecker.CheckSummary(checkedCount: keys.count, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        await coordinator.handleObservedNetworkStateForTesting(.offline)
        now = now.addingTimeInterval(31)
        await coordinator.handleObservedNetworkStateForTesting(.online(.wifi))
        await coordinator.handleObservedNetworkStateForTesting(.online(.cellular))
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(startedCount, 1)
    }
}

@MainActor
final class ServerHealthCheckerCachePolicyTests: XCTestCase {
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
    
    private func makeChecker() -> ServerHealthChecker {
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
                        url: "https://example.com",
                        token: "token",
                        libraries: [
                            PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)
                        ]
                    )
                ]
            )
        )

        return ServerHealthChecker(
            accountManager: accountManager
        )
    }

    func testUnavailableTTLIsShorterThanAvailableTTL() {
        let checker = makeChecker()
        let availableTTL = checker.cacheTTL(for: .connected(url: "https://example.com"))
        let unavailableTTL = checker.cacheTTL(for: .offline)
        XCTAssertGreaterThan(availableTTL, unavailableTTL)
    }
}
