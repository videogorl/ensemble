import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class HomeViewModelRefreshPolicyTests: XCTestCase {

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        func refreshContext() async {}
        func fetchArtists() async throws -> [CDArtist] { [] }
        func fetchArtist(ratingKey: String) async throws -> CDArtist? { nil }
        func fetchAlbums() async throws -> [CDAlbum] { [] }
        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? { nil }
        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] { [] }
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
        var snapshotFetchCount = 0
        var requestedNonNilSnapshotScopes: [String] = []

        func fetchHubs() async throws -> [Hub] { cachedHubs }
        func saveHubs(_ hubs: [Hub]) async throws {}
        func deleteAllHubs() async throws {}
        func fetchLatestHomeFeedSnapshot(sourceScopeKey: String?) async throws -> HomeFeedCachedSnapshot? {
            snapshotFetchCount += 1
            if let sourceScopeKey {
                requestedNonNilSnapshotScopes.append(sourceScopeKey)
            }
            return cachedSnapshot
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
        var loadSnapshotHandler: ((Bool, String) async -> HomeHubSnapshot?)?

        init(
            cachedHubs: [Hub] = [],
            networkHubs: [Hub]? = nil,
            cachedFetchedAt: Date? = nil,
            cachedFreshnessState: HomeFeedSnapshotFreshnessState? = nil
        ) {
            self.cachedSnapshot = Self.snapshot(
                hubs: cachedHubs,
                networkFetchCompletedAt: nil,
                cacheFetchedAt: cachedFetchedAt,
                freshnessState: cachedFreshnessState
            )
            self.networkSnapshot = networkHubs.map {
                Self.snapshot(hubs: $0, networkFetchCompletedAt: Date())
            }
        }

        func loadCachedSnapshot() async throws -> HomeHubSnapshot {
            return cachedSnapshot
        }

        func loadSnapshot(applySavedOrder: Bool, hubCount: String) async -> HomeHubSnapshot? {
            if let loadSnapshotHandler {
                return await loadSnapshotHandler(applySavedOrder, hubCount)
            }

            return networkSnapshot
        }

        func clearFailedHubKeys() {}

        private static func snapshot(
            hubs: [Hub],
            networkFetchCompletedAt: Date?,
            cacheFetchedAt: Date? = nil,
            freshnessState: HomeFeedSnapshotFreshnessState? = nil
        ) -> HomeHubSnapshot {
            HomeHubSnapshot(
                orderedHubs: hubs,
                failedHubKeys: [],
                metadata: HomeHubSnapshotMetadata(
                    currentSourceKey: "plex:account-enabled:server-enabled",
                    currentSourceName: "Editing Music",
                    fetchTaskCount: 1,
                    usedGlobalFallback: false,
                    networkFetchCompletedAt: networkFetchCompletedAt,
                    cacheFetchedAt: cacheFetchedAt,
                    freshnessState: freshnessState
                )
            )
        }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private struct MockSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        var libraryResult: Result<LibrarySyncResult, Error> = .success(LibrarySyncResult())
        var playlistResult: Result<PlaylistSyncResult, Error> = .success(PlaylistSyncResult())

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1.0)
            return try libraryResult.get()
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1.0)
            return try libraryResult.get()
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return try playlistResult.get()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return try playlistResult.get()
        }

        func getStreamURL(
            for trackRatingKey: String,
            trackStreamKey: String?,
            quality: StreamingQuality,
            metadataDurationSeconds: Double?
        ) async throws -> StreamResolution {
            throw MockError.unimplemented
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    private struct Harness {
        let viewModel: HomeViewModel
        let accountManager: AccountManager
        let coordinator: SyncCoordinator
        let hubRepository: MockHubRepository
        let hubLoader: HomeHubLoader
    }

    private func makeHarness(
        accounts: [PlexAccountConfig] = [],
        cachedHubs: [Hub] = [],
        credentialReadUnavailable: Bool = false
    ) -> Harness {
        let keychain = TestKeychain()
        if credentialReadUnavailable {
            keychain.localReadFailure = .unavailable
        }
        let accountManager = AccountManager(keychain: keychain)
        accountManager.loadAccounts()
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
            hubRepository: hubRepository,
            hubLoader: hubLoader
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

    func testFeedRestoresCombinedSnapshotWithoutFirstServerScope() async {
        let account = PlexAccountConfig(
            id: "account-enabled",
            displayTitle: "Enabled",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-enabled",
                    name: "Enabled Server",
                    url: "https://enabled.example.com",
                    token: "token-enabled",
                    libraries: [
                        PlexLibraryConfig(id: "lib-enabled", key: "lib-enabled", title: "Music", isEnabled: true)
                    ]
                )
            ]
        )
        let harness = makeHarness(accounts: [account], cachedHubs: [makeHub()])

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertGreaterThan(harness.hubRepository.snapshotFetchCount, 0)
        XCTAssertTrue(harness.hubRepository.requestedNonNilSnapshotScopes.isEmpty)
    }

    func testFeedRestoresCachedHubsWhenCredentialsAreUnavailable() async throws {
        let cachedHub = makeHub()
        let harness = makeHarness(
            cachedHubs: [cachedHub],
            credentialReadUnavailable: true
        )

        let snapshot = try await harness.hubLoader.loadCachedSnapshot()

        XCTAssertEqual(harness.accountManager.credentialLoadState, .unavailable)
        XCTAssertEqual(snapshot.orderedHubs.map(\.id), [cachedHub.id])
    }

    func testFeedRestoresCachedHubsWhenSavedCredentialsAreMissing() async throws {
        let cachedHub = makeHub()
        let harness = makeHarness(cachedHubs: [cachedHub])

        let snapshot = try await harness.hubLoader.loadCachedSnapshot()

        XCTAssertEqual(harness.accountManager.credentialLoadState, .loaded)
        XCTAssertFalse(harness.accountManager.hasAnySources)
        XCTAssertEqual(snapshot.orderedHubs.map(\.id), [cachedHub.id])
    }

    func testFeedMergesCachedPriorityHubsBeforePublishing() async throws {
        func hub(_ identifier: String, title: String, source: String) -> Hub {
            Hub(
                id: "\(source):\(identifier)",
                title: title,
                type: "album",
                items: [
                    HubItem(
                        id: identifier + source,
                        type: "album",
                        title: title,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source
                    )
                ]
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = "plex:account-2:server-2:library-2"
        let cachedHubs = [
            hub("music.recent.added.1", title: "Recently Added in One", source: firstSource),
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.recent.played.1", title: "Recently Played Music", source: firstSource),
            hub("music.recent.played.2", title: "Recently Played Music", source: secondSource),
            hub("music.popular.1", title: "Most Played in June", source: firstSource),
            hub("music.popular.2", title: "Most Played in July", source: secondSource),
        ]

        let snapshot = try await makeHarness(cachedHubs: cachedHubs).hubLoader.loadCachedSnapshot()

        XCTAssertEqual(snapshot.orderedHubs.map(\.title), ["Recently Added", "Recently Played Music", "Most Played"])
        XCTAssertEqual(snapshot.orderedHubs.map(\.items.count), [2, 2, 2])
    }

    func testFeedMergesPriorityHubsAcrossServersUsingPlexOrderingMetadata() {
        func item(
            _ id: String,
            source: String,
            addedAt: TimeInterval? = nil,
            lastViewedAt: TimeInterval? = nil,
            viewCount: Int? = nil
        ) -> HubItem {
            HubItem(
                id: id,
                type: "album",
                title: id,
                subtitle: nil,
                thumbPath: nil,
                year: nil,
                sourceCompositeKey: source,
                addedAt: addedAt.map(Date.init(timeIntervalSince1970:)),
                lastViewedAt: lastViewedAt.map(Date.init(timeIntervalSince1970:)),
                viewCount: viewCount
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = "plex:account-2:server-2:library-2"
        let hubs = [
            Hub(id: "\(firstSource):music.recent.added.1", title: "Recently Added in One", type: "album", items: [item("added-old", source: firstSource, addedAt: 100)]),
            Hub(id: "\(secondSource):music.recent.added.2", title: "Recently Added in Two", type: "album", items: [item("added-new", source: secondSource, addedAt: 300)]),
            Hub(id: "\(firstSource):music.recent.played.1", title: "Recently Played Music", type: "album", items: [item("played-new", source: firstSource, lastViewedAt: 400)]),
            Hub(id: "\(secondSource):music.recent.played.2", title: "Recently Played Music", type: "album", items: [item("played-old", source: secondSource, lastViewedAt: 200)]),
            Hub(id: "\(firstSource):music.popular.1", title: "Most Played in June", type: "album", items: [item("popular-four", source: firstSource, lastViewedAt: 500, viewCount: 4)]),
            Hub(id: "\(secondSource):music.popular.2", title: "Most Played in July", type: "album", items: [
                item("popular-nine-old", source: secondSource, lastViewedAt: 100, viewCount: 9),
                item("popular-nine-new", source: secondSource, lastViewedAt: 300, viewCount: 9),
            ]),
            Hub(id: "\(firstSource):music.recent.artist.1", title: "More by Artist", type: "album", items: [item("artist-one", source: firstSource)]),
            Hub(id: "\(secondSource):music.recent.artist.2", title: "More by Artist", type: "album", items: [item("artist-two", source: secondSource)]),
        ]

        let merged = HomeHubLoader.mergeAndGroupHubs(hubs)

        XCTAssertEqual(merged.first { $0.title == "Recently Added" }?.items.map(\.id), ["added-new", "added-old"])
        XCTAssertEqual(merged.first { $0.title == "Recently Played Music" }?.items.map(\.id), ["played-new", "played-old"])
        XCTAssertEqual(merged.first { $0.title == "Most Played" }?.items.map(\.id), ["popular-nine-new", "popular-nine-old", "popular-four"])
        XCTAssertEqual(merged.filter { $0.title == "More by Artist" }.count, 2)
    }

    func testFeedMergedHubsDeduplicateAccountAliasesForOnePhysicalLibrary() {
        func hub(source: String) -> Hub {
            Hub(
                id: "\(source):music.recent.added.1",
                title: "Recently Added",
                type: "album",
                items: [
                    HubItem(
                        id: "album-1",
                        type: "album",
                        title: source,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source
                    )
                ]
            )
        }

        let merged = HomeHubLoader.mergeAndGroupHubs([
            hub(source: "plex:account-1:shared-server:library-1"),
            hub(source: "plex:account-2:shared-server:library-1"),
            hub(source: "plex:account-2:shared-server:library-2"),
            hub(source: "plex:account-2:other-server:library-1"),
        ])

        XCTAssertEqual(
            merged.first?.items.map(\.sourceCompositeKey),
            [
                "plex:account-1:shared-server:library-1",
                "plex:account-2:other-server:library-1",
                "plex:account-2:shared-server:library-2",
            ]
        )
    }

    func testFeedPriorityHubOrderSurvivesPartialPayloads() {
        let suiteName = "HomeViewModelRefreshPolicyTests.feed-order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let orderManager = HubOrderManager(userDefaults: defaults)

        func hub(_ identifier: String, title: String, source: String) -> Hub {
            Hub(
                id: "\(source):\(identifier)",
                title: title,
                type: "album",
                items: [
                    HubItem(
                        id: identifier + source,
                        type: "album",
                        title: title,
                        subtitle: nil,
                        thumbPath: nil,
                        year: nil,
                        sourceCompositeKey: source
                    )
                ]
            )
        }

        let firstSource = "plex:account-1:server-1:library-1"
        let secondSource = "plex:account-2:server-2:library-2"
        let initial = HomeHubLoader.mergeAndGroupHubs([
            hub("music.recent.added.1", title: "Recently Added in One", source: firstSource),
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.popular.1", title: "Most Played in June", source: firstSource),
            hub("music.popular.2", title: "Most Played in July", source: secondSource),
        ])
        orderManager.saveOrder(initial.reversed().map(\.id), for: "plex:feed:global")

        let refreshed = HomeHubLoader.mergeAndGroupHubs([
            hub("music.recent.added.2", title: "Recently Added in Two", source: secondSource),
            hub("music.popular.2", title: "Most Played in August", source: secondSource),
        ])
        let ordered = orderManager.applyOrder(to: refreshed, for: "plex:feed:global")

        XCTAssertEqual(ordered.map(\.title), ["Most Played", "Recently Added"])
        XCTAssertTrue(ordered.allSatisfy { $0.id.hasPrefix("plex:feed:global:merged:") })
    }

    private func makeSourceIdentifier() -> MusicSourceIdentifier {
        MusicSourceIdentifier(
            type: .plex,
            accountId: "account-enabled",
            serverId: "server-enabled",
            libraryId: "lib-enabled"
        )
    }

    func testHiddenFeedDefersAutoRefreshUntilVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)
    }

    func testDeferredRefreshRunsWhenFeedBecomesVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)

        sut.handleViewVisibilityChange(isVisible: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 1)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testManualRefreshRunsImmediately() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var loadCount = 0
        var applySavedOrderFlags: [Bool] = []
        sut.loadHubsRunnerForTesting = { applySavedOrder in
            loadCount += 1
            applySavedOrderFlags.append(applySavedOrder)
        }

        sut.handleViewVisibilityChange(isVisible: true)

        await sut.refresh()

        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(applySavedOrderFlags, [true])
    }

    func testAutomaticFeedLoadSkipsRecentNetworkSnapshot() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date())
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 0)
    }

    func testFeedEntryRevalidatesExistingCachedContentWhenNetworkSnapshotIsStale() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        sut.seedLastNetworkHubFetchTimeForTesting(Date(timeIntervalSinceNow: -(10 * 60 + 1)))
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 1)
    }

    func testAutomaticFeedLoadSkipsFreshCachedSnapshotAfterViewModelRecreation() async {
        let cachedHub = makeHub()
        let loader = MockHomeHubLoader(
            cachedHubs: [cachedHub],
            cachedFetchedAt: Date(),
            cachedFreshnessState: .fresh
        )
        let (sut, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 0)
    }

    func testFeedEntryRevalidatesCachedContentWithoutNetworkTimestampOncePerWindow() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([makeHub()])
        var loadCount = 0
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubsIfNeeded()
        await sut.loadHubsIfNeeded()

        XCTAssertEqual(loadCount, 1)
    }

    func testHiddenNetworkRefreshDoesNotReplaceVisibleFeedContent() async {
        let cachedHub = makeHub(id: "cached-hub")
        let networkHub = makeHub(id: "network-hub")
        let loader = MockHomeHubLoader(cachedHubs: [cachedHub], networkHubs: [networkHub])
        let (sut, _) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.seedHubsForTesting([cachedHub])
        sut.handleViewVisibilityChange(isVisible: true)

        let loadStarted = expectation(description: "network load started")
        let allowCompletion = expectation(description: "allow network load completion")
        loader.loadSnapshotHandler = { [self] _, _ in
            loadStarted.fulfill()
            await self.fulfillment(of: [allowCompletion], timeout: 1.0)
            return loader.networkSnapshot
        }

        let loadTask = Task {
            await sut.loadHubs()
        }

        await fulfillment(of: [loadStarted], timeout: 1.0)
        sut.handleViewVisibilityChange(isVisible: false)
        allowCompletion.fulfill()
        await loadTask.value

        XCTAssertEqual(sut.hubs.map(\.id), [cachedHub.id])
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

    func testMultipleHiddenRefreshTriggersRunOnceWhenFeedBecomesVisible() async {
        let sut = makeViewModel()
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }

        sut.requestAutoRefreshForTesting(reason: .contentChange)
        sut.requestAutoRefreshForTesting(reason: .accountChange)
        XCTAssertTrue(sut.hasPendingAutoRefreshForTesting)

        sut.handleViewVisibilityChange(isVisible: true)
        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(refreshCount, 1)
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
        sut.loadHubsRunnerForTesting = { _ in
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
        sut.loadHubsRunnerForTesting = { _ in
            loadCount += 1
        }

        await sut.loadHubs()

        XCTAssertEqual(waitCallCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testSourceStatusOnlyUpdateDoesNotTriggerFeedAutoRefresh() async {
        let loader = MockHomeHubLoader()
        let (sut, coordinator) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshCount = 0
        sut.autoRefreshRunnerForTesting = { _ in refreshCount += 1 }
        sut.handleViewVisibilityChange(isVisible: true)

        let source = makeSourceIdentifier()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source),
            status: MusicSourceStatus(syncStatus: .idle, connectionState: .connecting)
        )
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source),
            status: MusicSourceStatus(syncStatus: .idle, connectionState: .connected(url: "https://enabled.example.com"))
        )

        try? await Task.sleep(nanoseconds: 2_300_000_000)

        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(sut.hasPendingAutoRefreshForTesting)
    }

    func testMaterialContentChangeTriggersVisibleFeedAutoRefresh() async {
        let loader = MockHomeHubLoader()
        let (sut, coordinator) = makeViewModel(hubLoader: loader)
        try? await Task.sleep(nanoseconds: 30_000_000)
        sut.markInitialLoadCompletedForTesting()
        sut.clearPendingAutoRefreshForTesting()
        var refreshReasons: [HomeViewModel.AutoRefreshReason] = []
        sut.autoRefreshRunnerForTesting = { reason in refreshReasons.append(reason) }
        sut.handleViewVisibilityChange(isVisible: true)

        let source = makeSourceIdentifier()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .success(LibrarySyncResult(changedTracks: 1))
            ),
            status: MusicSourceStatus(
                syncStatus: .lastSynced(Date(timeIntervalSince1970: 1_000)),
                connectionState: .connected(url: "https://enabled.example.com")
            )
        )

        await coordinator.sync(source: source)
        try? await Task.sleep(nanoseconds: 1_300_000_000)

        XCTAssertEqual(refreshReasons, [.contentChange])
    }
}
