import XCTest
@testable import EnsembleCore

@MainActor
final class PlaylistMutationControllerTests: XCTestCase {
    private func makeTrack(id: String, title: String = "Track") -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title,
            artistName: "Artist",
            sourceCompositeKey: "plex:account-1:server-1:library-1"
        )
    }

    private func makePlaylist(
        id: String = "playlist-1",
        title: String = "Playlist",
        isSmart: Bool = false,
        sourceCompositeKey: String? = "plex:account-1:server-1"
    ) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)",
            title: title,
            isSmart: isSmart,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeItem(id: String, unavailable: Bool = false) -> PlaylistItem {
        let track = Track(
            id: "track-\(id)",
            key: "/library/metadata/track-\(id)",
            title: "Track \(id)",
            sourceCompositeKey: "plex:account-1:server-1:library-1",
            unavailableReason: unavailable ? "Library not synced" : nil
        )
        return PlaylistItem(
            id: id,
            playlistItemID: id,
            track: track
        )
    }

    func testCreatePlaylistCreatesRemotePersistsTargetAndRefreshes() async throws {
        let refreshExpectation = expectation(description: "refresh")
        var createdTitle: String?
        var createdTrackIDs: [String] = []
        var persistedPlaylist: Playlist?

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { $0 == "plex:account-1:server-1" },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { tracks, _ in tracks.map(\.id) },
                createRemotePlaylist: { title, trackIDs, _ in
                    createdTitle = title
                    createdTrackIDs = trackIDs
                },
                reconcileCreatedPlaylist: { title, trackIDs, sourceKey, _ in
                    Playlist(
                        id: "created-1",
                        key: "/playlists/created-1",
                        title: title,
                        trackCount: trackIDs.count,
                        sourceCompositeKey: sourceKey
                    )
                },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { _, _, _ in },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { playlist in
                    persistedPlaylist = playlist
                },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { _ in
                    refreshExpectation.fulfill()
                }
            )
        )

        let result = try await controller.createPlaylist(
            title: " New Playlist ",
            tracks: [makeTrack(id: "t1"), makeTrack(id: "t2")],
            serverSourceKey: "plex:account-1:server-1"
        )

        XCTAssertEqual(createdTitle, "New Playlist")
        XCTAssertEqual(createdTrackIDs, ["t1", "t2"])
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(persistedPlaylist?.id, "created-1")
        await fulfillment(of: [refreshExpectation], timeout: 1.0)
    }

    func testAddTracksToPlaylistPersistsTargetAndTriggersRefresh() async throws {
        let refreshExpectation = expectation(description: "refresh")
        var addedPlaylistID: String?
        var addedTrackIDs: [String] = []
        var persistedPlaylist: Playlist?

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { tracks, _ in tracks.map(\.id) },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { playlistID, trackIDs, _ in
                    addedPlaylistID = playlistID
                    addedTrackIDs = trackIDs
                },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { _, _, _ in },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { playlist in
                    persistedPlaylist = playlist
                },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { _ in
                    refreshExpectation.fulfill()
                }
            )
        )

        let playlist = makePlaylist()
        let result = try await controller.addTracksToPlaylist(
            [makeTrack(id: "t1"), makeTrack(id: "t2")],
            playlist: playlist
        )

        XCTAssertEqual(addedPlaylistID, "playlist-1")
        XCTAssertEqual(addedTrackIDs, ["t1", "t2"])
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(persistedPlaylist?.id, playlist.id)
        await fulfillment(of: [refreshExpectation], timeout: 1.0)
    }

    func testRenamePlaylistRenamesRemoteAndRefreshes() async throws {
        var renamedPlaylistID: String?
        var renamedTitle: String?
        var refreshedSourceKey: String?

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { _, _ in [] },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { playlistID, newTitle, _ in
                    renamedPlaylistID = playlistID
                    renamedTitle = newTitle
                },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { _, _, _ in },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { _ in },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { sourceKey in
                    refreshedSourceKey = sourceKey
                }
            )
        )

        try await controller.renamePlaylist(makePlaylist(), to: " Renamed Playlist ")

        XCTAssertEqual(renamedPlaylistID, "playlist-1")
        XCTAssertEqual(renamedTitle, "Renamed Playlist")
        XCTAssertEqual(refreshedSourceKey, "plex:account-1:server-1")
    }

    func testDeletePlaylistDeletesRemoteClearsTargetAndRefreshes() async throws {
        var deletedPlaylistID: String?
        var clearedPlaylistID: String?
        var deletedArtworkID: String?
        var refreshedSourceKey: String?

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { _, _ in [] },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { playlistID, _ in
                    deletedPlaylistID = playlistID
                },
                replaceRemotePlaylistContents: { _, _, _ in },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { _ in },
                clearLastPlaylistTargetIfNeeded: { playlist in
                    clearedPlaylistID = playlist.id
                },
                deletePlaylistArtwork: { ratingKey in
                    deletedArtworkID = ratingKey
                },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { sourceKey in
                    refreshedSourceKey = sourceKey
                }
            )
        )

        try await controller.deletePlaylist(makePlaylist())

        XCTAssertEqual(deletedPlaylistID, "playlist-1")
        XCTAssertEqual(clearedPlaylistID, "playlist-1")
        XCTAssertEqual(deletedArtworkID, "playlist-1")
        XCTAssertEqual(refreshedSourceKey, "plex:account-1:server-1")
    }

    func testReplacePlaylistContentsReplacesRemoteAndRefreshes() async throws {
        var replacedPlaylistID: String?
        var replacedTrackIDs: [String] = []
        var refreshedSourceKey: String?

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { tracks, _ in tracks.map(\.id) },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { playlistID, trackIDs, _ in
                    replacedPlaylistID = playlistID
                    replacedTrackIDs = trackIDs
                },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { _ in },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { sourceKey in
                    refreshedSourceKey = sourceKey
                }
            )
        )

        try await controller.replacePlaylistContents(
            makePlaylist(),
            with: [makeTrack(id: "t1"), makeTrack(id: "t2")]
        )

        XCTAssertEqual(replacedPlaylistID, "playlist-1")
        XCTAssertEqual(replacedTrackIDs, ["t1", "t2"])
        XCTAssertEqual(refreshedSourceKey, "plex:account-1:server-1")
    }

    func testReplacePlaylistContentsRejectsNonEmptyEditWhenNoTracksMatchSource() async throws {
        var didReplaceRemote = false
        var didRefresh = false

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { _, _ in [] },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { _, _, _ in
                    didReplaceRemote = true
                },
                removeRemotePlaylistItem: { _, _, _ in },
                moveRemotePlaylistItem: { _, _, _, _ in },
                persistLastPlaylistTarget: { _ in },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { _, _ in },
                refreshServerPlaylists: { _ in
                    didRefresh = true
                }
            )
        )

        do {
            try await controller.replacePlaylistContents(
                makePlaylist(),
                with: [makeTrack(id: "t1")]
            )
            XCTFail("Expected emptySelection")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .emptySelection)
        }

        XCTAssertFalse(didReplaceRemote)
        XCTAssertFalse(didRefresh)
    }

    func testEditPlaylistItemsRemovesAndMovesUnavailableMembershipWithoutReplacingContents() async throws {
        var events: [String] = []
        let original = [
            makeItem(id: "item-a"),
            makeItem(id: "item-b", unavailable: true),
            makeItem(id: "item-c")
        ]
        let edited = [original[2], original[0]]

        let controller = PlaylistMutationController(
            dependencies: .init(
                validateServerSourceKey: { _ in true },
                fetchPlaylists: { _ in [] },
                filteredTrackIDsForServer: { _, _ in [] },
                createRemotePlaylist: { _, _, _ in },
                reconcileCreatedPlaylist: { _, _, _, _ in nil },
                addTracksToRemotePlaylist: { _, _, _ in },
                renameRemotePlaylist: { _, _, _ in },
                deleteRemotePlaylist: { _, _ in },
                replaceRemotePlaylistContents: { _, _, _ in
                    XCTFail("Item edits must not rebuild playlist contents")
                },
                removeRemotePlaylistItem: { playlistID, itemID, _ in
                    events.append("remove:\(playlistID):\(itemID)")
                },
                moveRemotePlaylistItem: { playlistID, itemID, afterID, _ in
                    events.append("move:\(playlistID):\(itemID):\(afterID ?? "first")")
                },
                persistLastPlaylistTarget: { _ in },
                clearLastPlaylistTargetIfNeeded: { _ in },
                deletePlaylistArtwork: { _ in },
                refreshRemotePlaylist: { playlistID, sourceKey in
                    events.append("refresh:\(playlistID):\(sourceKey)")
                },
                refreshServerPlaylists: { _ in
                    XCTFail("Item edits must refresh the mutated playlist directly")
                }
            )
        )

        try await controller.editPlaylistItems(
            makePlaylist(),
            originalItems: original,
            editedItems: edited
        )

        XCTAssertEqual(events, [
            "remove:playlist-1:item-b",
            "move:playlist-1:item-c:first",
            "refresh:playlist-1:plex:account-1:server-1"
        ])
    }
}
