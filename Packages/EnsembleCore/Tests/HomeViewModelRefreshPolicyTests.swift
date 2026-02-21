import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class HomeViewModelRefreshPolicyTests: XCTestCase {
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

    private final class MockHubRepository: HubRepositoryProtocol, @unchecked Sendable {
        func fetchHubs() async throws -> [Hub] { [] }
        func saveHubs(_ hubs: [Hub]) async throws {}
        func deleteAllHubs() async throws {}
    }

    private enum MockError: Error {
        case unimplemented
    }

    private func makeViewModel() -> HomeViewModel {
        let accountManager = AccountManager(keychain: TestKeychain())
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.home.network"),
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

        return HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubRepository: MockHubRepository()
        )
    }

    func testSyncCompleteTriggerDefersWhileInteracting() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleScrollInteraction(isInteracting: true)
        sut.handleViewVisibilityChange(isVisible: true)
        sut.requestAutoRefreshForTesting(reason: .syncCompleted)

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)
    }

    func testMultipleDeferredTriggersCoalesceToSingleRefresh() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleScrollInteraction(isInteracting: true)
        sut.handleViewVisibilityChange(isVisible: true)
        sut.requestAutoRefreshForTesting(reason: .syncCompleted)
        sut.requestAutoRefreshForTesting(reason: .accountChange)

        sut.handleScrollInteraction(isInteracting: false)
        try? await Task.sleep(nanoseconds: 420_000_000)

        XCTAssertEqual(refreshCount, 1)
    }

    func testDeferredRefreshRunsAfterIdleTransition() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleScrollInteraction(isInteracting: true)
        sut.handleViewVisibilityChange(isVisible: true)
        sut.requestAutoRefreshForTesting(reason: .syncCompleted)

        sut.handleScrollInteraction(isInteracting: false)
        try? await Task.sleep(nanoseconds: 420_000_000)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testManualRefreshBypassesInteractionDeferral() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.clearPendingAutoRefreshForTesting()
        var loadCount = 0
        var deferFlags: [Bool] = []
        sut.loadHubsRunnerForTesting = { _, deferUI in
            loadCount += 1
            deferFlags.append(deferUI)
        }

        sut.handleViewVisibilityChange(isVisible: true)
        sut.handleScrollInteraction(isInteracting: true)

        await sut.refresh()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(deferFlags, [false])
    }

    func testPeriodicRefreshDoesNotRunWhenViewHidden() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleViewVisibilityChange(isVisible: false)
        sut.requestAutoRefreshForTesting(reason: .periodicTimer)
        try? await Task.sleep(nanoseconds: 420_000_000)

        XCTAssertEqual(refreshCount, 0)
    }
}
