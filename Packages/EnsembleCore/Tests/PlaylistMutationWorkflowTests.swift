import XCTest
@testable import EnsembleCore

@MainActor
final class PlaylistMutationWorkflowTests: XCTestCase {
    private final class StubMutator: PlaylistMutationWorkflowMutating {
        var renameOutcome: MutationOutcome = .completed
        var deleteOutcome: MutationOutcome = .completed
        var addOutcome: MutationOutcome = .completed
        var optimisticAddOutcome: MutationOutcome = .completed
        var addResult: PlaylistMutationResult? = PlaylistMutationResult(addedCount: 1, skippedCount: 0)
        var createResult = PlaylistMutationResult(addedCount: 1, skippedCount: 0)
        var renameError: Error?
        var deleteError: Error?
        var renameErrorIDs: Set<String> = []
        var deleteErrorIDs: Set<String> = []
        var createErrorSourceKeys: Set<String> = []
        private(set) var renamedPlaylistID: String?
        private(set) var renamedPlaylistIDs: [String] = []
        private(set) var renamedTitle: String?
        private(set) var deletedPlaylistID: String?
        private(set) var deletedPlaylistIDs: [String] = []
        private(set) var addedPlaylistID: String?
        private(set) var addedTrackIDs: [String] = []
        private(set) var optimisticAddedPlaylistID: String?
        private(set) var createdPlaylistTitle: String?
        private(set) var createdPlaylistServerSourceKey: String?
        private(set) var createdPlaylistServerSourceKeys: [String] = []

        func addTracksToPlaylist(
            _ tracks: [Track],
            playlist: Playlist
        ) async throws -> (PlaylistMutationResult?, MutationOutcome) {
            addedPlaylistID = playlist.id
            addedTrackIDs = tracks.map(\.id)
            return (addResult, addOutcome)
        }

        func enqueuePlaylistAddOptimistically(
            _ tracks: [Track],
            playlist: Playlist
        ) async throws -> MutationOutcome {
            optimisticAddedPlaylistID = playlist.id
            addedTrackIDs = tracks.map(\.id)
            return optimisticAddOutcome
        }

        func createPlaylist(
            title: String,
            tracks: [Track],
            serverSourceKey: String
        ) async throws -> PlaylistMutationResult {
            if createErrorSourceKeys.contains(serverSourceKey) {
                throw TestError.failed
            }
            createdPlaylistTitle = title
            createdPlaylistServerSourceKey = serverSourceKey
            createdPlaylistServerSourceKeys.append(serverSourceKey)
            addedTrackIDs = tracks.map(\.id)
            return createResult
        }

        func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws -> MutationOutcome {
            if renameErrorIDs.contains(playlist.id) {
                throw TestError.failed
            }
            if let renameError {
                throw renameError
            }
            renamedPlaylistID = playlist.id
            renamedPlaylistIDs.append(playlist.id)
            renamedTitle = newTitle
            return renameOutcome
        }

        func deletePlaylist(_ playlist: Playlist) async throws -> MutationOutcome {
            if deleteErrorIDs.contains(playlist.id) {
                throw TestError.failed
            }
            if let deleteError {
                throw deleteError
            }
            deletedPlaylistID = playlist.id
            deletedPlaylistIDs.append(playlist.id)
            return deleteOutcome
        }
    }

    private enum TestError: LocalizedError {
        case failed

        var errorDescription: String? {
            "Request failed"
        }
    }

    func testBeginRenameTrimsTitleAndBuildsPendingToast() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())
        let playlist = makePlaylist(title: "Road Trip")

        let start = workflow.beginRename(
            playlist: playlist,
            to: "  Night Drive  ",
            scope: .sidebarPlaylist
        )

        XCTAssertEqual(start?.trimmedTitle, "Night Drive")
        XCTAssertEqual(start?.pendingToast.style, .info)
        XCTAssertEqual(start?.pendingToast.iconSystemName, "pencil")
        XCTAssertEqual(start?.pendingToast.title, "Renaming Road Trip...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "sidebar-playlist-rename-pending-playlist-1")
        XCTAssertTrue(start?.pendingToast.isPersistent == true)
        XCTAssertTrue(start?.pendingToast.showsActivityIndicator == true)
    }

    func testAddTracksBuildsSuccessToastAndTapHandler() async throws {
        let stub = StubMutator()
        stub.addResult = PlaylistMutationResult(addedCount: 2, skippedCount: 0)
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let playlist = makePlaylist(title: "Road Trip")
        var didTap = false

        let result = try await workflow.addTracks(
            [makeTrack(id: "track-1"), makeTrack(id: "track-2")],
            to: playlist,
            tapHandler: { didTap = true }
        )

        XCTAssertEqual(stub.addedPlaylistID, playlist.id)
        XCTAssertEqual(stub.addedTrackIDs, ["track-1", "track-2"])
        XCTAssertEqual(result.mutationResult.addedCount, 2)
        XCTAssertEqual(result.toast.style, .success)
        XCTAssertEqual(result.toast.title, "Added to Road Trip")
        XCTAssertEqual(result.toast.message, "2 tracks added.")
        result.toast.tapHandler?()
        XCTAssertTrue(didTap)
    }

    func testAddTracksBuildsQueuedToast() async throws {
        let stub = StubMutator()
        stub.addOutcome = .queued
        stub.addResult = nil
        let workflow = PlaylistMutationWorkflow(mutator: stub)

        let result = try await workflow.addTracks(
            [makeTrack()],
            to: makePlaylist(title: "Road Trip")
        )

        XCTAssertEqual(result.outcome, .queued)
        XCTAssertEqual(result.mutationResult.addedCount, 0)
        XCTAssertEqual(result.toast.style, .info)
        XCTAssertEqual(result.toast.iconSystemName, "clock.arrow.circlepath")
        XCTAssertEqual(result.toast.title, "Queued for Road Trip")
    }

    func testOptimisticAddRejectsEmptySelectionAndBuildsCompletedToast() async throws {
        let stub = StubMutator()
        let workflow = PlaylistMutationWorkflow(mutator: stub)

        do {
            _ = try await workflow.addTracksOptimistically([], to: makePlaylist())
            XCTFail("Expected empty-selection failure")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .emptySelection)
        }

        let result = try await workflow.addTracksOptimistically(
            [makeTrack(id: "track-1")],
            to: makePlaylist(title: "Road Trip")
        )

        XCTAssertEqual(stub.optimisticAddedPlaylistID, "playlist-1")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.toast.style, .success)
        XCTAssertEqual(result.toast.message, "1 track queued for sync.")
    }

    func testCreatePlaylistBuildsWarningToastForSkippedTracks() async throws {
        let stub = StubMutator()
        stub.createResult = PlaylistMutationResult(addedCount: 3, skippedCount: 1)
        let workflow = PlaylistMutationWorkflow(mutator: stub)

        let result = try await workflow.createPlaylist(
            title: "New Mix",
            tracks: [makeTrack()],
            serverSourceKey: "plex:account:server"
        )

        XCTAssertEqual(stub.createdPlaylistTitle, "New Mix")
        XCTAssertEqual(stub.createdPlaylistServerSourceKey, "plex:account:server")
        XCTAssertEqual(result.mutationResult.skippedCount, 1)
        XCTAssertEqual(result.toast.style, .warning)
        XCTAssertEqual(result.toast.title, "Created New Mix")
        XCTAssertEqual(result.toast.message, "Added 3, skipped 1.")
    }

    func testCreatePlaylistsRunsEverySourceAndReportsPartialSuccess() async {
        let stub = StubMutator()
        stub.createErrorSourceKeys = ["plex:account:offline"]
        let workflow = PlaylistMutationWorkflow(mutator: stub)

        let result = await workflow.createPlaylists(
            title: "Mixed Queue",
            tracks: [makeTrack(id: "one"), makeTrack(id: "two")],
            serverSourceKeys: [
                "plex:account:server",
                "plex:account:offline",
                MusicSourceIdentifier.appleMusic.compositeKey
            ]
        )

        XCTAssertEqual(stub.createdPlaylistServerSourceKeys, [
            "plex:account:server",
            MusicSourceIdentifier.appleMusic.compositeKey
        ])
        XCTAssertEqual(result.succeededCount, 2)
        XCTAssertEqual(result.totalCount, 3)
        XCTAssertEqual(result.resultToast.style, .warning)
    }

    func testBeginRenameRejectsEmptyTitle() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())

        let start = workflow.beginRename(playlist: makePlaylist(), to: "   ")

        XCTAssertNil(start)
    }

    func testBeginRenameRejectsApplePlaylistNotCreatedByEnsemble() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())
        let playlist = Playlist(
            id: "external-apple-playlist",
            key: "external-apple-playlist",
            title: "Playlist",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: true,
                canRename: false,
                canReorder: false,
                canDelete: false
            )
        )

        XCTAssertNil(workflow.beginRename(playlist: playlist, to: "Renamed"))
        XCTAssertTrue(playlist.supportsPlaylistTrackAdds)
    }

    func testFinishRenameCallsMutatorAndBuildsCompletedToast() async throws {
        let stub = StubMutator()
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let playlist = makePlaylist()

        let result = try await workflow.finishRename(
            playlist: playlist,
            trimmedTitle: "Renamed",
            scope: .playlist
        )

        XCTAssertEqual(stub.renamedPlaylistID, "playlist-1")
        XCTAssertEqual(stub.renamedTitle, "Renamed")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.successToast.style, .success)
        XCTAssertEqual(result.successToast.iconSystemName, "pencil.circle.fill")
        XCTAssertEqual(result.successToast.title, "Renamed playlist")
        XCTAssertEqual(result.successToast.dedupeKey, "playlist-rename-success-playlist-1")
    }

    func testFinishRenameBuildsQueuedToast() async throws {
        let stub = StubMutator()
        stub.renameOutcome = .queued
        let workflow = PlaylistMutationWorkflow(mutator: stub)

        let result = try await workflow.finishRename(
            playlist: makePlaylist(),
            trimmedTitle: "Renamed",
            scope: .playlist
        )

        XCTAssertEqual(result.outcome, .queued)
        XCTAssertEqual(result.successToast.style, .info)
        XCTAssertEqual(result.successToast.iconSystemName, "clock.arrow.circlepath")
        XCTAssertEqual(result.successToast.title, "Rename queued — will sync when online")
    }

    func testRenameFailureToastUsesLocalizedErrorAndScope() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())

        let toast = workflow.renameFailureToast(
            playlist: makePlaylist(),
            error: TestError.failed,
            scope: .sidebarPlaylist
        )

        XCTAssertEqual(toast.style, .error)
        XCTAssertEqual(toast.iconSystemName, "xmark.octagon.fill")
        XCTAssertEqual(toast.title, "Could not rename playlist")
        XCTAssertEqual(toast.message, "Request failed")
        XCTAssertEqual(toast.dedupeKey, "sidebar-playlist-rename-error-playlist-1")
    }

    func testDeleteWorkflowRejectsSmartPlaylist() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())

        let start = workflow.beginDelete(playlist: makePlaylist(isSmart: true))

        XCTAssertNil(start)
    }

    func testDeleteWorkflowBuildsToastsAndCallsMutator() async throws {
        let stub = StubMutator()
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let playlist = makePlaylist(title: "Road Trip")

        let start = workflow.beginDelete(playlist: playlist, scope: .sidebarPlaylist)
        let result = try await workflow.finishDelete(playlist: playlist, scope: .sidebarPlaylist)

        XCTAssertEqual(start?.pendingToast.iconSystemName, "trash")
        XCTAssertEqual(start?.pendingToast.title, "Deleting Road Trip...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "sidebar-playlist-delete-pending-playlist-1")
        XCTAssertEqual(stub.deletedPlaylistID, "playlist-1")
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.successToast.style, .success)
        XCTAssertEqual(result.successToast.iconSystemName, "checkmark.circle.fill")
        XCTAssertEqual(result.successToast.title, "Deleted Road Trip")
        XCTAssertEqual(result.successToast.dedupeKey, "sidebar-playlist-delete-success-playlist-1")
    }

    func testDeleteFailureToastUsesFallbackMessage() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())

        let toast = workflow.deleteFailureToast(
            playlist: makePlaylist(title: "Road Trip"),
            errorMessage: nil,
            scope: .playlist
        )

        XCTAssertEqual(toast.style, .error)
        XCTAssertEqual(toast.iconSystemName, "xmark.octagon.fill")
        XCTAssertEqual(toast.title, "Could not delete Road Trip")
        XCTAssertEqual(toast.message, "Try again later.")
        XCTAssertEqual(toast.dedupeKey, "playlist-delete-error-playlist-1")
    }

    func testMergedRenameAllBuildsPendingAndStrictPartialResultToasts() async {
        let stub = StubMutator()
        stub.renameErrorIDs = ["playlist-2"]
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let displayPlaylist = makeDisplayPlaylist()

        let start = workflow.beginRenameAll(displayPlaylist: displayPlaylist, to: "  New Mix  ")
        let result = await workflow.finishRenameAll(
            displayPlaylist: displayPlaylist,
            trimmedTitle: start?.trimmedTitle ?? ""
        )

        XCTAssertEqual(start?.trimmedTitle, "New Mix")
        XCTAssertEqual(start?.pendingToast.title, "Renaming on 2 sources...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "merged-rename-display-1")
        XCTAssertEqual(stub.renamedPlaylistIDs, ["playlist-1"])
        XCTAssertFalse(result.completedAll)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.resultToast.style, .warning)
        XCTAssertEqual(result.resultToast.title, "Renamed on 1/2 sources")
        XCTAssertEqual(result.resultToast.dedupeKey, "merged-rename-result-display-1")
    }

    func testMergedDeleteAllRequiresEveryCopyToSucceed() async {
        let stub = StubMutator()
        stub.deleteErrorIDs = ["playlist-2"]
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let displayPlaylist = makeDisplayPlaylist(title: "Road Trip")

        let start = workflow.beginDeleteAll(displayPlaylist: displayPlaylist)
        let result = await workflow.finishDeleteAll(displayPlaylist: displayPlaylist)

        XCTAssertEqual(start?.pendingToast.title, "Deleting from 2 sources...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "merged-delete-display-1")
        XCTAssertEqual(stub.deletedPlaylistIDs, ["playlist-1"])
        XCTAssertFalse(result.completedAll)
        XCTAssertEqual(result.resultToast.style, .error)
        XCTAssertEqual(result.resultToast.title, "Could not delete all copies")
        XCTAssertEqual(result.resultToast.message, "Deleted 1/2 copies.")
        XCTAssertEqual(result.resultToast.dedupeKey, "merged-delete-result-display-1")
    }

    func testMergedMutationsSkipSmartAndAppleDeletionUnsupportedConstituents() async {
        let stub = StubMutator()
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let appleUserCapabilities = PlaylistActionCapabilities(
            canAddItems: true,
            canRename: true,
            canReorder: true,
            canDelete: false
        )
        let displayPlaylist = DisplayPlaylist(
            id: "mixed",
            title: "Ambient Electric",
            isSmart: true,
            playlists: [
                makePlaylist(id: "apple-editorial", title: "Ambient Electric", isSmart: true, sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
                makePlaylist(
                    id: "apple-user",
                    title: "Ambient Electric",
                    sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey,
                    actionCapabilities: appleUserCapabilities
                ),
                makePlaylist(id: "plex", title: "Ambient Electric")
            ]
        )

        let rename = await workflow.finishRenameAll(displayPlaylist: displayPlaylist, trimmedTitle: "Ambient")
        let delete = await workflow.finishDeleteAll(displayPlaylist: displayPlaylist)

        XCTAssertEqual(stub.renamedPlaylistIDs, ["apple-user", "plex"])
        XCTAssertEqual(rename.totalCount, 2)
        XCTAssertEqual(stub.deletedPlaylistIDs, ["plex"])
        XCTAssertEqual(delete.totalCount, 1)
    }

    private func makePlaylist(
        id: String = "playlist-1",
        title: String = "Playlist",
        isSmart: Bool = false,
        sourceCompositeKey: String = "plex:account-1:server-1",
        actionCapabilities: PlaylistActionCapabilities? = nil
    ) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)",
            title: title,
            isSmart: isSmart,
            sourceCompositeKey: sourceCompositeKey,
            actionCapabilities: actionCapabilities
        )
    }

    private func makeTrack(id: String = "track-1") -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: "Track \(id)",
            sourceCompositeKey: "plex:account-1:server-1:library-1"
        )
    }

    private func makeDisplayPlaylist(
        id: String = "display-1",
        title: String = "Playlist"
    ) -> DisplayPlaylist {
        DisplayPlaylist(
            id: id,
            title: title,
            isSmart: false,
            playlists: [
                makePlaylist(id: "playlist-1", title: title),
                makePlaylist(id: "playlist-2", title: title)
            ]
        )
    }
}
