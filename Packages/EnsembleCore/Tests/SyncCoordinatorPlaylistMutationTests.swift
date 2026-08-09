import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorPlaylistMutationTests: XCTestCase {

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

    private enum MockError: Error {
        case unimplemented
    }

    private actor LibraryAddGate {
        private(set) var invocationCount = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false

        func add() async -> MusicSourceLibraryAddOutcome {
            invocationCount += 1
            if !isReleased {
                await withCheckedContinuation { continuations.append($0) }
            }
            return .alreadyPresent
        }

        func release() {
            isReleased = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor RecordingPlaylistProvider: MusicSourceSyncProvider, MusicSourcePlaylistMutating {
        let sourceIdentifier: MusicSourceIdentifier
        private(set) var events: [String] = []

        init(sourceIdentifier: MusicSourceIdentifier = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-1"
        )) {
            self.sourceIdentifier = sourceIdentifier
        }

        func recordedEvents() -> [String] {
            events
        }

        func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
            events.append("create")
            return nil
        }

        func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
            events.append("add")
            return tracks.count
        }

        func renamePlaylist(_ playlistID: String, title: String) async throws {
            events.append("rename")
        }

        func deletePlaylist(_ playlistID: String) async throws {
            events.append("delete")
        }

        func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
            events.append("replace")
        }

        func editPlaylistItems(
            _ playlistID: String,
            originalItems: [PlaylistItem],
            editedItems: [PlaylistItem]
        ) async throws {
            events.append("edit")
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult { LibrarySyncResult() }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult { LibrarySyncResult() }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            events.append("refresh")
            return PlaylistSyncResult()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            events.append("refresh")
            return PlaylistSyncResult()
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
    }

    private func makeCoordinator(
        withServer: Bool = true,
        playlistRepository: PlaylistRepositoryProtocol = MockPlaylistRepository()
    ) -> SyncCoordinator {
        let accountManager = AccountManager(keychain: TestKeychain())
        if withServer {
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
        }

        let networkMonitor = NetworkMonitor()
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: MockLibraryRepository(),
            playlistRepository: playlistRepository,
            artworkDownloadManager: MockArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        if withServer {
            coordinator.refreshProviders()
        }
        coordinator.setLastPlaylistTargetForTesting(nil, serverSourceKey: "plex:account-1:server-1")
        return coordinator
    }

    func testAddTrackToLibraryCoalescesConcurrentRequests() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let gate = LibraryAddGate()
        let firstAddStarted = expectation(description: "First library add started")
        let secondAddCoalesced = expectation(description: "Second library add coalesced")
        coordinator.sourceLibraryAddHandlerForTesting = { _ in
            firstAddStarted.fulfill()
            return await gate.add()
        }
        coordinator.sourceLibraryAddDidCoalesceForTesting = {
            secondAddCoalesced.fulfill()
        }
        let track = Track(
            id: "catalog-id",
            key: "apple-catalog",
            title: "The Wolf",
            artistName: "half alive",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        let first = Task { try await coordinator.addTrackToLibrary(track) }
        await fulfillment(of: [firstAddStarted], timeout: 1)
        let second = Task { try await coordinator.addTrackToLibrary(track) }
        await fulfillment(of: [secondAddCoalesced], timeout: 1)
        await gate.release()
        let secondOutcome = try await second.value
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome, .alreadyPresent)
        XCTAssertEqual(secondOutcome, .alreadyPresent)
        let finalInvocationCount = await gate.invocationCount
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testOptimisticAppleMusicPlaylistAddPersistsMembershipImmediately() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "playlist-1",
            title: "Sleepy Ambient",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: 200_000,
            trackCount: 2,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
        )
        try await repository.setPlaylistTrackSnapshots(
            [
                PlaylistTrackSnapshot(ratingKey: "one", title: "One", duration: 90, sourceCompositeKey: sourceKey),
                PlaylistTrackSnapshot(ratingKey: "two", title: "Two", duration: 110, sourceCompositeKey: sourceKey)
            ],
            forPlaylist: "playlist-1",
            sourceCompositeKey: sourceKey
        )
        let playlist = Playlist(
            id: "playlist-1",
            key: "playlist-1",
            title: "Sleepy Ambient",
            trackCount: 2,
            duration: 200,
            sourceCompositeKey: sourceKey
        )
        let espresso = Track(
            id: "1752214923",
            key: "apple-catalog",
            title: "Espresso",
            artistName: "Sabrina Carpenter",
            albumName: "Short n' Sweet (Deluxe)",
            duration: 175.5,
            sourceCompositeKey: sourceKey
        )
        let coordinator = makeCoordinator(withServer: false, playlistRepository: repository)

        let firstCount = try await coordinator.persistOptimisticPlaylistAdd([espresso], playlist: playlist)
        let duplicateCount = try await coordinator.persistOptimisticPlaylistAdd([espresso], playlist: playlist)
        XCTAssertEqual(firstCount, 3)
        XCTAssertEqual(duplicateCount, 3)

        let fetched = try await repository.fetchPlaylist(ratingKey: playlist.id, sourceCompositeKey: sourceKey)
        let cached = try XCTUnwrap(fetched)
        XCTAssertEqual(cached.trackCount, 3)
        XCTAssertEqual(cached.playlistItemsArray.map(PlaylistItem.init(from:)).map(\.track.title), ["One", "Two", "Espresso"])
    }

    func testDeletePlaylistRejectsSmartPlaylist() async throws {
        let coordinator = makeCoordinator()
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Smart",
            summary: nil,
            isSmart: true,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )

        do {
            try await coordinator.deletePlaylist(playlist)
            XCTFail("Expected smart playlist mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .smartPlaylistReadOnly)
        }
    }

    func testDeletePlaylistRejectsInvalidSource() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:missing-account:missing-server"
        )

        do {
            try await coordinator.deletePlaylist(playlist)
            XCTFail("Expected invalid source mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .invalidSource)
        }
    }

    func testEditPlaylistItemsRejectsReadOnlyPlaylistBeforeProviderMutation() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Read Only",
            sourceCompositeKey: "plex:account-1:server-1",
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: true,
                canRename: false,
                canReorder: false,
                canDelete: false
            )
        )

        do {
            try await coordinator.editPlaylistItems(
                playlist,
                originalItems: [],
                editedItems: []
            )
            XCTFail("Expected read-only playlist mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .smartPlaylistReadOnly)
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testServerScopedPlaylistMutationsRouteThroughRegisteredProvider() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let track = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track",
            sourceCompositeKey: provider.sourceIdentifier.compositeKey
        )
        let item = PlaylistItem(id: "item-1", playlistItemID: "item-1", track: track)

        _ = try await coordinator.createPlaylist(
            title: "Created",
            tracks: [track],
            serverSourceKey: "plex:account-1:server-1"
        )
        _ = try await coordinator.addTracksToPlaylist([track], playlist: playlist)
        try await coordinator.renamePlaylist(playlist, to: "Renamed")
        try await coordinator.replacePlaylistContents(playlist, with: [track])
        try await coordinator.editPlaylistItems(
            playlist,
            originalItems: [item],
            editedItems: []
        )
        try await coordinator.deletePlaylist(playlist)

        for _ in 0..<10 {
            if (await provider.recordedEvents()).contains("refresh") { break }
            await Task.yield()
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(
            events.filter { $0 != "refresh" },
            ["create", "add", "rename", "replace", "edit", "delete"]
        )
        XCTAssertTrue(events.contains("refresh"))
    }

    func testOnlinePlaylistMutationsRejectTrackFromRemovedSiblingLibrary() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let retainedSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-2"
        )
        let provider = RecordingPlaylistProvider(sourceIdentifier: retainedSource)
        coordinator.setSyncProvidersForTesting([
            retainedSource.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let removedTrack = Track(
            id: "removed-track",
            key: "/library/metadata/removed-track",
            title: "Removed",
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        let mutations: [() async throws -> Void] = [
            { _ = try await coordinator.createPlaylist(
                title: "Created",
                tracks: [removedTrack],
                serverSourceKey: "plex:account-1:server-1"
            ) },
            { _ = try await coordinator.addTracksToPlaylist([removedTrack], playlist: playlist) },
            { try await coordinator.replacePlaylistContents(playlist, with: [removedTrack]) }
        ]

        for mutation in mutations {
            do {
                try await mutation()
                XCTFail("Expected stale-library mutation to fail")
            } catch let error as PlaylistMutationError {
                XCTAssertEqual(error, .invalidSource)
            }
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testEditPlaylistAllowsServerOwnedItemFromRemovedLibrary() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let retainedSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-2"
        )
        let provider = RecordingPlaylistProvider(sourceIdentifier: retainedSource)
        coordinator.setSyncProvidersForTesting([retainedSource.compositeKey: provider])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let removedTrack = Track(
            id: "removed-track",
            key: "/library/metadata/removed-track",
            title: "Removed",
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        let item = PlaylistItem(id: "item", playlistItemID: "item", track: removedTrack)

        try await coordinator.editPlaylistItems(
            playlist,
            originalItems: [item],
            editedItems: []
        )

        let events = await provider.recordedEvents()
        XCTAssertTrue(events.contains("edit"))
    }

    func testDeletePlaylistClearsMatchingRecentTarget() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )

        coordinator.setLastPlaylistTargetForTesting(
            LastPlaylistTarget(
                id: "playlist-1",
                title: "Regular",
                sourceCompositeKey: "plex:account-1:server-1"
            ),
            serverSourceKey: "plex:account-1:server-1"
        )
        try await coordinator.deletePlaylist(playlist)

        XCTAssertNil(coordinator.lastPlaylistTarget(forServerSourceKey: "plex:account-1:server-1"))
        XCTAssertNil(coordinator.lastPlaylistTarget)
    }
}
