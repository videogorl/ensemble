import XCTest
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorPlaylistMutationTests: XCTestCase {

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
        playlistRepository: PlaylistRepositoryProtocol = EmptyPlaylistRepository()
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
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: playlistRepository,
            artworkDownloadManager: EmptyArtworkDownloadManager(),
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
