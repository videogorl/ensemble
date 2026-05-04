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

    private func dedupeKey(
        scope: PlaylistMutationToastScope,
        action: String,
        state: String,
        playlistID: String
    ) -> String {
        "\(scope.dedupePrefix)-\(action)-\(state)-\(playlistID)"
    }
}
