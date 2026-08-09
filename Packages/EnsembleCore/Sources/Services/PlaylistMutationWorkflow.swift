import Foundation

@MainActor
public protocol PlaylistMutationWorkflowMutating: AnyObject {
    func addTracksToPlaylist(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> (PlaylistMutationResult?, MutationOutcome)

    @discardableResult
    func enqueuePlaylistAddOptimistically(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> MutationOutcome

    func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult

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

public struct PlaylistAddWorkflowResult {
    public let mutationResult: PlaylistMutationResult
    public let outcome: MutationOutcome
    public let toast: ToastPayload

    public init(mutationResult: PlaylistMutationResult, outcome: MutationOutcome, toast: ToastPayload) {
        self.mutationResult = mutationResult
        self.outcome = outcome
        self.toast = toast
    }
}

public struct PlaylistOptimisticAddWorkflowResult {
    public let outcome: MutationOutcome
    public let toast: ToastPayload

    public init(outcome: MutationOutcome, toast: ToastPayload) {
        self.outcome = outcome
        self.toast = toast
    }
}

public struct PlaylistCreateWorkflowResult {
    public let mutationResult: PlaylistMutationResult
    public let toast: ToastPayload

    public init(mutationResult: PlaylistMutationResult, toast: ToastPayload) {
        self.mutationResult = mutationResult
        self.toast = toast
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
        static let playlistCreate = "plus.circle.fill"
        static let queued = "clock.arrow.circlepath"
        static let success = "checkmark.circle.fill"
        static let warning = "exclamationmark.triangle.fill"
    }

    private let mutator: PlaylistMutationWorkflowMutating

    public init(mutator: PlaylistMutationWorkflowMutating) {
        self.mutator = mutator
    }

    public func addTracks(
        _ tracks: [Track],
        to playlist: Playlist,
        tapHandler: (() -> Void)? = nil
    ) async throws -> PlaylistAddWorkflowResult {
        let (resultOrNil, outcome) = try await mutator.addTracksToPlaylist(tracks, playlist: playlist)

        if outcome == .queued {
            return PlaylistAddWorkflowResult(
                mutationResult: PlaylistMutationResult(addedCount: 0, skippedCount: 0),
                outcome: outcome,
                toast: queuedAddToast(playlist: playlist)
            )
        }

        let result = resultOrNil ?? PlaylistMutationResult(addedCount: 0, skippedCount: 0)
        return PlaylistAddWorkflowResult(
            mutationResult: result,
            outcome: outcome,
            toast: addToast(playlist: playlist, result: result, tapHandler: tapHandler)
        )
    }

    public func addTracksOptimistically(
        _ tracks: [Track],
        to playlist: Playlist,
        tapHandler: (() -> Void)? = nil
    ) async throws -> PlaylistOptimisticAddWorkflowResult {
        guard !tracks.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let outcome = try await mutator.enqueuePlaylistAddOptimistically(tracks, playlist: playlist)
        return PlaylistOptimisticAddWorkflowResult(
            outcome: outcome,
            toast: optimisticAddToast(
                playlist: playlist,
                addedCount: tracks.count,
                outcome: outcome,
                tapHandler: tapHandler
            )
        )
    }

    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistCreateWorkflowResult {
        let result = try await mutator.createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )

        return PlaylistCreateWorkflowResult(
            mutationResult: result,
            toast: createToast(title: title, result: result)
        )
    }

    public func createPlaylists(
        title: String,
        tracks: [Track],
        serverSourceKeys: [String]
    ) async -> PlaylistBatchMutationWorkflowResult {
        var succeededCount = 0
        for sourceKey in serverSourceKeys {
            do {
                _ = try await mutator.createPlaylist(
                    title: title,
                    tracks: tracks,
                    serverSourceKey: sourceKey
                )
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Playlist creation failed for \(sourceKey): \(error.localizedDescription)")
            }
        }

        let totalCount = serverSourceKeys.count
        let completedAll = succeededCount == totalCount
        return PlaylistBatchMutationWorkflowResult(
            succeededCount: succeededCount,
            totalCount: totalCount,
            resultToast: ToastPayload(
                style: completedAll ? .success : (succeededCount > 0 ? .warning : .error),
                iconSystemName: completedAll ? Icon.playlistCreate : Icon.failure,
                title: completedAll ? "Created \(title)" : "Created on \(succeededCount)/\(totalCount) sources",
                message: completedAll ? nil : "Some sources could not create this playlist.",
                dedupeKey: "playlist-create-all-\(title.lowercased())"
            )
        )
    }

    public func beginRename(
        playlist: Playlist,
        to proposedTitle: String,
        scope: PlaylistMutationToastScope = .playlist
    ) -> PlaylistRenameWorkflowStart? {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, playlist.supportsPlaylistEditing else { return nil }

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
        guard playlist.supportsPlaylistDeletion else { return nil }

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
        guard !trimmedTitle.isEmpty, !displayPlaylist.editablePlaylists.isEmpty else { return nil }

        let count = displayPlaylist.editablePlaylists.count
        return PlaylistRenameWorkflowStart(
            trimmedTitle: trimmedTitle,
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.edit,
                title: "Renaming on \(count) source\(count == 1 ? "" : "s")...",
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
        for playlist in displayPlaylist.editablePlaylists {
            do {
                _ = try await mutator.renamePlaylist(playlist, to: trimmedTitle)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist rename failed for \(playlist.id): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.editablePlaylists.count
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
            title = "Renamed on \(succeededCount)/\(totalCount) sources"
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
        guard !displayPlaylist.deletablePlaylists.isEmpty else { return nil }

        let count = displayPlaylist.deletablePlaylists.count
        return PlaylistDeleteWorkflowStart(
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: Icon.delete,
                title: "Deleting from \(count) source\(count == 1 ? "" : "s")...",
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
        for playlist in displayPlaylist.deletablePlaylists {
            do {
                _ = try await mutator.deletePlaylist(playlist)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist delete failed for \(playlist.id): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.deletablePlaylists.count
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

    private func queuedAddToast(playlist: Playlist) -> ToastPayload {
        ToastPayload(
            style: .info,
            iconSystemName: Icon.queued,
            title: "Queued for \(playlist.title)",
            message: "Will be added when back online.",
            dedupeKey: "playlist-add-queued-\(playlist.id)"
        )
    }

    private func addToast(
        playlist: Playlist,
        result: PlaylistMutationResult,
        tapHandler: (() -> Void)?
    ) -> ToastPayload {
        if result.skippedCount > 0 {
            return ToastPayload(
                style: .warning,
                iconSystemName: Icon.warning,
                title: "Added to \(playlist.title)",
                message: "Added \(result.addedCount), skipped \(result.skippedCount) incompatible.",
                tapHandler: tapHandler,
                dedupeKey: "playlist-add-\(playlist.id)"
            )
        }

        return ToastPayload(
            style: .success,
            iconSystemName: Icon.success,
            title: "Added to \(playlist.title)",
            message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
            tapHandler: tapHandler,
            dedupeKey: "playlist-add-\(playlist.id)"
        )
    }

    private func optimisticAddToast(
        playlist: Playlist,
        addedCount: Int,
        outcome: MutationOutcome,
        tapHandler: (() -> Void)?
    ) -> ToastPayload {
        if outcome == .queued {
            return queuedAddToast(playlist: playlist)
        }

        return ToastPayload(
            style: .success,
            iconSystemName: Icon.success,
            title: "Added to \(playlist.title)",
            message: addedCount == 1 ? "1 track queued for sync." : "\(addedCount) tracks queued for sync.",
            tapHandler: tapHandler,
            dedupeKey: "playlist-add-optimistic-\(playlist.id)"
        )
    }

    private func createToast(title: String, result: PlaylistMutationResult) -> ToastPayload {
        if result.skippedCount > 0 {
            return ToastPayload(
                style: .warning,
                iconSystemName: Icon.playlistCreate,
                title: "Created \(title)",
                message: "Added \(result.addedCount), skipped \(result.skippedCount).",
                dedupeKey: "playlist-create-\(title.lowercased())"
            )
        }

        return ToastPayload(
            style: .success,
            iconSystemName: Icon.playlistCreate,
            title: "Created \(title)",
            message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
            dedupeKey: "playlist-create-\(title.lowercased())"
        )
    }
}
