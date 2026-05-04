import XCTest
@testable import EnsembleCore

@MainActor
final class PlaylistMutationWorkflowTests: XCTestCase {
    private final class StubMutator: PlaylistMutationWorkflowMutating {
        var renameOutcome: MutationOutcome = .completed
        var deleteOutcome: MutationOutcome = .completed
        var renameError: Error?
        var deleteError: Error?
        var renameErrorIDs: Set<String> = []
        var deleteErrorIDs: Set<String> = []
        private(set) var renamedPlaylistID: String?
        private(set) var renamedPlaylistIDs: [String] = []
        private(set) var renamedTitle: String?
        private(set) var deletedPlaylistID: String?
        private(set) var deletedPlaylistIDs: [String] = []

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

    func testBeginRenameRejectsEmptyTitle() {
        let workflow = PlaylistMutationWorkflow(mutator: StubMutator())

        let start = workflow.beginRename(playlist: makePlaylist(), to: "   ")

        XCTAssertNil(start)
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
        XCTAssertEqual(start?.pendingToast.title, "Renaming on 2 servers...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "merged-rename-display-1")
        XCTAssertEqual(stub.renamedPlaylistIDs, ["playlist-1"])
        XCTAssertFalse(result.completedAll)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.totalCount, 2)
        XCTAssertEqual(result.resultToast.style, .warning)
        XCTAssertEqual(result.resultToast.title, "Renamed on 1/2 servers")
        XCTAssertEqual(result.resultToast.dedupeKey, "merged-rename-result-display-1")
    }

    func testMergedDeleteAllRequiresEveryCopyToSucceed() async {
        let stub = StubMutator()
        stub.deleteErrorIDs = ["playlist-2"]
        let workflow = PlaylistMutationWorkflow(mutator: stub)
        let displayPlaylist = makeDisplayPlaylist(title: "Road Trip")

        let start = workflow.beginDeleteAll(displayPlaylist: displayPlaylist)
        let result = await workflow.finishDeleteAll(displayPlaylist: displayPlaylist)

        XCTAssertEqual(start?.pendingToast.title, "Deleting from 2 servers...")
        XCTAssertEqual(start?.pendingToast.dedupeKey, "merged-delete-display-1")
        XCTAssertEqual(stub.deletedPlaylistIDs, ["playlist-1"])
        XCTAssertFalse(result.completedAll)
        XCTAssertEqual(result.resultToast.style, .error)
        XCTAssertEqual(result.resultToast.title, "Could not delete all copies")
        XCTAssertEqual(result.resultToast.message, "Deleted 1/2 copies.")
        XCTAssertEqual(result.resultToast.dedupeKey, "merged-delete-result-display-1")
    }

    private func makePlaylist(
        id: String = "playlist-1",
        title: String = "Playlist",
        isSmart: Bool = false
    ) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)",
            title: title,
            isSmart: isSmart,
            sourceCompositeKey: "plex:account-1:server-1"
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
