import Foundation

public enum PlaylistMutationToastScope: String, Sendable {
    case playlist
    case sidebarPlaylist = "sidebar-playlist"
}

public struct PlaylistBatchMutationResult {
    public let succeededCount: Int
    public let totalCount: Int
    public let failedSourceKeys: [String]
    public let resultToast: ToastPayload

    public var completedAll: Bool {
        succeededCount == totalCount
    }

    public init(
        succeededCount: Int,
        totalCount: Int,
        failedSourceKeys: [String] = [],
        resultToast: ToastPayload
    ) {
        self.succeededCount = succeededCount
        self.totalCount = totalCount
        self.failedSourceKeys = failedSourceKeys
        self.resultToast = resultToast
    }
}

extension MutationCoordinator {
    private enum PlaylistIcon {
        static let delete = "trash"
        static let edit = "pencil"
        static let editSuccess = "pencil.circle.fill"
        static let failure = "xmark.octagon.fill"
        static let playlistCreate = "plus.circle.fill"
        static let queued = "clock.arrow.circlepath"
        static let success = "checkmark.circle.fill"
        static let warning = "exclamationmark.triangle.fill"
    }

    public func addTracks(
        _ tracks: [Track],
        to playlist: Playlist,
        openPlaylist: (() -> Void)? = nil
    ) async throws -> (mutationResult: PlaylistMutationResult, outcome: MutationOutcome, toast: ToastPayload) {
        let (resultOrNil, outcome) = try await addTracksToPlaylist(tracks, playlist: playlist)

        if outcome == .queued {
            return (
                mutationResult: PlaylistMutationResult(addedCount: 0, skippedCount: 0),
                outcome: outcome,
                toast: queuedAddToast(playlist: playlist)
            )
        }

        let result = resultOrNil ?? PlaylistMutationResult(addedCount: 0, skippedCount: 0)
        return (
            mutationResult: result,
            outcome: outcome,
            toast: addToast(playlist: playlist, result: result, openPlaylist: openPlaylist)
        )
    }

    public func addTracksOptimistically(
        _ tracks: [Track],
        to playlist: Playlist,
        openPlaylist: (() -> Void)? = nil
    ) async throws -> (outcome: MutationOutcome, toast: ToastPayload) {
        guard !tracks.isEmpty else {
            throw PlaylistMutationError.emptySelection
        }

        let outcome = try await enqueuePlaylistAddOptimistically(tracks, playlist: playlist)
        return (
            outcome: outcome,
            toast: optimisticAddToast(
                playlist: playlist,
                addedCount: tracks.count,
                outcome: outcome,
                openPlaylist: openPlaylist
            )
        )
    }

    public func createPlaylistWithFeedback(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> (mutationResult: PlaylistMutationResult, toast: ToastPayload) {
        let result = try await createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )

        return (
            mutationResult: result,
            toast: createToast(title: title, serverSourceKey: serverSourceKey, result: result)
        )
    }

    public func createPlaylists(
        title: String,
        tracks: [Track],
        serverSourceKeys: [String],
        createPlaylist: ((String) async throws -> Void)? = nil,
        retryHandler: (([String]) -> Void)? = nil
    ) async -> PlaylistBatchMutationResult {
        var succeededCount = 0
        var failedSourceKeys: [String] = []
        for sourceKey in serverSourceKeys {
            do {
                if let createPlaylist {
                    try await createPlaylist(sourceKey)
                } else {
                    _ = try await self.createPlaylist(
                        title: title,
                        tracks: tracks,
                        serverSourceKey: sourceKey
                    )
                }
                succeededCount += 1
            } catch {
                failedSourceKeys.append(sourceKey)
                EnsembleLogger.debug("Playlist creation failed for \(sourceKey): \(error.localizedDescription)")
            }
        }

        let totalCount = serverSourceKeys.count
        let completedAll = succeededCount == totalCount
        return PlaylistBatchMutationResult(
            succeededCount: succeededCount,
            totalCount: totalCount,
            failedSourceKeys: failedSourceKeys,
            resultToast: ToastPayload(
                style: completedAll ? .success : (succeededCount > 0 ? .warning : .error),
                iconSystemName: completedAll ? PlaylistIcon.playlistCreate : PlaylistIcon.failure,
                title: completedAll ? "Created \(title)" : "Created on \(succeededCount)/\(totalCount) sources",
                message: completedAll ? nil : "Some sources could not create this playlist.",
                action: failedSourceKeys.isEmpty || retryHandler == nil ? nil : ToastAction(title: "Retry") {
                    retryHandler?(failedSourceKeys)
                },
                isPersistent: !completedAll,
                dedupeKey: "playlist-create-all-\(serverSourceKeys.sorted().joined(separator: ","))-\(title.lowercased())"
            )
        )
    }

    public func beginRename(
        playlist: Playlist,
        to proposedTitle: String,
        scope: PlaylistMutationToastScope = .playlist
    ) -> (trimmedTitle: String, pendingToast: ToastPayload)? {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, playlist.supportsPlaylistEditing else { return nil }

        return (
            trimmedTitle: trimmedTitle,
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: PlaylistIcon.edit,
                title: "Renaming \(playlist.title)...",
                isPersistent: true,
                dedupeKey: dedupeKey(scope: scope, action: "rename", state: "pending", playlistID: playlist.sourceScopedID),
                showsActivityIndicator: true
            )
        )
    }

    public func finishRename(
        playlist: Playlist,
        trimmedTitle: String,
        scope: PlaylistMutationToastScope = .playlist
    ) async throws -> (outcome: MutationOutcome, successToast: ToastPayload) {
        let outcome = try await renamePlaylist(playlist, to: trimmedTitle)

        return (
            outcome: outcome,
            successToast: ToastPayload(
                style: outcome == .queued ? .info : .success,
                iconSystemName: outcome == .queued ? PlaylistIcon.queued : PlaylistIcon.editSuccess,
                title: outcome == .queued ? "Rename queued — will sync when online" : "Renamed playlist",
                dedupeKey: dedupeKey(scope: scope, action: "rename", state: "success", playlistID: playlist.sourceScopedID)
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
            iconSystemName: PlaylistIcon.failure,
            title: "Could not rename playlist",
            message: errorMessage ?? "Try again later.",
            dedupeKey: dedupeKey(scope: scope, action: "rename", state: "error", playlistID: playlist.sourceScopedID)
        )
    }

    public func beginDelete(
        playlist: Playlist,
        scope: PlaylistMutationToastScope = .playlist
    ) -> ToastPayload? {
        guard playlist.supportsPlaylistDeletion else { return nil }

        return ToastPayload(
            style: .info,
            iconSystemName: PlaylistIcon.delete,
            title: "Deleting \(playlist.title)...",
            isPersistent: true,
            dedupeKey: dedupeKey(scope: scope, action: "delete", state: "pending", playlistID: playlist.sourceScopedID),
            showsActivityIndicator: true
        )
    }

    public func finishDelete(
        playlist: Playlist,
        scope: PlaylistMutationToastScope = .playlist
    ) async throws -> (outcome: MutationOutcome, successToast: ToastPayload) {
        let outcome = try await deletePlaylist(playlist)

        return (
            outcome: outcome,
            successToast: ToastPayload(
                style: .success,
                iconSystemName: PlaylistIcon.success,
                title: "Deleted \(playlist.title)",
                dedupeKey: dedupeKey(scope: scope, action: "delete", state: "success", playlistID: playlist.sourceScopedID)
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
            iconSystemName: PlaylistIcon.failure,
            title: "Could not delete \(playlist.title)",
            message: errorMessage ?? "Try again later.",
            dedupeKey: dedupeKey(scope: scope, action: "delete", state: "error", playlistID: playlist.sourceScopedID)
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
    ) -> (trimmedTitle: String, pendingToast: ToastPayload)? {
        let trimmedTitle = proposedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !displayPlaylist.editablePlaylists.isEmpty else { return nil }

        let count = displayPlaylist.editablePlaylists.count
        return (
            trimmedTitle: trimmedTitle,
            pendingToast: ToastPayload(
                style: .info,
                iconSystemName: PlaylistIcon.edit,
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
    ) async -> PlaylistBatchMutationResult {
        var succeededCount = 0
        for playlist in displayPlaylist.editablePlaylists {
            do {
                _ = try await renamePlaylist(playlist, to: trimmedTitle)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist rename failed for \(playlist.sourceScopedID): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.editablePlaylists.count
        let style: ToastStyle
        let icon: String
        let title: String
        let message: String?
        if succeededCount == totalCount {
            style = .success
            icon = PlaylistIcon.editSuccess
            title = "Renamed playlist"
            message = nil
        } else if succeededCount > 0 {
            style = .warning
            icon = PlaylistIcon.queued
            title = "Renamed on \(succeededCount)/\(totalCount) sources"
            message = "Some copies could not be renamed."
        } else {
            style = .error
            icon = PlaylistIcon.failure
            title = "Could not rename playlist"
            message = "No copies were renamed."
        }

        return PlaylistBatchMutationResult(
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

    public func beginDeleteAll(displayPlaylist: DisplayPlaylist) -> ToastPayload? {
        guard !displayPlaylist.deletablePlaylists.isEmpty else { return nil }

        let count = displayPlaylist.deletablePlaylists.count
        return ToastPayload(
            style: .info,
            iconSystemName: PlaylistIcon.delete,
            title: "Deleting from \(count) source\(count == 1 ? "" : "s")...",
            isPersistent: true,
            dedupeKey: "merged-delete-\(displayPlaylist.id)",
            showsActivityIndicator: true
        )
    }

    public func finishDeleteAll(
        displayPlaylist: DisplayPlaylist
    ) async -> PlaylistBatchMutationResult {
        var succeededCount = 0
        for playlist in displayPlaylist.deletablePlaylists {
            do {
                _ = try await deletePlaylist(playlist)
                succeededCount += 1
            } catch {
                EnsembleLogger.debug("Merged playlist delete failed for \(playlist.sourceScopedID): \(error.localizedDescription)")
            }
        }

        let totalCount = displayPlaylist.deletablePlaylists.count
        let completedAll = succeededCount == totalCount
        return PlaylistBatchMutationResult(
            succeededCount: succeededCount,
            totalCount: totalCount,
            resultToast: ToastPayload(
                style: completedAll ? .success : .error,
                iconSystemName: completedAll ? PlaylistIcon.success : PlaylistIcon.failure,
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
        "\(scope.rawValue)-\(action)-\(state)-\(playlistID)"
    }

    private func queuedAddToast(playlist: Playlist) -> ToastPayload {
        ToastPayload(
            style: .info,
            iconSystemName: PlaylistIcon.queued,
            title: "Queued for \(playlist.title)",
            message: "Will be added when back online.",
            dedupeKey: "playlist-add-queued-\(playlist.sourceScopedID)"
        )
    }

    private func addToast(
        playlist: Playlist,
        result: PlaylistMutationResult,
        openPlaylist: (() -> Void)?
    ) -> ToastPayload {
        if result.skippedCount > 0 {
            return ToastPayload(
                style: .warning,
                iconSystemName: PlaylistIcon.warning,
                title: "Added to \(playlist.title)",
                message: "Added \(result.addedCount), skipped \(result.skippedCount) incompatible.",
                action: openPlaylist.map { ToastAction(title: "View", handler: $0) },
                dedupeKey: "playlist-add-\(playlist.sourceScopedID)"
            )
        }

        return ToastPayload(
            style: .success,
            iconSystemName: PlaylistIcon.success,
            title: "Added to \(playlist.title)",
            message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
            action: openPlaylist.map { ToastAction(title: "View", handler: $0) },
            dedupeKey: "playlist-add-\(playlist.sourceScopedID)"
        )
    }

    private func optimisticAddToast(
        playlist: Playlist,
        addedCount: Int,
        outcome: MutationOutcome,
        openPlaylist: (() -> Void)?
    ) -> ToastPayload {
        if outcome == .queued {
            return queuedAddToast(playlist: playlist)
        }

        return ToastPayload(
            style: .success,
            iconSystemName: PlaylistIcon.success,
            title: "Added to \(playlist.title)",
            message: addedCount == 1 ? "1 track queued for sync." : "\(addedCount) tracks queued for sync.",
            action: openPlaylist.map { ToastAction(title: "View", handler: $0) },
            dedupeKey: "playlist-add-optimistic-\(playlist.sourceScopedID)"
        )
    }

    private func createToast(
        title: String,
        serverSourceKey: String,
        result: PlaylistMutationResult
    ) -> ToastPayload {
        if result.skippedCount > 0 {
            return ToastPayload(
                style: .warning,
                iconSystemName: PlaylistIcon.playlistCreate,
                title: "Created \(title)",
                message: "Added \(result.addedCount), skipped \(result.skippedCount).",
                dedupeKey: "playlist-create-\(serverSourceKey)-\(title.lowercased())"
            )
        }

        return ToastPayload(
            style: .success,
            iconSystemName: PlaylistIcon.playlistCreate,
            title: "Created \(title)",
            message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
            dedupeKey: "playlist-create-\(serverSourceKey)-\(title.lowercased())"
        )
    }
}
