import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorStartupRepairTests: XCTestCase {
    private let sourceId = MusicSourceIdentifier(
        type: .plex,
        accountId: "account-1",
        serverId: "server-1",
        libraryId: "1"
    )

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

    private final class RecordingSyncProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        private(set) var fullLibrarySyncCount = 0
        private(set) var incrementalLibrarySyncCount = 0
        var onFullLibrarySync: (() -> Void)?
        var onIncrementalLibrarySync: (() -> Void)?

        init(sourceIdentifier: MusicSourceIdentifier) {
            self.sourceIdentifier = sourceIdentifier
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            fullLibrarySyncCount += 1
            onFullLibrarySync?()
            progressHandler(1.0)
            return LibrarySyncResult(changedAlbums: 10, changedTracks: 50, changedGenres: 5)
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            incrementalLibrarySyncCount += 1
            onIncrementalLibrarySync?()
            progressHandler(1.0)
            return LibrarySyncResult()
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return PlaylistSyncResult()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1.0)
            return PlaylistSyncResult()
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

    func testRepairHeuristicTriggersForSparseGenreMetadata() {
        let stats = GenreCoverageStats(
            albumCount: 304,
            albumsWithGenreNames: 3,
            trackCount: 1917,
            tracksWithGenreNames: 15,
            genreCatalogCount: 19
        )

        XCTAssertTrue(SyncCoordinator.shouldRepairSparseGenreMetadata(stats))
    }

    func testStartupSyncForcesFullSyncWhenGenreMetadataIsSparse() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = MockPlaylistRepository()
        let artworkManager = MockArtworkDownloadManager()
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
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        coordinator.healthCheckRunnerForTesting = { _, _ in
            ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        let sourceKey = sourceId.compositeKey
        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: sourceKey,
            type: "plex",
            accountId: sourceId.accountId,
            serverId: sourceId.serverId,
            libraryId: sourceId.libraryId,
            displayName: "Music",
            accountName: "tester"
        )
        try await libraryRepository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)

        for index in 0..<5 {
            _ = try await libraryRepository.upsertGenre(
                ratingKey: "genre-\(index)",
                key: "/library/sections/1/genre/\(index)",
                title: "Genre \(index)",
                sourceCompositeKey: sourceKey
            )
        }

        let albumDate = Date()
        try await libraryRepository.batchUpsertAlbums(
            (0..<10).map { index in
                AlbumUpsertInput(
                    ratingKey: "album-\(index)",
                    key: "/library/metadata/album-\(index)",
                    title: "Album \(index)",
                    artistName: "Artist",
                    albumArtist: "Artist",
                    artistRatingKey: "artist-1",
                    summary: nil,
                    thumbPath: nil,
                    artPath: nil,
                    year: 2024,
                    trackCount: 5,
                    dateAdded: albumDate,
                    dateModified: albumDate,
                    rating: 0,
                    genreNames: index == 0 ? "Genre 0" : nil
                )
            },
            sourceCompositeKey: sourceKey
        )

        for index in 0..<50 {
            let albumIndex = index / 5
            let genreNames = index < 2 ? "Genre 0" : nil
            _ = try await libraryRepository.upsertTrack(
                ratingKey: "track-\(index)",
                key: "/library/metadata/track-\(index)",
                title: "Track \(index)",
                artistName: "Artist",
                albumName: "Album \(albumIndex)",
                albumRatingKey: "album-\(albumIndex)",
                trackNumber: (index % 5) + 1,
                discNumber: 1,
                duration: 180_000,
                thumbPath: nil,
                streamKey: "/library/metadata/track-\(index)",
                dateAdded: Date(),
                dateModified: Date(),
                lastPlayed: nil,
                lastRatedAt: nil,
                rating: 0,
                playCount: 0,
                genreNames: genreNames,
                sourceCompositeKey: sourceKey
            )
        }

        let provider = RecordingSyncProvider(sourceIdentifier: sourceId)
        coordinator.installSyncProviderForTesting(provider)

        await coordinator.performStartupSync()

        XCTAssertEqual(provider.fullLibrarySyncCount, 1)
        XCTAssertEqual(provider.incrementalLibrarySyncCount, 0)
        XCTAssertNotNil(coordinator.lastStartupSyncCompletion)
    }

    func testStartupSyncWaitsForHealthChecksAndInvalidatesPlexReconciliationCursors() async throws {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let syncCursorRepository = SyncCursorRepository(coreDataStack: stack)
        let playlistRepository = MockPlaylistRepository()
        let artworkManager = MockArtworkDownloadManager()
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
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            syncCursorRepository: syncCursorRepository,
            artworkDownloadManager: artworkManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        coordinator.refreshAPIClientConnectionsRunnerForTesting = {}

        var healthChecksCompleted = false
        coordinator.healthCheckRunnerForTesting = { _, _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            healthChecksCompleted = true
            return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
        }

        let sourceKey = sourceId.compositeKey
        _ = try await libraryRepository.upsertMusicSource(
            compositeKey: sourceKey,
            type: "plex",
            accountId: sourceId.accountId,
            serverId: sourceId.serverId,
            libraryId: sourceId.libraryId,
            displayName: "Music",
            accountName: "tester"
        )
        try await libraryRepository.updateMusicSourceSyncTimestamp(compositeKey: sourceKey)
        try await syncCursorRepository.recordFullSync(
            scopeKey: sourceKey,
            scopeType: .plexLibrary,
            at: Date()
        )
        let serverSourceKey = MediaSourceIdentity.serverSourceKey(for: sourceId)
        try await syncCursorRepository.recordFullSync(
            scopeKey: serverSourceKey,
            scopeType: .serverPlaylists,
            at: Date()
        )
        let legacyPlaylistKey = PlexMusicSourceSyncProvider.playlistOrphanCheckKey(for: serverSourceKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: legacyPlaylistKey)
        defer { UserDefaults.standard.removeObject(forKey: legacyPlaylistKey) }

        let provider = RecordingSyncProvider(sourceIdentifier: sourceId)
        var syncObservedCompletedHealthChecks = false
        provider.onIncrementalLibrarySync = {
            syncObservedCompletedHealthChecks = healthChecksCompleted
        }
        coordinator.installSyncProviderForTesting(provider)

        let healthTask = Task { @MainActor in
            await coordinator.performStartupHealthChecks()
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.performStartupSync()
        await healthTask.value

        XCTAssertTrue(healthChecksCompleted)
        XCTAssertTrue(syncObservedCompletedHealthChecks)
        XCTAssertEqual(provider.incrementalLibrarySyncCount, 1)
        let cursor = try await syncCursorRepository.fetchCursor(
            scopeKey: sourceKey,
            scopeType: .plexLibrary
        )
        XCTAssertNil(cursor)
        let playlistCursor = try await syncCursorRepository.fetchCursor(
            scopeKey: serverSourceKey,
            scopeType: .serverPlaylists
        )
        XCTAssertNil(playlistCursor?.lastInventorySyncAt)
        XCTAssertNil(UserDefaults.standard.object(forKey: legacyPlaylistKey))
    }
}
