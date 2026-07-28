import XCTest
@testable import EnsembleCore
import EnsembleAPI
import CoreData
import EnsemblePersistence

@MainActor
final class PlaylistDetailViewModelTests: XCTestCase {

    private final class MockLibraryRepository: LibraryRepositoryProtocol, @unchecked Sendable {
        var favoriteTracks: [CDTrack] = []
        var refreshedFavoriteTracks: [CDTrack]?
        var refreshContextCallCount = 0

        func refreshContext() async {
            refreshContextCallCount += 1
            if let refreshedFavoriteTracks {
                favoriteTracks = refreshedFavoriteTracks
            }
        }
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
        func fetchFavoriteTracks() async throws -> [CDTrack] { favoriteTracks }
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
        var playlists: [String: CDPlaylist] = [:]
        var fetchPlaylistCallCount = 0
        var fetchPlaylistsCallCount = 0
        var fetchPlaylistsForReferencesCallCount = 0

        func fetchPlaylists() async throws -> [CDPlaylist] {
            fetchPlaylistsCallCount += 1
            return Array(playlists.values)
        }

        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] {
            fetchPlaylistsCallCount += 1
            guard let sourceCompositeKey else { return Array(playlists.values) }
            return playlists.values.filter { $0.sourceCompositeKey == sourceCompositeKey }
        }

        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? {
            playlists[ratingKey]
        }

        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
            fetchPlaylistCallCount += 1
            return playlists[playlistKey(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)] ?? playlists[ratingKey]
        }

        func fetchPlaylists(forReferences references: [SourceScopedArtworkReference]) async throws -> [String: CDPlaylist] {
            fetchPlaylistsForReferencesCallCount += 1
            var result: [String: CDPlaylist] = [:]
            result.reserveCapacity(references.count)
            for reference in references {
                let key = playlistKey(ratingKey: reference.ratingKey, sourceCompositeKey: reference.sourceCompositeKey)
                if let playlist = playlists[key] {
                    result[reference.lookupKey] = playlist
                }
            }
            return result
        }

        func searchPlaylists(query: String) async throws -> [CDPlaylist] { [] }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { [] }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist { throw MockError.unimplemented }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {}
        func deletePlaylist(ratingKey: String) async throws {}
        func deletePlaylists(sourceCompositeKey: String) async throws {}
        func removeDuplicatePlaylists() async throws {}
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { 0 }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { [:] }

        func playlistKey(ratingKey: String, sourceCompositeKey: String?) -> String {
            "\(sourceCompositeKey ?? "")|\(ratingKey)"
        }
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

    private final class MockPendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
        func fetchPendingMutations() async throws -> [CDPendingMutation] { [] }
        func fetchAllMutations() async throws -> [CDPendingMutation] { [] }
        func enqueueMutation(id: String, type: CDPendingMutation.MutationType, payload: Data, sourceCompositeKey: String?) async throws {}
        func incrementRetryCount(id: String) async throws {}
        func markFailed(id: String) async throws {}
        func resetToRetry(id: String) async throws {}
        func deleteMutation(id: String) async throws {}
        func deleteAllMutations() async throws {}
        func countPendingMutations() async throws -> Int { 0 }
    }

    private final class RecordingPendingMutationRepository: PendingMutationRepositoryProtocol, @unchecked Sendable {
        var pending: [CDPendingMutation]
        private(set) var deletedIDs: [String] = []
        private(set) var enqueued: [(type: CDPendingMutation.MutationType, sourceCompositeKey: String?)] = []

        init(pending: [CDPendingMutation]) {
            self.pending = pending
        }

        func fetchPendingMutations() async throws -> [CDPendingMutation] { pending }
        func fetchAllMutations() async throws -> [CDPendingMutation] { pending }

        func enqueueMutation(
            id _: String,
            type: CDPendingMutation.MutationType,
            payload _: Data,
            sourceCompositeKey: String?
        ) async throws {
            enqueued.append((type: type, sourceCompositeKey: sourceCompositeKey))
        }

        func incrementRetryCount(id _: String) async throws {}
        func markFailed(id _: String) async throws {}
        func resetToRetry(id _: String) async throws {}

        func deleteMutation(id: String) async throws {
            deletedIDs.append(id)
            pending.removeAll { $0.id == Optional(id) }
        }

        func deleteAllMutations() async throws {
            pending.removeAll()
        }

        func countPendingMutations() async throws -> Int { pending.count }
    }

    private enum MockError: Error {
        case unimplemented
    }

    private func makeSyncCoordinator() -> SyncCoordinator {
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
        accountManager.addPlexAccount(
            PlexAccountConfig(
                id: "account-2",
                displayTitle: "tester-2",
                authToken: "auth-2",
                servers: [
                    PlexServerConfig(
                        id: "server-2",
                        name: "Server 2",
                        url: "https://example-two.com",
                        token: "token-2",
                        libraries: [
                            PlexLibraryConfig(id: "lib-2", key: "2", title: "Music", isEnabled: true)
                        ]
                    )
                ]
            )
        )

        let networkMonitor = NetworkMonitor()
        let networkMonitorRef = networkMonitor
        return SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: MockPlaylistRepository(),
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitorRef,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitorRef)
        )
    }

    private func makeMutationCoordinator(syncCoordinator: SyncCoordinator) -> MutationCoordinator {
        let nm = NetworkMonitor()
        return MutationCoordinator(
            repository: MockPendingMutationRepository(),
            networkMonitor: nm,
            syncCoordinator: syncCoordinator
        )
    }

    private func makePlaylist(
        id: String = "playlist-1",
        title: String? = nil,
        isSmart: Bool = false,
        sourceCompositeKey: String = "plex:account-1:server-1"
    ) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)",
            title: title ?? (isSmart ? "Smart" : "Regular"),
            summary: nil,
            isSmart: isSmart,
            trackCount: 2,
            duration: 200,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makePlaylistAccount(libraryEnabled: Bool) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            email: "user@example.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server.example.com",
                    connections: [
                        PlexConnectionConfig(uri: "https://server.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "server-token",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(
                            id: "lib-1",
                            key: "lib-1",
                            title: "Music",
                            isEnabled: libraryEnabled
                        )
                    ]
                )
            ]
        )
    }

    private func makeTrack(
        id: String,
        duration: TimeInterval = 100,
        sourceCompositeKey: String = "plex:account-1:server-1:lib-1"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: id,
            duration: duration,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makePlaylistItem(_ track: Track, itemID: String) -> PlaylistItem {
        PlaylistItem(
            id: itemID,
            playlistItemID: itemID,
            track: track
        )
    }

    private func makeCachedFavoriteTrack(
        id: String,
        title: String,
        context: NSManagedObjectContext
    ) -> CDTrack {
        let cdTrack = CDTrack(context: context)
        cdTrack.ratingKey = id
        cdTrack.key = "/library/metadata/\(id)"
        cdTrack.title = title
        cdTrack.artistName = "Artist"
        cdTrack.albumName = "Album"
        cdTrack.duration = 100_000
        cdTrack.rating = 10
        cdTrack.lastRatedAt = Date()
        cdTrack.sourceCompositeKey = "plex:account-1:server-1:lib-1"
        return cdTrack
    }

    private func makeCachedPlaylist(
        _ playlist: Playlist,
        tracks: [Track],
        serverTrackCount: Int? = nil,
        context: NSManagedObjectContext
    ) -> CDPlaylist {
        let cdPlaylist = CDPlaylist(context: context)
        cdPlaylist.ratingKey = playlist.id
        cdPlaylist.key = playlist.key
        cdPlaylist.title = playlist.title
        cdPlaylist.summary = playlist.summary
        cdPlaylist.compositePath = playlist.compositePath
        cdPlaylist.isSmart = playlist.isSmart
        cdPlaylist.duration = Int64(playlist.duration * 1000)
        cdPlaylist.trackCount = Int32(serverTrackCount ?? tracks.count)
        cdPlaylist.dateAdded = playlist.dateAdded
        cdPlaylist.dateModified = playlist.dateModified
        cdPlaylist.lastPlayed = playlist.lastPlayed
        cdPlaylist.sourceCompositeKey = playlist.sourceCompositeKey

        let playlistTracks = tracks.enumerated().map { index, track in
            let cdTrack = CDTrack(context: context)
            cdTrack.ratingKey = track.id
            cdTrack.key = track.key
            cdTrack.title = track.title
            cdTrack.artistName = track.artistName
            cdTrack.albumName = track.albumName
            cdTrack.trackNumber = Int32(track.trackNumber)
            cdTrack.discNumber = Int32(track.discNumber)
            cdTrack.duration = Int64(track.duration * 1000)
            cdTrack.rating = Int16(track.rating)
            cdTrack.playCount = Int32(track.playCount)
            cdTrack.sourceCompositeKey = track.sourceCompositeKey

            let playlistTrack = CDPlaylistTrack(context: context)
            playlistTrack.order = Int32(index)
            playlistTrack.playlist = cdPlaylist
            playlistTrack.track = cdTrack
            return playlistTrack
        }
        cdPlaylist.playlistTracks = NSSet(array: playlistTracks)
        return cdPlaylist
    }

    private func waitForPlaylistIDs(
        viewModel: PlaylistViewModel,
        expectedIDs: [String]
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.playlists.map(\.id) == expectedIDs {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(viewModel.playlists.map(\.id), expectedIDs)
    }

    private func makePendingPlaylistAddMutation(
        id: String,
        playlistRatingKey: String,
        playlistSourceCompositeKey: String,
        context: NSManagedObjectContext
    ) throws -> CDPendingMutation {
        let mutation = CDPendingMutation(context: context)
        mutation.id = id
        mutation.type = CDPendingMutation.MutationType.playlistAdd.rawValue
        mutation.status = CDPendingMutation.MutationStatus.pending.rawValue
        mutation.createdAt = Date()
        mutation.payload = try JSONEncoder().encode(
            PlaylistMutationPayload(
                playlistRatingKey: playlistRatingKey,
                playlistSourceCompositeKey: playlistSourceCompositeKey,
                trackRatingKeys: ["track-1"],
                trackSourceCompositeKey: "\(playlistSourceCompositeKey):lib-1"
            )
        )
        mutation.sourceCompositeKey = playlistSourceCompositeKey
        return mutation
    }

    func testDeletePlaylistSuccessReturnsTrue() async {
        let syncCoordinator = makeSyncCoordinator()
        syncCoordinator.playlistDeleteHandlerForTesting = { _, _ in }
        syncCoordinator.refreshServerPlaylistsHandlerForTesting = { _ in }

        let playlist = makePlaylist()

        let viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: MockPlaylistRepository(),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )

        let didDelete = await viewModel.deletePlaylist()
        XCTAssertTrue(didDelete)
        XCTAssertNil(viewModel.error)
    }

    func testDeletePlaylistFailureSetsErrorAndReturnsFalse() async {
        let syncCoordinator = makeSyncCoordinator()
        let smartPlaylist = makePlaylist(isSmart: true)

        let viewModel = PlaylistDetailViewModel(
            playlist: smartPlaylist,
            playlistRepository: MockPlaylistRepository(),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )

        let didDelete = await viewModel.deletePlaylist()
        XCTAssertFalse(didDelete)
        XCTAssertEqual(viewModel.error, PlaylistMutationError.smartPlaylistReadOnly.localizedDescription)
    }

    func testOfflinePlaylistDeletePurgesPendingMutationsForMatchingSourceOnly() async throws {
        let syncCoordinator = makeSyncCoordinator()
        syncCoordinator.networkMonitor.injectNetworkStateForTesting(.offline, debounced: false)
        await syncCoordinator.handleAppWillEnterForeground()

        let context = CoreDataStack.inMemory().viewContext
        let matchingMutation = try makePendingPlaylistAddMutation(
            id: "matching",
            playlistRatingKey: "playlist-1",
            playlistSourceCompositeKey: "plex:account-1:server-1",
            context: context
        )
        let otherSourceMutation = try makePendingPlaylistAddMutation(
            id: "other-source",
            playlistRatingKey: "playlist-1",
            playlistSourceCompositeKey: "plex:account-2:server-2",
            context: context
        )
        let repository = RecordingPendingMutationRepository(
            pending: [matchingMutation, otherSourceMutation]
        )
        let mutationCoordinator = MutationCoordinator(
            repository: repository,
            networkMonitor: syncCoordinator.networkMonitor,
            syncCoordinator: syncCoordinator
        )

        let outcome = try await mutationCoordinator.deletePlaylist(
            makePlaylist(id: "playlist-1", sourceCompositeKey: "plex:account-1:server-1")
        )

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(repository.deletedIDs, ["matching"])
        XCTAssertEqual(repository.pending.map(\.id), ["other-source"])
        XCTAssertEqual(repository.enqueued.map(\.type), [.playlistDelete])
        XCTAssertEqual(repository.enqueued.map(\.sourceCompositeKey), ["plex:account-1:server-1"])
    }

    func testPlaylistViewModelPreservesVisiblePlaylistsWhenReloadTemporarilyEmpty() async {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )] = makeCachedPlaylist(playlist, tracks: [], context: context)

        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )

        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])

        playlistRepository.playlists.removeAll()
        await viewModel.loadPlaylists()

        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])
        XCTAssertNil(viewModel.error)
    }

    func testPlaylistViewModelCanOptOutOfExternalReloads() async throws {
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter(),
            observesExternalChanges: false
        )

        NotificationCenter.default.post(name: SyncCoordinator.playlistsDidRefresh, object: nil)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(playlistRepository.fetchPlaylistsCallCount, 0)
        _ = viewModel
    }

    func testPlaylistViewModelClearsVisiblePlaylistsAfterLibraryDataClearNotification() async throws {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(makePlaylistAccount(libraryEnabled: true))
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road", sourceCompositeKey: "plex:account-1:server-1")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )] = makeCachedPlaylist(playlist, tracks: [], context: context)

        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter(),
            accountManager: accountManager
        )

        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])

        playlistRepository.playlists.removeAll()
        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])

        NotificationCenter.default.post(name: CacheManager.libraryDataDidClear, object: nil)
        try await waitForPlaylistIDs(viewModel: viewModel, expectedIDs: [])

        XCTAssertTrue(viewModel.displayPlaylists.isEmpty)
        XCTAssertFalse(viewModel.isShowingStaleSnapshot)
    }

    func testPlaylistViewModelKeepsCompletedDeleteHiddenWhenCacheReloadIsStale() async {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        syncCoordinator.playlistDeleteHandlerForTesting = { _, _ in }
        syncCoordinator.refreshServerPlaylistsHandlerForTesting = { _ in }
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let deletedPlaylist = makePlaylist(id: "playlist-a", title: "Audit")
        let remainingPlaylist = makePlaylist(id: "playlist-b", title: "Road")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: deletedPlaylist.id,
            sourceCompositeKey: deletedPlaylist.sourceCompositeKey
        )] = makeCachedPlaylist(deletedPlaylist, tracks: [], context: context)
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: remainingPlaylist.id,
            sourceCompositeKey: remainingPlaylist.sourceCompositeKey
        )] = makeCachedPlaylist(remainingPlaylist, tracks: [], context: context)

        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )

        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.playlists.map(\.id).sorted(), ["playlist-a", "playlist-b"])

        let didDelete = await viewModel.deletePlaylist(deletedPlaylist)

        XCTAssertTrue(didDelete)
        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-b"])

        await viewModel.loadPlaylists()

        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-b"])
        XCTAssertEqual(viewModel.displayPlaylists.map(\.primaryPlaylist.id), ["playlist-b"])
    }

    func testPlaylistViewModelClearsVisiblePlaylistsWhenAllLibrariesAreDisabled() async {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.addPlexAccount(makePlaylistAccount(libraryEnabled: true))
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road", sourceCompositeKey: "plex:account-1:server-1")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )] = makeCachedPlaylist(playlist, tracks: [], context: context)

        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter(),
            accountManager: accountManager
        )

        await viewModel.loadPlaylists()
        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])

        accountManager.updatePlexAccount(makePlaylistAccount(libraryEnabled: false))
        await viewModel.loadPlaylists()

        XCTAssertTrue(viewModel.playlists.isEmpty)
        XCTAssertTrue(viewModel.displayPlaylists.isEmpty)
        XCTAssertFalse(viewModel.isShowingStaleSnapshot)
    }

    func testPlaylistViewModelSeedsNewInstanceFromLastGoodSnapshot() async {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )] = makeCachedPlaylist(playlist, tracks: [], context: context)

        let firstViewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )
        await firstViewModel.loadPlaylists()
        XCTAssertEqual(firstViewModel.displayPlaylists.map(\.primaryPlaylist.id), ["playlist-a"])

        let secondViewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )

        XCTAssertEqual(secondViewModel.playlists.map(\.id), ["playlist-a"])
        XCTAssertEqual(secondViewModel.displayPlaylists.map(\.primaryPlaylist.id), ["playlist-a"])
        XCTAssertTrue(secondViewModel.isShowingStaleSnapshot)

        await secondViewModel.loadPlaylists()
        XCTAssertFalse(secondViewModel.isShowingStaleSnapshot)
    }

    func testPlaylistViewModelSeedsInitialInstanceFromPersistentCache() {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let coreDataStack = CoreDataStack.inMemory()
        let playlistRepository = PlaylistRepository(coreDataStack: coreDataStack)
        let playlist = makePlaylist(id: "playlist-a", title: "Road")
        _ = makeCachedPlaylist(playlist, tracks: [], context: coreDataStack.viewContext)

        let viewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )

        XCTAssertEqual(viewModel.playlists.map(\.id), ["playlist-a"])
        XCTAssertEqual(viewModel.displayPlaylists.map(\.primaryPlaylist.id), ["playlist-a"])
    }

    func testPlaylistViewModelClearsStaleSeedWhenCacheIsActuallyEmpty() async {
        PlaylistViewModel.resetLastGoodSnapshotForTesting()
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road")
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )] = makeCachedPlaylist(playlist, tracks: [], context: context)

        let firstViewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )
        await firstViewModel.loadPlaylists()
        playlistRepository.playlists.removeAll()

        let secondViewModel = PlaylistViewModel(
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            toastCenter: ToastCenter()
        )
        XCTAssertEqual(secondViewModel.playlists.map(\.id), ["playlist-a"])

        await secondViewModel.loadPlaylists()

        XCTAssertTrue(secondViewModel.playlists.isEmpty)
        XCTAssertFalse(secondViewModel.isShowingStaleSnapshot)
    }

    func testFavoritesViewModelSeedsNewInstanceFromLastGoodSnapshot() async {
        FavoritesViewModel.resetLastGoodSnapshotForTesting()
        let libraryRepository = MockLibraryRepository()
        let context = CoreDataStack.inMemory().viewContext
        libraryRepository.favoriteTracks = [
            makeCachedFavoriteTrack(id: "track-a", title: "Favorite A", context: context)
        ]

        let firstViewModel = FavoritesViewModel(libraryRepository: libraryRepository)
        await firstViewModel.loadTracks()

        XCTAssertEqual(firstViewModel.tracks.map(\.id), ["track-a"])
        XCTAssertEqual(firstViewModel.filteredTracks.map(\.id), ["track-a"])

        libraryRepository.favoriteTracks = []
        let secondViewModel = FavoritesViewModel(libraryRepository: libraryRepository)

        XCTAssertEqual(secondViewModel.tracks.map(\.id), ["track-a"])
        XCTAssertEqual(secondViewModel.filteredTracks.map(\.id), ["track-a"])

        await secondViewModel.loadTracks()

        XCTAssertTrue(secondViewModel.tracks.isEmpty)
        XCTAssertTrue(secondViewModel.filteredTracks.isEmpty)
    }

    func testFavoritesViewModelSeedsInitialInstanceFromPersistentCache() {
        FavoritesViewModel.resetLastGoodSnapshotForTesting()
        let coreDataStack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: coreDataStack)
        _ = makeCachedFavoriteTrack(id: "track-a", title: "Favorite A", context: coreDataStack.viewContext)

        let viewModel = FavoritesViewModel(libraryRepository: libraryRepository)

        XCTAssertEqual(viewModel.tracks.map(\.id), ["track-a"])
        XCTAssertEqual(viewModel.filteredTracks.map(\.id), ["track-a"])
        XCTAssertFalse(viewModel.isLoading)
    }

    func testFavoritesViewModelRefreshesBeforeMappingFavoriteMetadata() async {
        FavoritesViewModel.resetLastGoodSnapshotForTesting()
        let libraryRepository = MockLibraryRepository()
        let context = CoreDataStack.inMemory().viewContext
        libraryRepository.favoriteTracks = [
            makeCachedFavoriteTrack(id: "stale-track", title: "Stale placeholder", context: context)
        ]
        libraryRepository.refreshedFavoriteTracks = [
            makeCachedFavoriteTrack(id: "track-a", title: "Favorite A", context: context)
        ]

        let viewModel = FavoritesViewModel(libraryRepository: libraryRepository)
        await viewModel.loadTracks()

        XCTAssertGreaterThanOrEqual(libraryRepository.refreshContextCallCount, 1)
        XCTAssertEqual(viewModel.tracks.first?.title, "Favorite A")
        XCTAssertEqual(viewModel.tracks.first?.artistName, "Artist")
        XCTAssertEqual(viewModel.tracks.first?.duration, 100)
    }

    func testPlaylistDetailPreservesTracksDuringIntermediateEmptyRelationshipReload() async {
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let playlist = makePlaylist(id: "playlist-a", title: "Road")
        let firstTracks = [makeTrack(id: "track-1"), makeTrack(id: "track-2")]
        let key = playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        playlistRepository.playlists[key] = makeCachedPlaylist(playlist, tracks: firstTracks, context: context)

        let viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )

        await viewModel.loadTracks()
        XCTAssertEqual(viewModel.tracks.map(\.id), ["track-1", "track-2"])

        let intermediate = makeCachedPlaylist(playlist, tracks: [], context: context)
        intermediate.trackCount = 2
        playlistRepository.playlists[key] = intermediate

        await viewModel.loadTracks()

        XCTAssertEqual(viewModel.tracks.map(\.id), ["track-1", "track-2"])
    }

    func testPlaylistDetailCanOptOutOfExternalReloads() async throws {
        let syncCoordinator = makeSyncCoordinator()
        let playlistRepository = MockPlaylistRepository()
        let viewModel = PlaylistDetailViewModel(
            playlist: makePlaylist(),
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            observesExternalChanges: false
        )

        NotificationCenter.default.post(name: SyncCoordinator.playlistsDidRefresh, object: nil)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(playlistRepository.fetchPlaylistCallCount, 0)
        _ = viewModel
    }

    func testRemoveTrackFromPlaylistDeletesMembershipWithoutReplacingContents() async {
        let syncCoordinator = makeSyncCoordinator()
        var removedPlaylistID: String?
        var removedItemID: String?
        var refreshedSourceKey: String?
        syncCoordinator.playlistRemoveItemHandlerForTesting = { _, playlistID, itemID in
            removedPlaylistID = playlistID
            removedItemID = itemID
        }
        syncCoordinator.refreshServerPlaylistsHandlerForTesting = { sourceKey in
            refreshedSourceKey = sourceKey
        }

        let tracks = [makeTrack(id: "track-1"), makeTrack(id: "track-2")]
        let items = [
            makePlaylistItem(tracks[0], itemID: "item-1"),
            makePlaylistItem(tracks[1], itemID: "item-2")
        ]
        let viewModel = PlaylistDetailViewModel(
            playlist: makePlaylist(),
            playlistRepository: MockPlaylistRepository(),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            initialItems: items
        )

        let didRemove = await viewModel.removeTrackFromPlaylist(tracks[0], displayIndex: 0)

        XCTAssertTrue(didRemove)
        XCTAssertEqual(removedPlaylistID, "playlist-1")
        XCTAssertEqual(removedItemID, "item-1")
        XCTAssertEqual(refreshedSourceKey, "plex:account-1:server-1")
        XCTAssertEqual(viewModel.tracks.map(\.id), ["track-2"])
        XCTAssertEqual(viewModel.playlist.trackCount, 1)
    }

    func testRemoveTrackFromPlaylistRejectsIncompleteCachedContents() async {
        let syncCoordinator = makeSyncCoordinator()
        var didReplace = false
        syncCoordinator.playlistReplaceContentsHandlerForTesting = { _, _, _, _ in
            didReplace = true
        }

        let playlist = makePlaylist(id: "playlist-a", title: "Mixed Libraries")
        let playlistRepository = MockPlaylistRepository()
        let context = CoreDataStack.inMemory().viewContext
        let key = playlistRepository.playlistKey(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        playlistRepository.playlists[key] = makeCachedPlaylist(
            playlist,
            tracks: [makeTrack(id: "enabled-track")],
            serverTrackCount: 2,
            context: context
        )

        let viewModel = PlaylistDetailViewModel(
            playlist: playlist,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )
        await viewModel.loadTracks()

        let didRemove = await viewModel.removeTrackFromPlaylist(makeTrack(id: "enabled-track"))

        XCTAssertTrue(viewModel.hasUnavailableTracks)
        XCTAssertFalse(didRemove)
        XCTAssertFalse(didReplace)
        XCTAssertEqual(viewModel.error, PlaylistMutationError.incompletePlaylistContents.localizedDescription)
        XCTAssertEqual(viewModel.tracks.map(\.id), ["enabled-track"])
    }

    func testRemoveTrackFromPlaylistWithoutDisplayIndexUsesSourceScopedIdentity() async {
        let syncCoordinator = makeSyncCoordinator()
        var removedItemIDs: [String] = []
        syncCoordinator.playlistRemoveItemHandlerForTesting = { _, _, itemID in
            removedItemIDs.append(itemID)
        }
        syncCoordinator.refreshServerPlaylistsHandlerForTesting = { _ in }

        let sharedLibraryTrack = makeTrack(
            id: "7551",
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        let testLibraryTrack = makeTrack(
            id: "7551",
            sourceCompositeKey: "plex:account-1:server-1:lib-2"
        )
        let viewModel = PlaylistDetailViewModel(
            playlist: makePlaylist(),
            playlistRepository: MockPlaylistRepository(),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            initialItems: [
                makePlaylistItem(sharedLibraryTrack, itemID: "item-shared"),
                makePlaylistItem(testLibraryTrack, itemID: "item-test")
            ]
        )

        let didRemove = await viewModel.removeTrackFromPlaylist(testLibraryTrack)

        XCTAssertTrue(didRemove)
        XCTAssertEqual(viewModel.tracks.map(\.sourceScopedID), [sharedLibraryTrack.sourceScopedID])
        XCTAssertEqual(removedItemIDs, ["item-test"])
    }

    func testRemoveTrackFromSmartPlaylistFailsWithoutReplacingContents() async {
        let syncCoordinator = makeSyncCoordinator()
        var didReplace = false
        syncCoordinator.playlistReplaceContentsHandlerForTesting = { _, _, _, _ in
            didReplace = true
        }

        let viewModel = PlaylistDetailViewModel(
            playlist: makePlaylist(isSmart: true),
            playlistRepository: MockPlaylistRepository(),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator),
            initialTracks: [makeTrack(id: "track-1")]
        )

        let didRemove = await viewModel.removeTrackFromPlaylist(makeTrack(id: "track-1"), displayIndex: 0)

        XCTAssertFalse(didRemove)
        XCTAssertFalse(didReplace)
        XCTAssertEqual(viewModel.error, PlaylistMutationError.smartPlaylistReadOnly.localizedDescription)
        XCTAssertEqual(viewModel.tracks.map(\.id), ["track-1"])
    }

    func testRemoveTrackFromMergedPlaylistReplacesOnlyMatchingServerPlaylist() async {
        let syncCoordinator = makeSyncCoordinator()
        var replacedPlaylistID: String?
        var replacedTrackIDs: [String] = []
        var replacedServerID: String?
        var refreshedSourceKey: String?
        syncCoordinator.playlistReplaceContentsHandlerForTesting = { _, playlistID, trackIDs, serverID in
            replacedPlaylistID = playlistID
            replacedTrackIDs = trackIDs
            replacedServerID = serverID
        }
        syncCoordinator.refreshServerPlaylistsHandlerForTesting = { sourceKey in
            refreshedSourceKey = sourceKey
        }

        let firstPlaylist = makePlaylist(
            id: "playlist-a",
            title: "Road",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let secondPlaylist = makePlaylist(
            id: "playlist-b",
            title: "Road",
            sourceCompositeKey: "plex:account-2:server-2"
        )
        let editorialPlaylist = makePlaylist(
            id: "apple-editorial",
            title: "Road",
            isSmart: true,
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let firstTracks = [
            makeTrack(id: "server-1-track-1", sourceCompositeKey: "plex:account-1:server-1:lib-1"),
            makeTrack(id: "server-1-track-2", sourceCompositeKey: "plex:account-1:server-1:lib-1")
        ]
        let secondTracks = [
            makeTrack(id: "server-2-track-1", sourceCompositeKey: "plex:account-2:server-2:lib-2"),
            makeTrack(id: "server-2-track-2", sourceCompositeKey: "plex:account-2:server-2:lib-2")
        ]
        let context = CoreDataStack.inMemory().viewContext
        let playlistRepository = MockPlaylistRepository()
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: firstPlaylist.id,
            sourceCompositeKey: firstPlaylist.sourceCompositeKey
        )] = makeCachedPlaylist(firstPlaylist, tracks: firstTracks, context: context)
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: secondPlaylist.id,
            sourceCompositeKey: secondPlaylist.sourceCompositeKey
        )] = makeCachedPlaylist(secondPlaylist, tracks: secondTracks, context: context)
        playlistRepository.playlists[playlistRepository.playlistKey(
            ratingKey: editorialPlaylist.id,
            sourceCompositeKey: editorialPlaylist.sourceCompositeKey
        )] = makeCachedPlaylist(editorialPlaylist, tracks: [], context: context)

        let viewModel = MergedPlaylistDetailViewModel(
            displayPlaylist: .merged(
                title: "Road",
                isSmart: true,
                playlists: [editorialPlaylist, firstPlaylist, secondPlaylist]
            ),
            playlistRepository: playlistRepository,
            accountManager: AccountManager(keychain: TestKeychain()),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )
        await viewModel.loadTracks()

        XCTAssertEqual(playlistRepository.fetchPlaylistsForReferencesCallCount, 1)
        XCTAssertEqual(playlistRepository.fetchPlaylistCallCount, 0)

        let didRemove = await viewModel.removeTrackFromPlaylist(secondTracks[0], displayIndex: 1)

        XCTAssertTrue(didRemove)
        XCTAssertEqual(replacedPlaylistID, "playlist-b")
        XCTAssertEqual(replacedTrackIDs, ["server-2-track-2"])
        XCTAssertEqual(replacedServerID, "server-2")
        XCTAssertEqual(refreshedSourceKey, "plex:account-2:server-2")
        XCTAssertEqual(
            viewModel.tracks.map(\.id),
            ["server-1-track-1", "server-1-track-2", "server-2-track-2"]
        )
    }

    func testRemoveTrackFromMergedPlaylistRejectsUnknownSourceAcrossMultiplePlaylists() async {
        let syncCoordinator = makeSyncCoordinator()
        var didReplace = false
        syncCoordinator.playlistReplaceContentsHandlerForTesting = { _, _, _, _ in
            didReplace = true
        }

        let viewModel = MergedPlaylistDetailViewModel(
            displayPlaylist: .merged(
                title: "Road",
                isSmart: false,
                playlists: [
                    makePlaylist(id: "playlist-a", title: "Road", sourceCompositeKey: "plex:account-1:server-1"),
                    makePlaylist(id: "playlist-b", title: "Road", sourceCompositeKey: "plex:account-2:server-2")
                ]
            ),
            playlistRepository: MockPlaylistRepository(),
            accountManager: AccountManager(keychain: TestKeychain()),
            syncCoordinator: syncCoordinator,
            mutationCoordinator: makeMutationCoordinator(syncCoordinator: syncCoordinator)
        )

        let didRemove = await viewModel.removeTrackFromPlaylist(
            Track(id: "unknown", key: "/library/metadata/unknown", title: "Unknown")
        )

        XCTAssertFalse(didRemove)
        XCTAssertFalse(didReplace)
        XCTAssertEqual(viewModel.error, "Could not determine which server playlist owns this track.")
    }

    func testOptimisticPlaylistAddImmediatelyRemembersItsTarget() async throws {
        let syncCoordinator = makeSyncCoordinator()
        let networkMonitor = NetworkMonitor()
        networkMonitor.simulateOffline(true)
        let mutationCoordinator = MutationCoordinator(
            repository: MockPendingMutationRepository(),
            networkMonitor: networkMonitor,
            syncCoordinator: syncCoordinator
        )
        let playlist = makePlaylist(id: "recent", title: "Recent Playlist")
        let track = makeTrack(id: "track")

        let outcome = try await mutationCoordinator.enqueuePlaylistAddOptimistically(
            [track],
            playlist: playlist
        )

        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(syncCoordinator.lastPlaylistTarget?.id, playlist.id)
        XCTAssertEqual(syncCoordinator.lastPlaylistTarget?.title, playlist.title)

        syncCoordinator.rememberLastPlaylistTarget(
            makePlaylist(id: playlist.id, title: "", sourceCompositeKey: playlist.sourceCompositeKey ?? "")
        )
        XCTAssertEqual(syncCoordinator.lastPlaylistTarget?.title, playlist.title)
    }

    func testPlaylistMutationPayloadDecodesLegacyPayloadWithoutTitle() throws {
        let data = Data(#"{"playlistRatingKey":"playlist","playlistSourceCompositeKey":"source","trackRatingKeys":["track"],"trackSourceCompositeKey":"track-source"}"#.utf8)

        let payload = try JSONDecoder().decode(PlaylistMutationPayload.self, from: data)

        XCTAssertNil(payload.playlistTitle)
    }
}
