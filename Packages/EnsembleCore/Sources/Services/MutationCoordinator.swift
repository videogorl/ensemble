import Combine
import EnsemblePersistence
import Foundation

// MARK: - Mutation Outcome

/// Result of attempting a mutation — either completed immediately or queued for later
public enum MutationOutcome: Sendable {
    case completed
    case queued
}

// MARK: - Mutation Error

/// Errors specific to the mutation coordination layer
public enum MutationError: LocalizedError {
    case unavailableOffline(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOffline(let action):
            return "\(action) is not available while offline."
        }
    }
}

// MARK: - Mutation Payload Models

/// Payload for a track rating mutation (favorite toggle)
public struct TrackRatingMutationPayload: Codable, Sendable {
    public let trackRatingKey: String
    public let sourceCompositeKey: String
    /// nil = unrate (remove rating), non-nil = set rating (e.g. 10 for loved)
    public let rating: Int?

    public init(trackRatingKey: String, sourceCompositeKey: String, rating: Int?) {
        self.trackRatingKey = trackRatingKey
        self.sourceCompositeKey = sourceCompositeKey
        self.rating = rating
    }
}

/// Payload for a playlist add/remove mutation
public struct PlaylistMutationPayload: Codable, Sendable {
    public let playlistRatingKey: String
    public let playlistSourceCompositeKey: String
    public let trackRatingKeys: [String]
    public let trackSourceCompositeKey: String

    public init(
        playlistRatingKey: String,
        playlistSourceCompositeKey: String,
        trackRatingKeys: [String],
        trackSourceCompositeKey: String
    ) {
        self.playlistRatingKey = playlistRatingKey
        self.playlistSourceCompositeKey = playlistSourceCompositeKey
        self.trackRatingKeys = trackRatingKeys
        self.trackSourceCompositeKey = trackSourceCompositeKey
    }
}

/// Payload for a playlist rename mutation
public struct PlaylistRenameMutationPayload: Codable, Sendable {
    public let playlistRatingKey: String
    public let playlistSourceCompositeKey: String
    public let newTitle: String

    public init(playlistRatingKey: String, playlistSourceCompositeKey: String, newTitle: String) {
        self.playlistRatingKey = playlistRatingKey
        self.playlistSourceCompositeKey = playlistSourceCompositeKey
        self.newTitle = newTitle
    }
}

/// Payload for a playlist delete mutation
public struct PlaylistDeleteMutationPayload: Codable, Sendable {
    public let playlistRatingKey: String
    public let playlistSourceCompositeKey: String

    public init(playlistRatingKey: String, playlistSourceCompositeKey: String) {
        self.playlistRatingKey = playlistRatingKey
        self.playlistSourceCompositeKey = playlistSourceCompositeKey
    }
}

// MARK: - MutationCoordinator

/// Unified entry point for all server-side mutations. Handles online execution and offline queuing.
/// Mutations are persisted in CoreData and survive app restarts. The queue drains automatically
/// when connectivity resumes.
@MainActor
public final class MutationCoordinator: ObservableObject {
    /// How many pending (non-failed) mutations are queued
    @Published public private(set) var pendingCount: Int = 0

    private static let maxRetries: Int16 = 3

    private let repository: PendingMutationRepositoryProtocol
    private let networkMonitor: NetworkMonitor
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var isDraining = false

    /// Whether the device is currently offline
    public var isOffline: Bool { syncCoordinator.isOffline }

    public init(
        repository: PendingMutationRepositoryProtocol,
        networkMonitor: NetworkMonitor,
        syncCoordinator: SyncCoordinator
    ) {
        self.repository = repository
        self.networkMonitor = networkMonitor
        self.syncCoordinator = syncCoordinator

        // Drain queue when connectivity is restored
        networkMonitor.$isConnected
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] isConnected in
                guard isConnected else { return }
                Task { @MainActor [weak self] in
                    await self?.drainQueue()
                }
            }
            .store(in: &cancellables)

        // Load the initial pending count so the published value is correct from the start
        Task { @MainActor [weak self] in
            await self?.refreshCount()
        }
    }

    // MARK: - Unified Mutation API

    /// Rate a track (or unrate with nil). Queues when offline.
    @discardableResult
    public func rateTrack(_ track: Track, rating: Int?) async throws -> MutationOutcome {
        if syncCoordinator.isOffline {
            guard let sourceKey = track.sourceCompositeKey else { return .completed }
            let payload = TrackRatingMutationPayload(
                trackRatingKey: track.id,
                sourceCompositeKey: sourceKey,
                rating: rating
            )
            await enqueueMutation(type: .trackRating, payload: payload, sourceCompositeKey: sourceKey)
            return .queued
        }

        try await syncCoordinator.rateTrack(track: track, rating: rating)
        return .completed
    }

    /// Add tracks to a playlist. Queues when offline.
    public func addTracksToPlaylist(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> (PlaylistMutationResult?, MutationOutcome) {
        if syncCoordinator.isOffline {
            guard let sourceKey = playlist.sourceCompositeKey else {
                return (nil, .completed)
            }
            let trackKeys = tracks.map(\.id)
            let trackSourceKey = tracks.first?.sourceCompositeKey ?? sourceKey
            let payload = PlaylistMutationPayload(
                playlistRatingKey: playlist.id,
                playlistSourceCompositeKey: sourceKey,
                trackRatingKeys: trackKeys,
                trackSourceCompositeKey: trackSourceKey
            )
            await enqueueMutation(type: .playlistAdd, payload: payload, sourceCompositeKey: sourceKey)
            return (nil, .queued)
        }

        let result = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
        return (result, .completed)
    }

    /// Rename a playlist. Queues when offline.
    @discardableResult
    public func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws -> MutationOutcome {
        if syncCoordinator.isOffline {
            guard let sourceKey = playlist.sourceCompositeKey else {
                throw MutationError.unavailableOffline("Rename playlist")
            }
            let payload = PlaylistRenameMutationPayload(
                playlistRatingKey: playlist.id,
                playlistSourceCompositeKey: sourceKey,
                newTitle: newTitle
            )
            await enqueueMutation(type: .playlistRename, payload: payload, sourceCompositeKey: sourceKey)
            return .queued
        }

        try await syncCoordinator.renamePlaylist(playlist, to: newTitle)
        return .completed
    }

    /// Delete a playlist. Queues when offline and purges any related queued mutations.
    @discardableResult
    public func deletePlaylist(_ playlist: Playlist) async throws -> MutationOutcome {
        if syncCoordinator.isOffline {
            guard let sourceKey = playlist.sourceCompositeKey else {
                throw MutationError.unavailableOffline("Delete playlist")
            }
            // Purge any queued mutations for this playlist since they're now irrelevant
            await purgePlaylistMutations(playlistRatingKey: playlist.id)
            let payload = PlaylistDeleteMutationPayload(
                playlistRatingKey: playlist.id,
                playlistSourceCompositeKey: sourceKey
            )
            await enqueueMutation(type: .playlistDelete, payload: payload, sourceCompositeKey: sourceKey)
            return .queued
        }

        try await syncCoordinator.deletePlaylist(playlist)
        return .completed
    }

    /// Create a playlist. Throws `MutationError.unavailableOffline` when offline — cannot be queued
    /// because no server ID exists yet.
    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        if syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Create playlist")
        }
        return try await syncCoordinator.createPlaylist(title: title, tracks: tracks, serverSourceKey: serverSourceKey)
    }

    /// Replace playlist contents. Throws `MutationError.unavailableOffline` when offline —
    /// multi-step clear+add is ordering-sensitive and risks data loss if queued.
    public func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        if syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Edit playlist tracks")
        }
        try await syncCoordinator.replacePlaylistContents(playlist, with: orderedTracks)
    }

    /// Save the current queue as a playlist snapshot. Delegates to addTracksToPlaylist.
    public func saveQueueSnapshot(
        _ tracks: [Track],
        to playlist: Playlist
    ) async throws -> (PlaylistMutationResult?, MutationOutcome) {
        return try await addTracksToPlaylist(tracks, playlist: playlist)
    }

    // MARK: - Queue Management

    /// Drain queued mutations now (called on app launch when online, or after reconnect)
    public func drainQueue() async {
        guard !isDraining, networkMonitor.isConnected else { return }
        isDraining = true
        defer { isDraining = false }

        do {
            let mutations = try await repository.fetchPendingMutations()
            guard !mutations.isEmpty else { return }

            #if DEBUG
            EnsembleLogger.debug("📬 MutationCoordinator: Draining \(mutations.count) mutations")
            #endif

            for mutation in mutations {
                let success = await replayMutation(mutation)
                if success {
                    try? await repository.deleteMutation(id: mutation.id)
                } else {
                    try? await repository.incrementRetryCount(id: mutation.id)
                    if mutation.retryCount + 1 >= Self.maxRetries {
                        try? await repository.markFailed(id: mutation.id)
                        #if DEBUG
                        EnsembleLogger.debug("⚠️ MutationCoordinator: Mutation \(mutation.id) failed after \(Self.maxRetries) retries")
                        #endif
                    }
                }
            }

            await refreshCount()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Error draining queue: \(error)")
            #endif
        }
    }

    /// Refresh the published pending count from the repository
    public func refreshCount() async {
        pendingCount = (try? await repository.countPendingMutations()) ?? 0
    }

    // MARK: - Private Enqueue Helpers

    /// Generic enqueue method for any Codable payload
    private func enqueueMutation<T: Codable>(
        type: CDPendingMutation.MutationType,
        payload: T,
        sourceCompositeKey: String
    ) async {
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try await repository.enqueueMutation(
                id: id,
                type: type,
                payload: data,
                sourceCompositeKey: sourceCompositeKey
            )
            await refreshCount()
            #if DEBUG
            EnsembleLogger.debug("📬 MutationCoordinator: Enqueued \(type.rawValue)")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Failed to enqueue \(type.rawValue): \(error)")
            #endif
        }
    }

    /// Remove any queued playlist mutations (add, rename, remove) for a playlist being deleted
    private func purgePlaylistMutations(playlistRatingKey: String) async {
        let playlistTypes: Set<String> = [
            CDPendingMutation.MutationType.playlistAdd.rawValue,
            CDPendingMutation.MutationType.playlistRemove.rawValue,
            CDPendingMutation.MutationType.playlistRename.rawValue,
        ]
        do {
            let pending = try await repository.fetchPendingMutations()
            for mutation in pending {
                guard playlistTypes.contains(mutation.type) else { continue }
                // Check if this mutation targets the playlist being deleted
                if matchesPlaylist(mutation: mutation, playlistRatingKey: playlistRatingKey) {
                    try? await repository.deleteMutation(id: mutation.id)
                    #if DEBUG
                    EnsembleLogger.debug("🗑️ MutationCoordinator: Purged \(mutation.type) for deleted playlist \(playlistRatingKey)")
                    #endif
                }
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Error purging playlist mutations: \(error)")
            #endif
        }
    }

    /// Check if a queued mutation targets a specific playlist by decoding its payload
    private func matchesPlaylist(mutation: CDPendingMutation, playlistRatingKey: String) -> Bool {
        switch mutation.mutationType {
        case .playlistAdd, .playlistRemove:
            if let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) {
                return payload.playlistRatingKey == playlistRatingKey
            }
        case .playlistRename:
            if let payload = try? JSONDecoder().decode(PlaylistRenameMutationPayload.self, from: mutation.payload) {
                return payload.playlistRatingKey == playlistRatingKey
            }
        case .trackRating, .playlistDelete:
            break
        }
        return false
    }

    // MARK: - Replay

    /// Attempt to replay a single persisted mutation against the server
    private func replayMutation(_ mutation: CDPendingMutation) async -> Bool {
        switch mutation.mutationType {
        case .trackRating:
            return await replayTrackRating(mutation)
        case .playlistAdd:
            return await replayPlaylistAdd(mutation)
        case .playlistRemove:
            // playlistRemove not currently enqueued but handled for future completeness
            return true
        case .playlistRename:
            return await replayPlaylistRename(mutation)
        case .playlistDelete:
            return await replayPlaylistDelete(mutation)
        }
    }

    private func replayTrackRating(_ mutation: CDPendingMutation) async -> Bool {
        guard let payload = try? JSONDecoder().decode(TrackRatingMutationPayload.self, from: mutation.payload) else {
            return false
        }

        // rateTrack only uses track.id and track.sourceCompositeKey
        let track = Track(
            id: payload.trackRatingKey,
            key: "/library/metadata/\(payload.trackRatingKey)",
            title: "",
            sourceCompositeKey: payload.sourceCompositeKey
        )
        do {
            try await syncCoordinator.rateTrack(track: track, rating: payload.rating)
            #if DEBUG
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed trackRating for \(payload.trackRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying trackRating: \(error)")
            #endif
            return false
        }
    }

    private func replayPlaylistAdd(_ mutation: CDPendingMutation) async -> Bool {
        guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) else {
            return false
        }

        let tracks = payload.trackRatingKeys.map { ratingKey in
            Track(
                id: ratingKey,
                key: "/library/metadata/\(ratingKey)",
                title: "",
                sourceCompositeKey: payload.trackSourceCompositeKey
            )
        }
        let playlist = Playlist(
            id: payload.playlistRatingKey,
            key: "/playlists/\(payload.playlistRatingKey)",
            title: "",
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )

        do {
            _ = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
            #if DEBUG
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistAdd for playlist \(payload.playlistRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistAdd: \(error)")
            #endif
            return false
        }
    }

    private func replayPlaylistRename(_ mutation: CDPendingMutation) async -> Bool {
        guard let payload = try? JSONDecoder().decode(PlaylistRenameMutationPayload.self, from: mutation.payload) else {
            return false
        }

        // renamePlaylist uses playlist.id, playlist.isSmart, and playlist.sourceCompositeKey
        let playlist = Playlist(
            id: payload.playlistRatingKey,
            key: "/playlists/\(payload.playlistRatingKey)",
            title: "",
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )

        do {
            try await syncCoordinator.renamePlaylist(playlist, to: payload.newTitle)
            #if DEBUG
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistRename for \(payload.playlistRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistRename: \(error)")
            #endif
            return false
        }
    }

    private func replayPlaylistDelete(_ mutation: CDPendingMutation) async -> Bool {
        guard let payload = try? JSONDecoder().decode(PlaylistDeleteMutationPayload.self, from: mutation.payload) else {
            return false
        }

        // deletePlaylist uses playlist.id, playlist.isSmart, and playlist.sourceCompositeKey
        let playlist = Playlist(
            id: payload.playlistRatingKey,
            key: "/playlists/\(payload.playlistRatingKey)",
            title: "",
            summary: nil,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )

        do {
            try await syncCoordinator.deletePlaylist(playlist)
            #if DEBUG
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistDelete for \(payload.playlistRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistDelete: \(error)")
            #endif
            return false
        }
    }
}
