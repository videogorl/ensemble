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
        func upsertAlbum(ratingKey: String, key: String, title: String, artistName: String?, albumArtist: String?, artistRatingKey: String?, summary: String?, thumbPath: String?, artPath: String?, year: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, rating: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDAlbum { throw MockError.unimplemented }
        func fetchTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchSiriEligibleTracks() async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] { [] }
        func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] { [] }
        func fetchFavoriteTracks() async throws -> [CDTrack] { [] }
        func fetchTrack(ratingKey: String) async throws -> CDTrack? { nil }
        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? { nil }
        func upsertTrack(ratingKey: String, key: String, title: String, artistName: String?, albumName: String?, albumRatingKey: String?, trackNumber: Int?, discNumber: Int?, duration: Int?, thumbPath: String?, streamKey: String?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, lastRatedAt: Date?, rating: Int?, playCount: Int?, genreNames: String?, sourceCompositeKey: String?) async throws -> CDTrack { throw MockError.unimplemented }
        func fetchGenres() async throws -> [CDGenre] { [] }
        func upsertGenre(ratingKey: String?, key: String, title: String, sourceCompositeKey: String?) async throws -> CDGenre { throw MockError.unimplemented }
        func searchTracks(query: String) async throws -> [CDTrack] { [] }
        func searchArtists(query: String) async throws -> [CDArtist] { [] }
        func searchAlbums(query: String) async throws -> [CDAlbum] { [] }
        func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] { [] }
        func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] { [] }
        func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] { [] }
        func fetchMusicSources() async throws -> [CDMusicSource] { [] }
        func upsertMusicSource(compositeKey: String, type: String, accountId: String, serverId: String, libraryId: String, displayName: String?, accountName: String?) async throws -> CDMusicSource { throw MockError.unimplemented }
        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {}
        func deleteAllData(forSourceCompositeKey: String) async throws {}
        func deleteAllLibraryData() async throws {}
        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] { [:] }
        func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
        func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {}
        func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {}
        func drainTrackReparentInfo() -> [TrackReparentInfo] { [] }
    }

    private final class MockPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        func fetchPlaylists() async throws -> [CDPlaylist] { [] }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { [] }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { nil }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { nil }
        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw MockError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }
    }

    private final class MockArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        func predownloadArtwork(for albums: [CDAlbum], size: Int) async throws -> Int { 0 }
        func predownloadArtwork(for artists: [CDArtist], size: Int) async throws -> Int { 0 }
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class MockHubRepository: HubRepositoryProtocol, @unchecked Sendable {
        var cachedHubs: [Hub] = []
        var cachedSnapshot: HomeFeedCachedSnapshot?

        func fetchHubs() async throws -> [Hub] { cachedHubs }
        func saveHubs(_ hubs: [Hub]) async throws {}
        func deleteAllHubs() async throws {}
        func fetchLatestHomeFeedSnapshot(sourceScopeKey: String?) async throws -> HomeFeedCachedSnapshot? {
            cachedSnapshot
        }
        func saveHomeFeedSnapshot(_ snapshot: HomeFeedCachedSnapshot) async throws {
            cachedSnapshot = snapshot
        }
        func markHomeFeedSnapshotLastGood(id: String, freshnessState: HomeFeedSnapshotFreshnessState) async throws {
            guard let snapshot = cachedSnapshot, snapshot.id == id else { return }
            cachedSnapshot = HomeFeedCachedSnapshot(
                id: snapshot.id,
                sourceScopeKey: snapshot.sourceScopeKey,
                sourceName: snapshot.sourceName,
                createdAt: snapshot.createdAt,
                fetchedAt: snapshot.fetchedAt,
                refreshReason: snapshot.refreshReason,
                freshnessState: freshnessState,
                schemaVersion: snapshot.schemaVersion,
                isLastGood: true,
                hubs: snapshot.hubs
            )
        }
        func deleteHomeFeedSnapshots(sourceScopeKey: String?) async throws {
            cachedSnapshot = nil
        }
    }

    private final class MockHomeHubLoader: HomeHubLoaderProtocol, @unchecked Sendable {
        var cachedSnapshot: HomeHubSnapshot
        var networkSnapshot: HomeHubSnapshot?

        init(cachedHubs: [Hub] = [], networkHubs: [Hub]? = nil) {
            self.cachedSnapshot = Self.snapshot(hubs: cachedHubs)
            self.networkSnapshot = networkHubs.map(Self.snapshot(hubs:))
        }

        func loadCachedSnapshot() async throws -> HomeHubSnapshot {
            cachedSnapshot
        }

        func loadSnapshot(applySavedOrder: Bool, hubCount: String) async -> HomeHubSnapshot? {
            networkSnapshot
        }

        func clearFailedHubKeys() {}

        private static func snapshot(hubs: [Hub]) -> HomeHubSnapshot {
            HomeHubSnapshot(
                orderedHubs: hubs,
                failedHubKeys: [],
                metadata: HomeHubSnapshotMetadata(
                    currentSourceKey: "plex:account-enabled:server-enabled",
                    currentSourceName: "Editing Music",
                    fetchTaskCount: 1,
                    usedGlobalFallback: false,
                    networkFetchCompletedAt: Date()
                )
            )
        }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private struct Harness {
        let viewModel: HomeViewModel
        let accountManager: AccountManager
        let coordinator: SyncCoordinator
        let hubRepository: MockHubRepository
    }

    private func makeHarness(
        accounts: [PlexAccountConfig] = [],
        cachedHubs: [Hub] = []
    ) -> Harness {
        let accountManager = AccountManager(keychain: TestKeychain())
        for account in accounts {
            accountManager.addPlexAccount(account)
        }
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.home.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: MockPlaylistRepository(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let hubRepository = MockHubRepository()
        hubRepository.cachedHubs = cachedHubs
        let hubLoader = HomeHubLoader(
            accountManager: accountManager,
            hubRepository: hubRepository
        )
        let libraryRepository = MockLibraryRepository()
        let playlistRepository = MockPlaylistRepository()

        let viewModel = HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubLoader: hubLoader,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository
        )

        return Harness(
            viewModel: viewModel,
            accountManager: accountManager,
            coordinator: coordinator,
            hubRepository: hubRepository
        )
    }

    private func makeViewModel() -> HomeViewModel {
        let enabledAccount = PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        return makeHarness(accounts: [enabledAccount]).viewModel
    }

    private func makeViewModel(hubLoader: HomeHubLoaderProtocol) -> (HomeViewModel, SyncCoordinator) {
        let enabledAccount = PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(enabledAccount)
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.home.network.custom"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: MockPlaylistRepository(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let viewModel = HomeViewModel(
            accountManager: accountManager,
            syncCoordinator: coordinator,
            hubLoader: hubLoader,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: MockPlaylistRepository()
        )
        return (viewModel, coordinator)
    }

    private func makeHub(id: String = "hub-1") -> Hub {
        Hub(
            id: id,
            title: "Recently Played",
            type: "mixed",
            items: [
                HubItem(
                    id: "track-1",
                    type: "track",
                    title: "Track One",
                    subtitle: "Artist",
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:account-enabled:server-enabled:lib-enabled"
                )
            ]
        )
    }

    func testSyncCompleteTriggerDefersWhileInteracting() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
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
        sut.markInitialLoadCompletedForTesting()
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
        sut.markInitialLoadCompletedForTesting()
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
        sut.markInitialLoadCompletedForTesting()
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
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.handleViewVisibilityChange(isVisible: false)
        sut.requestAutoRefreshForTesting(reason: .periodicTimer)
        try? await Task.sleep(nanoseconds: 420_000_000)

        XCTAssertEqual(refreshCount, 0)
    }

    func testHiddenViewClearsDeferredAutoRefresh() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()

        sut.handleViewVisibilityChange(isVisible: true)
        sut.handleScrollInteraction(isInteracting: true)
        sut.requestAutoRefreshForTesting(reason: .syncCompleted)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)

        sut.handleViewVisibilityChange(isVisible: false)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testNoEnabledLibrariesClearsCachedFeedContent() async {
        let account = PlexAccountConfig(
            id: "account-1",
            email: "tester@example.com",
            plexUsername: "tester",
            displayTitle: "Tester",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-1",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Music", isEnabled: false)
                    ]
                )
            ]
        )
        let staleHub = Hub(
            id: "plex:account-1:server-1:hub-1",
            title: "Recently Played",
            type: "mixed",
            items: [
                HubItem(
                    id: "track-1",
                    type: "track",
                    title: "Track One",
                    subtitle: "Artist",
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:account-1:server-1:lib-1"
                )
            ]
        )
        let harness = makeHarness(accounts: [account], cachedHubs: [staleHub])
        let sut = harness.viewModel

        try? await Task.sleep(nanoseconds: 80_000_000)
        await sut.loadHubs()

        XCTAssertTrue(sut.hubs.isEmpty)
        XCTAssertTrue(sut.hasConfiguredAccounts)
        XCTAssertFalse(sut.hasEnabledLibraries)
    }

    func testUnavailableNetworkSnapshotPreservesExistingCachedFeedContent() async {
        let cachedHub = makeHub()
        let loader = MockHomeHubLoader(cachedHubs: [], networkHubs: nil)
        let (sut, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])

        await sut.loadHubs()

        XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
        XCTAssertTrue(sut.isFeedCacheStale)
    }

    func testEmptyNetworkSnapshotPreservesExistingCachedFeedContent() async {
        let cachedHub = makeHub()
        let loader = MockHomeHubLoader(cachedHubs: [], networkHubs: [])
        let (sut, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])

        await sut.loadHubs()

        XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
        XCTAssertTrue(sut.isFeedCacheStale)
    }

    func testOfflineEmptyNetworkSnapshotPreservesExistingCachedFeedContent() async {
        let cachedHub = makeHub()
        let loader = MockHomeHubLoader(cachedHubs: [], networkHubs: [])
        let (sut, coordinator) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])
        await coordinator.handleObservedNetworkStateForTesting(.offline)

        await sut.loadHubs()

        XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
        XCTAssertTrue(sut.isFeedCacheStale)
    }

    func testLocalAvailabilityFilterDropsUnresolvedItemsAndEmptyHubs() async throws {
        let available = Set([
            "album-1|plex:account-1:server-1:lib-1",
            "track-1|plex:account-1:server-1:lib-1"
        ])

        let hubs = [
            Hub(
                id: "hub-1",
                title: "Mixed",
                type: "mixed",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: "Album One",
                        subtitle: "Artist One",
                        thumbPath: nil,
                        year: 2025,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    ),
                    HubItem(
                        id: "album-2",
                        type: "album",
                        title: "Album Two",
                        subtitle: "Artist Two",
                        thumbPath: nil,
                        year: 2024,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ],
                context: "hub.music.artist"
            ),
            Hub(
                id: "hub-2",
                title: "Tracks",
                type: "mixed",
                items: [
                    HubItem(
                        id: "track-1",
                        type: "track",
                        title: "Track One",
                        subtitle: "Artist",
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ]
            ),
            Hub(
                id: "hub-3",
                title: "Playlists",
                type: "playlist",
                items: [
                    HubItem(
                        id: "playlist-1",
                        type: "playlist",
                        title: "Playlist",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: "plex:account-1:server-1:lib-1"
                    )
                ]
            )
        ]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { item in
            available.contains("\(item.id)|\(item.sourceCompositeKey)")
        }

        XCTAssertEqual(filtered.count, 2)
        XCTAssertEqual(filtered[0].items.map(\.id), ["album-1"])
        XCTAssertEqual(filtered[0].context, "hub.music.artist")
        XCTAssertEqual(filtered[1].items.map(\.id), ["track-1"])
    }

    func testLocalAvailabilityFilterUsesResolvedLocalItemMetadata() async throws {
        let sourceKey = "plex:account-1:server-1:lib-1"
        let hubs = [
            Hub(
                id: "hub-1",
                title: "Recently Added",
                type: "mixed",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: "Stale Album Title",
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: sourceKey
                    )
                ]
            )
        ]

        let filtered = await HomeViewModel.filterHubsForLocalAvailability(hubs) { item in
            guard item.id == "album-1" else { return nil }
            let album = Album(
                id: item.id,
                key: item.id,
                title: "Album One",
                artistName: "Artist One",
                year: 2026,
                thumbPath: "/library/metadata/album-1/thumb/123",
                sourceCompositeKey: sourceKey
            )
            return HubItem(
                id: item.id,
                type: item.type,
                title: album.title,
                subtitle: album.artistName,
                thumbPath: album.thumbPath,
                year: album.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: album
            )
        }

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].items[0].title, "Album One")
        XCTAssertEqual(filtered[0].items[0].subtitle, "Artist One")
        XCTAssertEqual(filtered[0].items[0].thumbPath, "/library/metadata/album-1/thumb/123")
        XCTAssertEqual(filtered[0].items[0].album?.thumbPath, "/library/metadata/album-1/thumb/123")
    }

    func testInitialLoadWaitsForStartupHealthChecksBeforeFetchingNetworkHubs() async {
        let harness = makeHarness(accounts: [PlexAccountConfig(
            id: "account-enabled",
            email: "enabled@example.com",
            plexUsername: "enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    connections: [PlexConnectionConfig(uri: "https://enabled.example.com", local: false, relay: false, protocol: "https")],
                    token: "token-enabled",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )])
        let sut = harness.viewModel
        let waitStarted = expectation(description: "wait started")
        let releaseWait = expectation(description: "release wait")
        releaseWait.assertForOverFulfill = false
        var loadCount = 0

        sut.waitForStartupHealthChecksRunnerForTesting = { [self] in
            waitStarted.fulfill()
            await self.fulfillment(of: [releaseWait], timeout: 1.0)
        }
        sut.loadHubsRunnerForTesting = { _, _ in
            loadCount += 1
        }

        let loadTask = Task {
            await sut.loadHubs()
        }

        await fulfillment(of: [waitStarted], timeout: 1.0)
        XCTAssertEqual(loadCount, 0)

        releaseWait.fulfill()
        await loadTask.value

        XCTAssertEqual(loadCount, 1)
    }

    func testSubsequentLoadsDoNotWaitForStartupHealthChecks() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()

        var waitCallCount = 0
        var loadCount = 0
        sut.waitForStartupHealthChecksRunnerForTesting = {
            waitCallCount += 1
        }
        sut.loadHubsRunnerForTesting = { _, _ in
            loadCount += 1
        }

        await sut.loadHubs()

        XCTAssertEqual(waitCallCount, 0)
        XCTAssertEqual(loadCount, 1)
    }
}
