import XCTest
@testable import EnsembleCore
@testable import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorNetworkHealthTests: XCTestCase {

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

    private actor SyncInvocationProbe {
        private var libraryCallCount = 0
        private var cancellationCount = 0
        private var isReleased = false

        func beginAndWait() async throws {
            libraryCallCount += 1
            do {
                while !isReleased {
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
            } catch {
                cancellationCount += 1
                throw error
            }
        }

        func release() {
            isReleased = true
        }

        func counts() -> (libraryCalls: Int, cancellations: Int) {
            (libraryCallCount, cancellationCount)
        }
    }

    private struct MockSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        var libraryResult: Result<LibrarySyncResult, Error> = .success(LibrarySyncResult())
        var playlistResult: Result<PlaylistSyncResult, Error> = .success(PlaylistSyncResult())
        var invocationProbe: SyncInvocationProbe?

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            try await invocationProbe?.beginAndWait()
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
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
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

    func testForegroundRefreshDefersDuringInteractivePlaybackLoad() async {
        let (coordinator, networkMonitor) = makeCoordinator()
        let now = Date(timeIntervalSince1970: 41_000)
        coordinator.nowProviderForTesting = { now }
        coordinator.shouldDeferForegroundHealthRefresh = { true }
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        coordinator.setLastHealthRefreshForTesting(now.addingTimeInterval(-120))
        await coordinator.handleAppWillEnterForeground()
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 0)
    }

    func testForegroundRefreshStillRunsWhenDeferredLoadStateIsTooStale() async {
        let (coordinator, networkMonitor) = makeCoordinator()
        let now = Date(timeIntervalSince1970: 42_000)
        coordinator.nowProviderForTesting = { now }
        coordinator.shouldDeferForegroundHealthRefresh = { true }
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, _ in
            healthRefreshCount += 1
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        coordinator.setLastHealthRefreshForTesting(now.addingTimeInterval(-301))
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

    func testStartupHealthChecksCoalesceWithForegroundRefresh() async {
        let (coordinator, networkMonitor) = makeCoordinator()
        let now = Date(timeIntervalSince1970: 55_000)
        coordinator.nowProviderForTesting = { now }
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)

        var healthRefreshCount = 0
        coordinator.healthCheckRunnerForTesting = { _, keys in
            healthRefreshCount += 1
            try? await Task.sleep(nanoseconds: 80_000_000)
            return ServerHealthChecker.CheckSummary(checkedCount: keys.count, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        let startupTask = Task {
            await coordinator.performStartupHealthChecks()
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.handleAppWillEnterForeground()
        await startupTask.value
        await coordinator.awaitHealthRefreshForTesting()

        XCTAssertEqual(healthRefreshCount, 1)
    }

    func testPossiblyAvailableTreatsUnknownHealthAsPlayable() {
        let (coordinator, networkMonitor) = makeCoordinator()
        let sourceKey = "plex:account-1:server-1:lib-1"

        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        coordinator.serverHealthChecker.prepopulateUnknownStates()
        let resolver = TrackAvailabilityResolver(
            networkMonitor: networkMonitor,
            serverHealthChecker: coordinator.serverHealthChecker
        )
        let track = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track",
            sourceCompositeKey: sourceKey
        )

        XCTAssertFalse(coordinator.isServerAvailable(sourceKey: sourceKey))
        XCTAssertTrue(coordinator.isServerPossiblyAvailable(sourceKey: sourceKey))
        XCTAssertEqual(resolver.availability(for: track), .available)
    }

    func testSyncPublishesOnlyMaterialLibraryChanges() async {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "lib-1")
        let previousSyncDate = Date(timeIntervalSince1970: 1_000)

        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .success(LibrarySyncResult()),
                playlistResult: .success(PlaylistSyncResult(changedPlaylists: 1))
            ),
            status: MusicSourceStatus(syncStatus: .lastSynced(previousSyncDate), connectionState: .connected(url: "https://example.com"))
        )

        await coordinator.sync(source: source)
        XCTAssertTrue(coordinator.lastContentChange?.affectsLibraryBrowse == false)
        XCTAssertTrue(coordinator.lastContentChange?.affectsPlaylists == true)

        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .success(LibrarySyncResult(changedTracks: 2)),
                playlistResult: .success(PlaylistSyncResult())
            ),
            status: coordinator.sourceStatuses[source]
        )

        await coordinator.sync(source: source)

        XCTAssertEqual(coordinator.lastContentChange?.source, source)
        XCTAssertEqual(coordinator.lastContentChange?.libraryResult?.changedTracks, 2)
        XCTAssertTrue(coordinator.lastContentChange?.affectsLibraryBrowse == true)
    }

    func testConcurrentFullSyncEntrypointsShareOneSourceOperation() async throws {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )
        let probe = SyncInvocationProbe()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source, invocationProbe: probe),
            status: MusicSourceStatus(connectionState: .connected(url: "https://example.com"))
        )

        let allSourcesTask = Task { await coordinator.syncAll() }
        try await waitForLibraryCall(in: probe)
        let singleSourceTask = Task { await coordinator.sync(source: source) }
        try await Task.sleep(nanoseconds: 30_000_000)

        let concurrentCounts = await probe.counts()
        XCTAssertEqual(concurrentCounts.libraryCalls, 1)

        await probe.release()
        await allSourcesTask.value
        let outcome = await singleSourceTask.value
        let finalCounts = await probe.counts()
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(finalCounts.libraryCalls, 1)
    }

    func testProviderRefreshDuringSourceSyncPublishesTerminalError() async throws {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )
        let probe = SyncInvocationProbe()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source, invocationProbe: probe),
            status: MusicSourceStatus(connectionState: .connected(url: "https://example.com"))
        )

        let syncTask = Task { await coordinator.sync(source: source) }
        try await waitForLibraryCall(in: probe)
        coordinator.refreshProviders()
        await probe.release()

        let expectedMessage = "The music source changed while syncing. Please try again."
        let outcome = await syncTask.value
        XCTAssertEqual(outcome, .failure(message: expectedMessage))
        guard case .error(let message) = coordinator.sourceStatuses[source]?.syncStatus else {
            return XCTFail("Expected stale source work to finish with an observable error")
        }
        XCTAssertEqual(message, expectedMessage)
    }

    func testSourceCleanupCancelsActiveSourceSyncBeforePurging() async throws {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )
        let probe = SyncInvocationProbe()
        coordinator.installSyncProviderForTesting(
            MockSyncProvider(sourceIdentifier: source, invocationProbe: probe),
            status: MusicSourceStatus(connectionState: .connected(url: "https://example.com"))
        )

        let syncTask = Task { await coordinator.sync(source: source) }
        try await waitForLibraryCall(in: probe)
        coordinator.accountManager.removeMusicSource(source)

        let cleanupSucceeded = await coordinator.cleanupRemovedSource(source)
        _ = await syncTask.value
        let counts = await probe.counts()
        XCTAssertTrue(cleanupSucceeded)
        XCTAssertEqual(counts.libraryCalls, 1)
        XCTAssertEqual(counts.cancellations, 1)
        XCTAssertNil(coordinator.sourceStatuses[source])
    }

    func testUnavailableSourceSyncPublishesObservableError() async {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "1"
        )
        let expectedMessage = "The music source is unavailable. Please try again."

        let outcome = await coordinator.sync(source: source)

        XCTAssertEqual(outcome, .failure(message: expectedMessage))
        guard case .error(let message) = coordinator.sourceStatuses[source]?.syncStatus else {
            return XCTFail("Expected an observable source error")
        }
        XCTAssertEqual(message, expectedMessage)
    }

    func testCancellationRestoresPreviousStatusInsteadOfPublishingError() async {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "lib-1")
        let previousSyncDate = Date(timeIntervalSince1970: 2_000)

        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .failure(CancellationError())
            ),
            status: MusicSourceStatus(syncStatus: .lastSynced(previousSyncDate), connectionState: .connected(url: "https://example.com"))
        )

        await coordinator.sync(source: source)

        guard let status = coordinator.sourceStatuses[source] else {
            return XCTFail("Missing source status after cancelled sync")
        }

        XCTAssertEqual(status.connectionState, .connected(url: "https://example.com"))
        XCTAssertEqual(status.syncStatus, .lastSynced(previousSyncDate))
    }

    func testIncrementalSyncFallsBackToFullSyncWhenNoPreviousSyncExists() async {
        let (coordinator, _) = makeCoordinator()
        let source = MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "lib-1")

        coordinator.installSyncProviderForTesting(
            MockSyncProvider(
                sourceIdentifier: source,
                libraryResult: .success(LibrarySyncResult(changedAlbums: 1)),
                playlistResult: .success(PlaylistSyncResult(changedPlaylists: 1))
            ),
            status: MusicSourceStatus(syncStatus: .idle, connectionState: .connected(url: "https://example.com"))
        )

        await coordinator.syncIncremental(source: source)

        XCTAssertEqual(coordinator.lastContentChange?.source, source)
        XCTAssertEqual(coordinator.lastContentChange?.libraryResult?.changedAlbums, 1)
        XCTAssertTrue(coordinator.lastContentChange?.affectsPlaylists == true)
    }

    private func waitForLibraryCall(in probe: SyncInvocationProbe) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            guard await probe.counts().libraryCalls == 0 else { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let counts = await probe.counts()
        XCTAssertEqual(counts.libraryCalls, 1)
    }
}

@MainActor
final class ServerHealthCheckerCachePolicyTests: XCTestCase {

    private actor ProbeCounter {
        private var count = 0

        func value() -> Int { count }

        func perform(_ request: URLRequest) throws -> (Data, URLResponse) {
            count += 1
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(), response)
        }
    }

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
                        url: "https://example.com",
                        connections: [
                            PlexConnectionConfig(
                                uri: "https://example.com",
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

    private func makeChecker() -> ServerHealthChecker {
        let networkMonitor = NetworkMonitor()
        return ServerHealthChecker(
            accountManager: makeAccountManager(),
            networkMonitor: networkMonitor
        )
    }

    func testUnavailableTTLIsShorterThanAvailableTTL() {
        let checker = makeChecker()
        let availableTTL = checker.cacheTTL(for: .connected(url: "https://example.com"))
        let unavailableTTL = checker.cacheTTL(for: .offline)
        XCTAssertGreaterThan(availableTTL, unavailableTTL)
    }

    func testWebSocketHealthySignalExtendsCachedHealthWithoutProbing() async {
        let accountManager = makeAccountManager()
        let counter = ProbeCounter()
        var now = Date(timeIntervalSince1970: 1_000)
        let failover = ConnectionFailoverManager(timeout: 0.1) { request in
            try await counter.perform(request)
        }
        let checker = ServerHealthChecker(
            accountManager: accountManager,
            failoverManager: failover,
            cacheTTL: 120,
            unavailableCacheTTL: 10,
            nowProvider: { now }
        )

        _ = await checker.checkServer(accountId: "account-1", serverId: "server-1", forceRefresh: false)
        let firstProbeCount = await counter.value()
        XCTAssertEqual(firstProbeCount, 1)

        now = now.addingTimeInterval(100)
        checker.markServerHealthy(accountId: "account-1", serverId: "server-1")

        now = now.addingTimeInterval(100)
        _ = await checker.checkServer(accountId: "account-1", serverId: "server-1", forceRefresh: false)

        let secondProbeCount = await counter.value()
        XCTAssertEqual(secondProbeCount, 1)
    }
}
