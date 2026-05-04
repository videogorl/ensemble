import Foundation

@MainActor
public protocol PlaylistMutationWorkflowMutating: AnyObject {
    @discardableResult
    func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws -> MutationOutcome

    @discardableResult
    func deletePlaylist(_ playlist: Playlist) async throws -> MutationOutcome
}

extension MutationCoordinator: PlaylistMutationWorkflowMutating {}

public struct PlaylistMutationToastScope: Equatable, Sendable {
    public static let playlist = PlaylistMutationToastScope(dedupePrefix: "playlist")
    public static let sidebarPlaylist = PlaylistMutationToastScope(dedupePrefix: "sidebar-playlist")

    public let dedupePrefix: String

    public init(dedupePrefix: String) {
        self.dedupePrefix = dedupePrefix
    }
}

public struct PlaylistRenameWorkflowStart {
    public let trimmedTitle: String
    public let pendingToast: ToastPayload

    public init(trimmedTitle: String, pendingToast: ToastPayload) {
        self.trimmedTitle = trimmedTitle
        self.pendingToast = pendingToast
    }
}

public struct PlaylistRenameWorkflowResult {
    public let outcome: MutationOutcome
    public let successToast: ToastPayload

    public init(outcome: MutationOutcome, successToast: ToastPayload) {
        self.outcome = outcome
        self.successToast = successToast
    }
}

public struct PlaylistDeleteWorkflowStart {
    public let pendingToast: ToastPayload

    public init(pendingToast: ToastPayload) {
        self.pendingToast = pendingToast
    }
}

public struct PlaylistDeleteWorkflowResult {
    public let outcome: MutationOutcome
    public let successToast: ToastPayload

    public init(outcome: MutationOutcome, successToast: ToastPayload) {
        self.outcome = outcome
        self.successToast = successToast
    }
}

public struct PlaylistBatchMutationWorkflowResult {
    public let succeededCount: Int
    public let totalCount: Int
    public let resultToast: ToastPayload

    public var completedAll: Bool {
        succeededCount == totalCount
    }

    public init(succeededCount: Int, totalCount: Int, resultToast: ToastPayload) {
        self.succeededCount = succeededCount
        self.totalCount = totalCount
        self.resultToast = resultToast
    }
}

/// Shared playlist mutation presentation workflow for root/sidebar/detail UI surfaces.
///
/// The service owns normalization, the mutation call, and toast payload policy. Views still
/// own local navigation, optimistic list state, pin updates, and confirmation presentation.
@MainActor
public final class PlaylistMutationWorkflow {
    private enum Icon {
        static let delete = "trash"
        static let edit = "pencil"
        static let editSuccess = "pencil.circle.fill"
        static let failure = "xmark.octagon.fill"
        static let queued = "clock.arrow.circlepath"
        static let success = "checkmark.circle.fill"
    }

    private let mutator: PlaylistMutationWorkflowMutating

    public init(mutator: PlaylistMutationWorkflowMutating) {
        self.mutator = mutator
    }

    public func beginRename(
        playlist: Playlist,
        to proposedTitle: String,
        scope: PlaylistMutationToastScope = .playlist
    ) -> PlaylistRenameWorkflowStart? {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        return PlaylistRenameWorkflowStart(
            trimmedTitle: trimmedTitle,
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.edit,
                title: "Renaming \(playlist.title)...",
                isPersistent: true,
                dedupeKey: dedupeKey(scope: scope, action: "rename", state: "pending", playlistID: playlist.id),
                showsActivityIndicator: true
            )
        )
    }

    public func finishRename(
        playlist: Playlist,
        trimmedTitle: String,
        scope: PlaylistMutationToastScope = .playlist
    ) async throws -> PlaylistRenameWorkflowResult {
        let outcome = try await mutator.renamePlaylist(playlist, to: trimmedTitle)

        return PlaylistRenameWorkflowResult(
            outcome: outcome,
            successToast: ToastPayload(
                style: outcome == .queued ? .info : .success,
                iconSystemName: outcome == .queued ? Icon.queued : Icon.editSuccess,
                title: outcome == .queued ? "Rename queued — will sync when online" : "Renamed playlist",
                dedupeKey: dedupeKey(scope: scope, action: "rename", state: "success", playlistID: playlist.id)
            )
        )
    }

    public func renameFailureToast(
        playlist: Playlist,
        error: Error,
        scope: PlaylistMutationToastScope = .playlist
    ) -> ToastPayload {
        renameFailureToast(playlist: playlist, errorMessage: error.localizedDescription, scope: scope)
    }

    public func renameFailureToast(
        playlist: Playlist,
        errorMessage: String?,
        scope: PlaylistMutationToastScope = .playlist
    ) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Could not rename playlist",
            message: errorMessage ?? "Try again later.",
            dedupeKey: dedupeKey(scope: scope, action: "rename", state: "error", playlistID: playlist.id)
        )
    }

    public func beginDelete(
        playlist: Playlist,
        scope: PlaylistMutationToastScope = .playlist
    ) -> PlaylistDeleteWorkflowStart? {
        guard !playlist.isSmart else { return nil }

        return PlaylistDeleteWorkflowStart(
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.delete,
                title: "Deleting \(playlist.title)...",
                isPersistent: true,
                dedupeKey: dedupeKey(scope: scope, action: "delete", state: "pending", playlistID: playlist.id),
                showsActivityIndicator: true
            )
        )
    }

    public func finishDelete(
        playlist: Playlist,
        scope: PlaylistMutationToastScope = .playlist
    ) async throws -> PlaylistDeleteWorkflowResult {
        let outcome = try await mutator.deletePlaylist(playlist)

        return PlaylistDeleteWorkflowResult(
            outcome: outcome,
            successToast: ToastPayload(
                style: .success,
                iconSystemName: Icon.success,
                title: "Deleted \(playlist.title)",
                dedupeKey: dedupeKey(scope: scope, action: "delete", state: "success", playlistID: playlist.id)
            )
        )
    }

    public func deleteFailureToast(
        playlist: Playlist,
        errorMessage: String?,
        scope: PlaylistMutationToastScope = .playlist
    ) -> ToastPayload {
        ToastPayload(
            style: .error,
            iconSystemName: Icon.failure,
            title: "Could not delete \(playlist.title)",
            message: errorMessage ?? "Try again later.",
            dedupeKey: dedupeKey(scope: scope, action: "delete", state: "error", playlistID: playlist.id)
        )
    }

    public func deleteFailureToast(
        playlist: Playlist,
        error: Error,
        scope: PlaylistMutationToastScope = .playlist
    ) -> ToastPayload {
        deleteFailureToast(playlist: playlist, errorMessage: error.localizedDescription, scope: scope)
    }

    public func beginRenameAll(
        displayPlaylist: DisplayPlaylist,
        to proposedTitle: String
    ) -> PlaylistRenameWorkflowStart? {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        let count = displayPlaylist.playlists.count
        return PlaylistRenameWorkflowStart(
            trimmedTitle: trimmedTitle,
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.edit,
                title: "Renaming on \(count) server\(count == 1 ? "" : "s")...",
                isPersistent: true,
                dedupeKey: "merged-rename-\(displayPlaylist.id)",
                showsActivityIndicator: true
            )
        )
    }

    public func finishRenameAll(
        displayPlaylist: DisplayPlaylist,
        trimmedTitle: String
    ) async -> PlaylistBatchMutationWorkflowResult {
        var succeededCount = 0
        for playlist in displayPlaylist.playlists {
            do {
                _ = try await mutator.renamePlaylist(playlist, to: trimmedTitle)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist rename failed for \(playlist.id): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.playlists.count
        let style: ToastStyle
        let icon: String
        let title: String
        let message: String?
        if succeededCount == totalCount {
            style = .success
            icon = Icon.editSuccess
            title = "Renamed playlist"
            message = nil
        } else if succeededCount > 0 {
            style = .warning
            icon = Icon.queued
            title = "Renamed on \(succeededCount)/\(totalCount) servers"
            message = "Some copies could not be renamed."
        } else {
            style = .error
            icon = Icon.failure
            title = "Could not rename playlist"
            message = "No copies were renamed."
        }

        return PlaylistBatchMutationWorkflowResult(
            succeededCount: succeededCount,
            totalCount: totalCount,
            resultToast: ToastPayload(
                style: style,
                iconSystemName: icon,
                title: title,
                message: message,
                dedupeKey: "merged-rename-result-\(displayPlaylist.id)"
            )
        )
    }

    public func beginDeleteAll(displayPlaylist: DisplayPlaylist) -> PlaylistDeleteWorkflowStart? {
        guard !displayPlaylist.isSmart else { return nil }

        let count = displayPlaylist.playlists.count
        return PlaylistDeleteWorkflowStart(
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.delete,
                title: "Deleting from \(count) server\(count == 1 ? "" : "s")...",
                isPersistent: true,
                dedupeKey: "merged-delete-\(displayPlaylist.id)",
                showsActivityIndicator: true
            )
        )
    }

    public func finishDeleteAll(
        displayPlaylist: DisplayPlaylist
    ) async -> PlaylistBatchMutationWorkflowResult {
        var succeededCount = 0
        for playlist in displayPlaylist.playlists {
            do {
                _ = try await mutator.deletePlaylist(playlist)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist delete failed for \(playlist.id): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.playlists.count
        let completedAll = succeededCount == totalCount
        return PlaylistBatchMutationWorkflowResult(
            succeededCount: succeededCount,
            totalCount: totalCount,
            resultToast: ToastPayload(
                style: completedAll ? .success : .error,
                iconSystemName: completedAll ? Icon.success : Icon.failure,
                title: completedAll ? "Deleted \(displayPlaylist.title)" : "Could not delete all copies",
                message: completedAll ? nil : "Deleted \(succeededCount)/\(totalCount) copies.",
                dedupeKey: "merged-delete-result-\(displayPlaylist.id)"
            )
        )
    }

    private func dedupeKey(
        scope: PlaylistMutationToastScope,
        action: String,
        state: String,
        playlistID: String
    ) -> String {
        "\(scope.dedupePrefix)-\(action)-\(state)-\(playlistID)"
    }
}
