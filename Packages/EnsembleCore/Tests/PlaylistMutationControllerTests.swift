import EnsemblePersistence
import XCTest
@testable import EnsembleCore

@MainActor
final class PlaylistMutationControllerTests: XCTestCase {
    private actor RefreshGate {
        private var started = false
        private var isOpen = false

        func wait() async {
            started = true
            while !isOpen { await Task.yield() }
        }

        func waitUntilStarted() async {
            while !started { await Task.yield() }
        }

        func open() {
            isOpen = true
        }
    }

    private actor RecordingProvider: MusicSourcePlaylistMutating {
        private(set) var events: [String] = []
        private let createdPlaylist: Playlist?

        init(createdPlaylist: Playlist? = nil) {
            self.createdPlaylist = createdPlaylist
        }

        func recordedEvents() -> [String] {
            events
        }

        func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
            events.append("create:\(title):\(tracks.map(\.id).joined(separator: ","))")
            return createdPlaylist
        }

        func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
            events.append("add:\(playlistID):\(tracks.map(\.id).joined(separator: ","))")
            return tracks.count
        }

        func renamePlaylist(_ playlistID: String, title: String) async throws {
            events.append("rename:\(playlistID):\(title)")
        }

        func deletePlaylist(_ playlistID: String) async throws {
            events.append("delete:\(playlistID)")
        }

        func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
            events.append("replace:\(playlistID):\(tracks.map(\.id).joined(separator: ","))")
        }

        func editPlaylistItems(
            _ playlistID: String,
            originalItems: [PlaylistItem],
            editedItems: [PlaylistItem]
        ) async throws {
            events.append("edit:\(playlistID):\(originalItems.count):\(editedItems.count)")
        }

    }

    private func makeTrack(
        id: String,
        sourceCompositeKey: String? = "plex:account-1:server-1:library-1"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            artistName: "Artist",
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makePlaylist(
        isSmart: Bool = false,
        sourceCompositeKey: String? = "plex:account-1:server-1"
    ) -> Playlist {
        Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist",
            isSmart: isSmart,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeController(
        fetchPlaylists: @escaping (String?) async throws -> [Playlist] = { _ in [] },
        persistCreated: @escaping (Playlist, [Track]) async throws -> Void = { _, _ in },
        persistTarget: @escaping (Playlist) -> Void = { _ in },
        clearTarget: @escaping (Playlist) -> Void = { _ in },
        deleteArtwork: @escaping (String, String) -> Void = { _, _ in },
        refresh: @escaping (String) async -> Void = { _ in },
        deferredRefresh: ((String) async -> Void)? = nil,
        reconcileAdd: @escaping (
            MusicSourcePlaylistMutating,
            Playlist,
            [Track],
            Int
        ) async -> Void = { _, _, _, _ in }
    ) -> PlaylistMutationController {
        PlaylistMutationController(
            dependencies: .init(
                fetchPlaylists: fetchPlaylists,
                persistCreatedPlaylist: persistCreated,
                persistOptimisticAdd: { tracks, playlist in
                    playlist.trackCount + tracks.count
                },
                reconcileAcceptedAdd: reconcileAdd,
                persistLastPlaylistTarget: persistTarget,
                clearLastPlaylistTargetIfNeeded: clearTarget,
                deletePlaylistArtwork: deleteArtwork,
                refreshPlaylists: refresh,
                refreshPlaylistsAfterMutation: { sourceKey, _ in
                    await (deferredRefresh ?? refresh)(sourceKey)
                }
            )
        )
    }

    func testCreateTrimsFiltersPersistsAndRefreshes() async throws {
        var target: Playlist?
        var refreshedSource: String?
        let created = Playlist(
            id: "created",
            key: "/playlists/created",
            title: "New Playlist",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let provider = RecordingProvider(createdPlaylist: created)
        let controller = makeController(
            fetchPlaylists: { _ in [] },
            persistTarget: { target = $0 },
            refresh: { sourceKey in refreshedSource = sourceKey }
        )

        let result = try await controller.createPlaylist(
            title: " New Playlist ",
            tracks: [makeTrack(id: "one"), makeTrack(id: "other", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey)],
            sourceKey: "plex:account-1:server-1",
            provider: provider
        )

        let events = await provider.recordedEvents()
        XCTAssertEqual(events, ["create:New Playlist:one"])
        XCTAssertEqual(result.addedCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        for _ in 0..<20 where target == nil {
            await Task.yield()
        }
        XCTAssertEqual(target?.id, "created")
        XCTAssertEqual(refreshedSource, "plex:account-1:server-1")
    }

    func testCreatePersistsProviderResultBeforeDeferredRefresh() async throws {
        let created = Playlist(
            id: "created",
            key: "/playlists/created",
            title: "New Playlist",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let provider = RecordingProvider(createdPlaylist: created)
        let refreshGate = RefreshGate()
        var persistedPlaylist: Playlist?
        var persistedTrackIDs: [String] = []
        var target: Playlist?
        let controller = makeController(
            persistCreated: { playlist, tracks in
                persistedPlaylist = playlist
                persistedTrackIDs = tracks.map(\.id)
            },
            persistTarget: { target = $0 },
            deferredRefresh: { _ in await refreshGate.wait() }
        )

        _ = try await controller.createPlaylist(
            title: "New Playlist",
            tracks: [makeTrack(id: "one")],
            sourceKey: "plex:account-1:server-1",
            provider: provider
        )

        await refreshGate.waitUntilStarted()
        XCTAssertEqual(persistedPlaylist?.id, "created")
        XCTAssertEqual(persistedTrackIDs, ["one"])
        XCTAssertEqual(target?.id, "created")
        await refreshGate.open()
    }

    func testCreateDoesNotReturnBeforeProviderResultIsPersisted() async throws {
        let created = Playlist(
            id: "created",
            key: "/playlists/created",
            title: "New Playlist",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let provider = RecordingProvider(createdPlaylist: created)
        let persistenceGate = RefreshGate()
        var didReturn = false
        let createTask = Task { @MainActor in
            _ = try await makeController(
                persistCreated: { _, _ in await persistenceGate.wait() }
            ).createPlaylist(
                title: "New Playlist",
                tracks: [],
                sourceKey: "plex:account-1:server-1",
                provider: provider
            )
            didReturn = true
        }

        await persistenceGate.waitUntilStarted()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(didReturn)

        await persistenceGate.open()
        try await createTask.value
        XCTAssertTrue(didReturn)
    }

    func testCreateReplaceAndEditReturnBeforeRefreshCompletes() async throws {
        let provider = RecordingProvider()
        let createGate = RefreshGate()
        let createCompleted = expectation(description: "create returned")
        let createTask = Task {
            defer { createCompleted.fulfill() }
            return try await makeController(refresh: { _ in await createGate.wait() })
                .createPlaylist(
                    title: "New Playlist",
                    tracks: [],
                    sourceKey: "plex:account-1:server-1",
                    provider: provider
                )
        }
        await createGate.waitUntilStarted()
        await fulfillment(of: [createCompleted], timeout: 1)
        await createGate.open()
        _ = try await createTask.value

        let replaceGate = RefreshGate()
        let replaceCompleted = expectation(description: "replace returned")
        let replaceTask = Task {
            defer { replaceCompleted.fulfill() }
            try await makeController(refresh: { _ in await replaceGate.wait() })
                .replacePlaylistContents(
                    makePlaylist(),
                    with: [],
                    provider: provider
                )
        }
        await replaceGate.waitUntilStarted()
        await fulfillment(of: [replaceCompleted], timeout: 1)
        await replaceGate.open()
        try await replaceTask.value

        let editGate = RefreshGate()
        let editCompleted = expectation(description: "edit returned")
        let editTask = Task {
            defer { editCompleted.fulfill() }
            try await makeController(refresh: { _ in await editGate.wait() })
                .editPlaylistItems(
                    makePlaylist(),
                    originalItems: [],
                    editedItems: [],
                    provider: provider
                )
        }
        await editGate.waitUntilStarted()
        await fulfillment(of: [editCompleted], timeout: 1)
        await editGate.open()
        try await editTask.value
    }

    func testAddPersistsTargetAndDelegatesReconciliation() async throws {
        let provider = RecordingProvider()
        let playlist = makePlaylist()
        var target: Playlist?
        var reconciledMinimum: Int?
        let controller = makeController(
            persistTarget: { target = $0 },
            reconcileAdd: { _, _, _, minimum in reconciledMinimum = minimum }
        )

        let result = try await controller.addTracksToPlaylist(
            [makeTrack(id: "one"), makeTrack(id: "two")],
            playlist: playlist,
            provider: provider
        )

        let events = await provider.recordedEvents()
        XCTAssertEqual(events, ["add:playlist-1:one,two"])
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(target?.id, playlist.id)
        XCTAssertEqual(reconciledMinimum, 2)
    }

    func testRenameRejectsDuplicateBeforeProviderMutation() async throws {
        let provider = RecordingProvider()
        let duplicate = Playlist(
            id: "other",
            key: "/playlists/other",
            title: "Taken",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let controller = makeController(fetchPlaylists: { _ in [duplicate] })

        await XCTAssertThrowsErrorAsync(
            try await controller.renamePlaylist(makePlaylist(), to: "Taken", provider: provider),
            equals: PlaylistMutationError.duplicateName
        )
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testDeleteClearsTargetArtworkAndRefreshes() async throws {
        let provider = RecordingProvider()
        var clearedID: String?
        var artworkIdentity: String?
        var refreshedSource: String?
        let controller = makeController(
            clearTarget: { clearedID = $0.id },
            deleteArtwork: { artworkIdentity = "\($1)|\($0)" },
            refresh: { sourceKey in refreshedSource = sourceKey }
        )

        try await controller.deletePlaylist(makePlaylist(), provider: provider)

        let events = await provider.recordedEvents()
        XCTAssertEqual(events, ["delete:playlist-1"])
        XCTAssertEqual(clearedID, "playlist-1")
        XCTAssertEqual(artworkIdentity, "plex:account-1:server-1|playlist-1")
        XCTAssertEqual(refreshedSource, "plex:account-1:server-1")
    }

    func testReplaceRejectsSourceLessTracks() async throws {
        let provider = RecordingProvider()
        let controller = makeController()

        await XCTAssertThrowsErrorAsync(
            try await controller.replacePlaylistContents(
                makePlaylist(),
                with: [makeTrack(id: "legacy", sourceCompositeKey: nil)],
                provider: provider
            ),
            equals: PlaylistMutationError.emptySelection
        )
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testEditDelegatesMembershipSemanticsToProvider() async throws {
        let provider = RecordingProvider()
        let original = [PlaylistItem(id: "one", playlistItemID: "one", track: makeTrack(id: "one"))]
        let controller = makeController()

        try await controller.editPlaylistItems(
            makePlaylist(),
            originalItems: original,
            editedItems: [],
            provider: provider
        )

        let events = await provider.recordedEvents()
        XCTAssertEqual(events, ["edit:playlist-1:1:0"])
    }
}

private func XCTAssertThrowsErrorAsync<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    equals expectedError: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
