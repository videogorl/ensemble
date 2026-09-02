import Combine
import EnsembleAPI
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

enum CollectionRatingKind: String, Codable, Sendable {
    case album
    case playlist
}

struct CollectionRatingMutationPayload: Codable, Sendable {
    let ratingKey: String
    let sourceCompositeKey: String
    let kind: CollectionRatingKind
    let rating: Int?
}

/// Payload for a playlist add/remove mutation
public struct PlaylistMutationPayload: Codable, Sendable {
    public let playlistRatingKey: String
    public let playlistTitle: String?
    public let playlistSourceCompositeKey: String
    public let trackReferences: [OfflineTrackReference]

    public init(
        playlistRatingKey: String,
        playlistTitle: String? = nil,
        playlistSourceCompositeKey: String,
        trackReferences: [OfflineTrackReference]
    ) {
        self.playlistRatingKey = playlistRatingKey
        self.playlistTitle = playlistTitle
        self.playlistSourceCompositeKey = playlistSourceCompositeKey
        self.trackReferences = trackReferences
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

/// Payload for a scrobble mutation (mark track as played)
public struct ScrobbleMutationPayload: Codable, Sendable {
    public let trackRatingKey: String
    public let sourceCompositeKey: String

    public init(trackRatingKey: String, sourceCompositeKey: String) {
        self.trackRatingKey = trackRatingKey
        self.sourceCompositeKey = sourceCompositeKey
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
    private let playlistRepository: PlaylistRepositoryProtocol?
    private let networkMonitor: NetworkMonitor
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var isDraining = false

    /// Whether the device is currently offline
    public var isOffline: Bool { syncCoordinator.isOffline }

    public init(
        repository: PendingMutationRepositoryProtocol,
        networkMonitor: NetworkMonitor,
        syncCoordinator: SyncCoordinator,
        playlistRepository: PlaylistRepositoryProtocol? = nil
    ) {
        self.repository = repository
        self.networkMonitor = networkMonitor
        self.syncCoordinator = syncCoordinator
        self.playlistRepository = playlistRepository

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

        NotificationCenter.default.publisher(
            for: SourceCacheCleanupService.pendingMutationsDidChange
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshCount()
            }
        }
        .store(in: &cancellables)

        // Load the initial pending count so the published value is correct from the start
        Task { @MainActor [weak self] in
            await self?.refreshCount()
        }
    }

    // MARK: - Unified Mutation API

    /// Rate a track (or unrate with nil). Queues when offline or server unreachable.
    @discardableResult
    public func rateTrack(_ track: Track, rating: Int?) async throws -> MutationOutcome {
        guard let sourceKey = track.sourceCompositeKey,
              MusicSourceIdentifier(compositeKey: sourceKey) != nil else {
            throw MusicSourceRoutingError.invalidSourceKey(track.sourceCompositeKey)
        }
        let supportsQueuedMutations = track.sourceCapabilities.supportsQueuedRatingMutations

        if !supportsQueuedMutations, syncCoordinator.isOffline {
            throw URLError(.notConnectedToInternet)
        }

        // Queue immediately if we know we're offline
        if syncCoordinator.isOffline {
            let payload = TrackRatingMutationPayload(
                trackRatingKey: track.id, sourceCompositeKey: sourceKey, rating: rating
            )
            guard await enqueueMutation(type: .trackRating, payload: payload, sourceCompositeKey: sourceKey) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            return .queued
        }

        // Try the server; queue on connection failure so the mutation isn't lost
        do {
            try await syncCoordinator.rateTrack(track: track, rating: rating)
            return .completed
        } catch where isConnectionFailure(error) && supportsQueuedMutations {
            let payload = TrackRatingMutationPayload(
                trackRatingKey: track.id, sourceCompositeKey: sourceKey, rating: rating
            )
            guard await enqueueMutation(type: .trackRating, payload: payload, sourceCompositeKey: sourceKey) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            return .queued
        }
    }

    @discardableResult
    public func rateAlbum(_ album: Album, rating: Int?) async throws -> MutationOutcome {
        try await rateCollection(
            ratingKey: album.id,
            sourceCompositeKey: album.sourceCompositeKey,
            kind: .album,
            rating: rating
        )
    }

    @discardableResult
    public func ratePlaylist(_ playlist: Playlist, rating: Int?) async throws -> MutationOutcome {
        try await rateCollection(
            ratingKey: playlist.id,
            sourceCompositeKey: playlist.sourceCompositeKey,
            kind: .playlist,
            rating: rating
        )
    }

    private func rateCollection(
        ratingKey: String,
        sourceCompositeKey: String?,
        kind: CollectionRatingKind,
        rating: Int?
    ) async throws -> MutationOutcome {
        guard let sourceCompositeKey,
              let sourceIdentity = MediaSourceIdentity.parse(sourceCompositeKey) else {
            throw MusicSourceRoutingError.invalidSourceKey(sourceCompositeKey)
        }
        guard sourceIdentity.sourceType.capabilities.supportsCollectionRatings else {
            throw MusicSourceRoutingError.capabilityUnavailable(
                sourceKey: sourceCompositeKey,
                capability: "collection ratings"
            )
        }

        let payload = CollectionRatingMutationPayload(
            ratingKey: ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            kind: kind,
            rating: rating
        )
        if syncCoordinator.isOffline {
            guard await enqueueMutation(
                type: .collectionRating,
                payload: payload,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceCompositeKey)
            }
            return .queued
        }

        do {
            try await syncCoordinator.rateCollection(
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey,
                rating: rating
            )
            return .completed
        } catch where isConnectionFailure(error) {
            guard await enqueueMutation(
                type: .collectionRating,
                payload: payload,
                sourceCompositeKey: sourceCompositeKey
            ) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceCompositeKey)
            }
            return .queued
        }
    }

    /// Add tracks to a playlist. Queues when the source supports delayed mutations.
    public func addTracksToPlaylist(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> (PlaylistMutationResult?, MutationOutcome) {
        let sourceKey = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistTrackAdds else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        let supportsQueuedMutations = supportsQueuedPlaylistMutations(playlist)

        if !supportsQueuedMutations, syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Add to playlist")
        }

        if syncCoordinator.isOffline {
            let payload = try makePlaylistAddPayload(tracks: tracks, playlist: playlist, sourceKey: sourceKey)
            guard await enqueueMutation(
                type: .playlistAdd,
                payload: payload,
                sourceCompositeKey: sourceKey,
                relatedSourceCompositeKeys: Set(payload.trackReferences.map(\.trackSourceCompositeKey))
            ) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            return (nil, .queued)
        }

        do {
            let result = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
            return (result, .completed)
        } catch where isConnectionFailure(error) && supportsQueuedMutations {
            let payload = try makePlaylistAddPayload(tracks: tracks, playlist: playlist, sourceKey: sourceKey)
            guard await enqueueMutation(
                type: .playlistAdd,
                payload: payload,
                sourceCompositeKey: sourceKey,
                relatedSourceCompositeKeys: Set(payload.trackReferences.map(\.trackSourceCompositeKey))
            ) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            return (nil, .queued)
        }
    }

    private func makePlaylistAddPayload(
        tracks: [Track],
        playlist: Playlist,
        sourceKey: String
    ) throws -> PlaylistMutationPayload {
        for track in tracks {
            guard let trackSourceKey = track.sourceCompositeKey,
                  MusicSourceIdentifier(compositeKey: trackSourceKey) != nil else {
                throw MusicSourceRoutingError.invalidSourceKey(track.sourceCompositeKey)
            }
        }
        let compatibleTracks = PlaylistActionService().tracks(
            tracks,
            compatibleWithServerSourceKey: sourceKey
        )
        guard !compatibleTracks.isEmpty else { throw PlaylistMutationError.emptySelection }
        let references = try compatibleTracks.map { track in
            guard let trackSourceKey = track.sourceCompositeKey,
                  MusicSourceIdentifier(compositeKey: trackSourceKey) != nil else {
                throw MusicSourceRoutingError.invalidSourceKey(track.sourceCompositeKey)
            }
            return OfflineTrackReference(
                trackRatingKey: track.id,
                trackSourceCompositeKey: trackSourceKey
            )
        }
        return PlaylistMutationPayload(
            playlistRatingKey: playlist.id,
            playlistTitle: playlist.title,
            playlistSourceCompositeKey: sourceKey,
            trackReferences: references
        )
    }

    /// Optimistic playlist-add path used by interactive UI surfaces.
    /// The mutation is persisted first, then drained in the background when online.
    @discardableResult
    public func enqueuePlaylistAddOptimistically(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> MutationOutcome {
        let sourceKey = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistTrackAdds else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        let supportsQueuedMutations = supportsQueuedPlaylistMutations(playlist)

        if !supportsQueuedMutations {
            guard !syncCoordinator.isOffline else {
                throw MutationError.unavailableOffline("Add to playlist")
            }
            _ = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
            return .completed
        }

        let payload = try makePlaylistAddPayload(tracks: tracks, playlist: playlist, sourceKey: sourceKey)
        guard await enqueueMutation(
            type: .playlistAdd,
            payload: payload,
            sourceCompositeKey: sourceKey,
            relatedSourceCompositeKeys: Set(payload.trackReferences.map(\.trackSourceCompositeKey))
        ) else {
            throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
        }
        rememberLastPlaylistTargetIfCurrent(playlist, sourceKey: sourceKey)

        if networkMonitor.isConnected {
            Task { @MainActor [weak self] in
                await self?.drainQueue()
            }
            return .completed
        }

        return .queued
    }

    /// Rename a playlist. Queues when the source supports delayed mutations.
    @discardableResult
    public func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws -> MutationOutcome {
        let sourceKey = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistRenaming else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        let supportsQueuedMutations = supportsQueuedPlaylistMutations(playlist)

        if !supportsQueuedMutations, syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Rename playlist")
        }

        if syncCoordinator.isOffline {
            let payload = PlaylistRenameMutationPayload(
                playlistRatingKey: playlist.id, playlistSourceCompositeKey: sourceKey, newTitle: newTitle
            )
            guard await enqueueMutation(type: .playlistRename, payload: payload, sourceCompositeKey: sourceKey) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            await persistPlaylistRename(playlist, title: newTitle, sourceKey: sourceKey)
            return .queued
        }

        do {
            try await syncCoordinator.renamePlaylist(playlist, to: newTitle)
            await persistPlaylistRename(playlist, title: newTitle, sourceKey: sourceKey)
            return .completed
        } catch where isConnectionFailure(error) && supportsQueuedMutations {
            let payload = PlaylistRenameMutationPayload(
                playlistRatingKey: playlist.id, playlistSourceCompositeKey: sourceKey, newTitle: newTitle
            )
            guard await enqueueMutation(type: .playlistRename, payload: payload, sourceCompositeKey: sourceKey) else {
                throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
            }
            await persistPlaylistRename(playlist, title: newTitle, sourceKey: sourceKey)
            return .queued
        }
    }

    private func persistPlaylistRename(_ playlist: Playlist, title: String, sourceKey: String) async {
        guard let playlistRepository,
              let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey) else {
            return
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        do {
            try await playlistRepository.updatePlaylistTitle(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey,
                title: title,
                dateModified: Date()
            )
            NotificationCenter.default.post(
                name: SyncCoordinator.playlistsDidRefresh,
                object: nil,
                userInfo: ["serverSourceKey": sourceKey]
            )
        } catch {
            EnsembleLogger.debug("Playlist rename succeeded but local cache update failed: \(error.localizedDescription)")
        }
    }

    private func rememberLastPlaylistTargetIfCurrent(_ playlist: Playlist, sourceKey: String) {
        guard let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKey: sourceKey) else {
            return
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        syncCoordinator.rememberLastPlaylistTarget(playlist)
    }

    /// Delete a playlist. Queues when the source supports delayed mutations and purges related queued mutations.
    @discardableResult
    public func deletePlaylist(_ playlist: Playlist) async throws -> MutationOutcome {
        let sourceKey = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistDeletion else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        let supportsQueuedMutations = supportsQueuedPlaylistMutations(playlist)

        if syncCoordinator.isOffline {
            guard supportsQueuedMutations else {
                throw MutationError.unavailableOffline("Delete playlist")
            }
            try await enqueuePlaylistDelete(playlist: playlist, sourceKey: sourceKey)
            return .queued
        }

        do {
            try await syncCoordinator.deletePlaylist(playlist)
            return .completed
        } catch where isConnectionFailure(error) && supportsQueuedMutations {
            try await enqueuePlaylistDelete(playlist: playlist, sourceKey: sourceKey)
            return .queued
        }
    }

    /// Enqueue a playlist deletion and purge any now-irrelevant queued mutations for it
    private func enqueuePlaylistDelete(playlist: Playlist, sourceKey: String) async throws {
        await purgePlaylistMutations(playlistRatingKey: playlist.id, playlistSourceCompositeKey: sourceKey)
        let payload = PlaylistDeleteMutationPayload(
            playlistRatingKey: playlist.id, playlistSourceCompositeKey: sourceKey
        )
        guard await enqueueMutation(type: .playlistDelete, payload: payload, sourceCompositeKey: sourceKey) else {
            throw MusicSourceRoutingError.providerUnavailable(sourceKey: sourceKey)
        }
    }

    /// Create a playlist. Throws `MutationError.unavailableOffline` when offline or server
    /// unreachable — cannot be queued because no server ID exists yet.
    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        if syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Create playlist")
        }
        do {
            return try await syncCoordinator.createPlaylist(title: title, tracks: tracks, serverSourceKey: serverSourceKey)
        } catch where isConnectionFailure(error) {
            throw MutationError.unavailableOffline("Create playlist")
        }
    }

    /// Replace playlist contents. Throws `MutationError.unavailableOffline` when offline or
    /// server unreachable — multi-step clear+add is ordering-sensitive and risks data loss if queued.
    public func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        _ = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistEditing else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        if syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Edit playlist tracks")
        }
        do {
            try await syncCoordinator.replacePlaylistContents(playlist, with: orderedTracks)
        } catch where isConnectionFailure(error) {
            throw MutationError.unavailableOffline("Edit playlist tracks")
        }
    }

    /// Edit playlist items without clearing memberships that are unavailable locally.
    public func editPlaylistItems(
        _ playlist: Playlist,
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) async throws {
        _ = try requireSourceKey(for: playlist)
        guard playlist.supportsPlaylistEditing else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        if syncCoordinator.isOffline {
            throw MutationError.unavailableOffline("Edit playlist tracks")
        }
        do {
            try await syncCoordinator.editPlaylistItems(
                playlist,
                originalItems: originalItems,
                editedItems: editedItems
            )
        } catch where isConnectionFailure(error) {
            throw MutationError.unavailableOffline("Edit playlist tracks")
        }
    }

    /// Save the current queue as a playlist snapshot. Delegates to addTracksToPlaylist.
    public func saveQueueSnapshot(
        _ tracks: [Track],
        to playlist: Playlist
    ) async throws -> (PlaylistMutationResult?, MutationOutcome) {
        return try await addTracksToPlaylist(tracks, playlist: playlist)
    }

    private func requireSourceKey(for playlist: Playlist) throws -> String {
        guard let sourceKey = playlist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else {
            throw MusicSourceRoutingError.invalidSourceKey(playlist.sourceCompositeKey)
        }
        return sourceKey
    }

    /// Scrobble a track (mark as played). Queues when offline or server unreachable
    /// so play counts are not lost on flaky connections.
    @discardableResult
    public func scrobbleTrack(_ track: Track) async -> MutationOutcome {
        guard let sourceKey = track.sourceCompositeKey,
              MusicSourceIdentifier(compositeKey: sourceKey) != nil else {
            return .completed
        }

        if syncCoordinator.isOffline {
            let payload = ScrobbleMutationPayload(
                trackRatingKey: track.id, sourceCompositeKey: sourceKey
            )
            return await enqueueMutation(type: .scrobble, payload: payload, sourceCompositeKey: sourceKey)
                ? .queued
                : .completed
        }

        do {
            try await syncCoordinator.scrobbleTrackThrowing(track)
            return .completed
        } catch where isConnectionFailure(error) {
            let payload = ScrobbleMutationPayload(
                trackRatingKey: track.id, sourceCompositeKey: sourceKey
            )
            return await enqueueMutation(type: .scrobble, payload: payload, sourceCompositeKey: sourceKey)
                ? .queued
                : .completed
        } catch {
            // Non-retryable error (semantic) — log and drop
            EnsembleLogger.debug("⚠️ MutationCoordinator: Scrobble failed with non-retryable error: \(error)")
            return .completed
        }
    }

    // MARK: - Queue Management

    /// Drain queued mutations now (called on app launch when online, or after reconnect)
    public func drainQueue() async {
        guard !isDraining, networkMonitor.isConnected else { return }
        isDraining = true
        defer { isDraining = false }

        do {
            let mutations = try await repository.fetchPendingMutationRecords()
            guard !mutations.isEmpty else { return }

            EnsembleLogger.debug("📬 MutationCoordinator: Draining \(mutations.count) mutations")

            var consecutiveFailures = 0

            for mutation in mutations {
                // If too many consecutive failures, stop draining — server is likely down.
                // Queue will re-drain on next connectivity event.
                if consecutiveFailures >= 5 {
                    EnsembleLogger.debug("⚠️ MutationCoordinator: Stopping drain after \(consecutiveFailures) consecutive failures")
                    break
                }

                // Progressive backoff after 2+ consecutive failures
                if consecutiveFailures >= 2 {
                    let delaySeconds = min(Double(1 << consecutiveFailures), 30.0)
                    EnsembleLogger.debug("⏳ MutationCoordinator: Backoff \(delaySeconds)s before next drain attempt")
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }

                guard let sourceKeys = persistenceSourceKeys(for: mutation) else {
                    try? await repository.markFailed(id: mutation.id)
                    continue
                }
                guard let success = await replayMutationIfCurrent(mutation, sourceKeys: sourceKeys) else {
                    continue
                }
                if success {
                    try? await repository.deleteMutation(id: mutation.id)
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    try? await repository.incrementRetryCount(id: mutation.id)
                    if mutation.retryCount + 1 >= Self.maxRetries {
                        try? await repository.markFailed(id: mutation.id)
                        EnsembleLogger.debug("⚠️ MutationCoordinator: Mutation \(mutation.id) failed after \(Self.maxRetries) retries")
                    }
                }
            }

            await refreshCount()
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Error draining queue: \(error)")
        }
    }

    /// Refresh the published pending count from the repository
    public func refreshCount() async {
        pendingCount = (try? await repository.countPendingMutations()) ?? 0
    }

    // MARK: - Server Failure Detection

    /// Returns true if the error is a connection/transport failure (server unreachable,
    /// timeout, connection reset) rather than a semantic API error (bad request, auth, etc.).
    /// Connection failures are safe to queue for retry; semantic errors should propagate.
    private func isConnectionFailure(_ error: Error) -> Bool {
        PlexErrorClassification.classify(error).isRetryable
    }

    private func supportsQueuedPlaylistMutations(_ playlist: Playlist) -> Bool {
        playlist.sourceType?.capabilities.supportsQueuedPlaylistMutations == true
    }

    // MARK: - Private Enqueue Helpers

    /// Generic enqueue method for any Codable payload
    @discardableResult
    private func enqueueMutation<T: Codable>(
        type: CDPendingMutation.MutationType,
        payload: T,
        sourceCompositeKey: String,
        relatedSourceCompositeKeys: Set<String> = []
    ) async -> Bool {
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        let sourceKeys = relatedSourceCompositeKeys.union([sourceCompositeKey])
        guard let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKeys: sourceKeys) else {
            EnsembleLogger.debug("MutationCoordinator: Skipped enqueue for unavailable source \(sourceCompositeKey)")
            return false
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        do {
            try await repository.enqueueMutation(
                id: id,
                type: type,
                payload: data,
                sourceCompositeKey: sourceCompositeKey
            )
            await refreshCount()
            EnsembleLogger.debug("📬 MutationCoordinator: Enqueued \(type.rawValue)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed to enqueue \(type.rawValue): \(error)")
            return false
        }
    }

    /// Remove queued mutations targeting a playlist being deleted.
    private func purgePlaylistMutations(playlistRatingKey: String, playlistSourceCompositeKey: String) async {
        let playlistTypes: Set<CDPendingMutation.MutationType> = [
            .playlistAdd,
            .playlistRemove,
            .playlistRename,
            .collectionRating,
        ]
        do {
            let pending = try await repository.fetchPendingMutationRecords()
            for mutation in pending {
                guard playlistTypes.contains(mutation.mutationType) else { continue }
                // Check if this mutation targets the playlist being deleted
                if matchesPlaylist(
                    mutation: mutation,
                    playlistRatingKey: playlistRatingKey,
                    playlistSourceCompositeKey: playlistSourceCompositeKey
                ) {
                    try? await repository.deleteMutation(id: mutation.id)
                    EnsembleLogger.debug("🗑️ MutationCoordinator: Purged \(mutation.mutationType.rawValue) for deleted playlist \(playlistRatingKey)")
                }
            }
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Error purging playlist mutations: \(error)")
        }
    }

    /// Check if a queued mutation targets a specific playlist by decoding its payload
    private func matchesPlaylist(
        mutation: PendingMutationRecord,
        playlistRatingKey: String,
        playlistSourceCompositeKey: String
    ) -> Bool {
        switch mutation.mutationType {
        case .playlistAdd, .playlistRemove:
            if let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) {
                return payload.playlistRatingKey == playlistRatingKey &&
                    payload.playlistSourceCompositeKey == playlistSourceCompositeKey
            }
        case .playlistRename:
            if let payload = try? JSONDecoder().decode(PlaylistRenameMutationPayload.self, from: mutation.payload) {
                return payload.playlistRatingKey == playlistRatingKey &&
                    payload.playlistSourceCompositeKey == playlistSourceCompositeKey
            }
        case .collectionRating:
            if let payload = try? JSONDecoder().decode(CollectionRatingMutationPayload.self, from: mutation.payload) {
                return payload.kind == .playlist &&
                    payload.ratingKey == playlistRatingKey &&
                    payload.sourceCompositeKey == playlistSourceCompositeKey
            }
        case .trackRating, .playlistDelete, .scrobble:
            break
        }
        return false
    }

    private func persistenceSourceKeys(for mutation: PendingMutationRecord) -> Set<String>? {
        guard let ownerKey = mutation.sourceCompositeKey else { return nil }
        switch mutation.mutationType {
        case .trackRating:
            guard let payload = try? JSONDecoder().decode(TrackRatingMutationPayload.self, from: mutation.payload),
                  payload.sourceCompositeKey == ownerKey,
                  MusicSourceIdentifier(compositeKey: ownerKey) != nil else {
                return nil
            }
            return [ownerKey]
        case .collectionRating:
            guard let payload = try? JSONDecoder().decode(CollectionRatingMutationPayload.self, from: mutation.payload),
                  payload.sourceCompositeKey == ownerKey,
                  MediaSourceIdentity.parse(ownerKey) != nil else {
                return nil
            }
            return [ownerKey]
        case .scrobble:
            guard let payload = try? JSONDecoder().decode(ScrobbleMutationPayload.self, from: mutation.payload),
                  payload.sourceCompositeKey == ownerKey,
                  MusicSourceIdentifier(compositeKey: ownerKey) != nil else {
                return nil
            }
            return [ownerKey]
        case .playlistAdd, .playlistRemove:
            guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload),
                  payload.playlistSourceCompositeKey == ownerKey,
                  isValidPlaylistSourceKey(ownerKey),
                  payload.trackReferences.allSatisfy({
                      MusicSourceIdentifier(compositeKey: $0.trackSourceCompositeKey) != nil
                  }) else {
                return nil
            }
            return Set(payload.trackReferences.map(\.trackSourceCompositeKey)).union([ownerKey])
        case .playlistRename:
            guard let payload = try? JSONDecoder().decode(PlaylistRenameMutationPayload.self, from: mutation.payload),
                  payload.playlistSourceCompositeKey == ownerKey,
                  isValidPlaylistSourceKey(ownerKey) else {
                return nil
            }
            return [ownerKey]
        case .playlistDelete:
            guard let payload = try? JSONDecoder().decode(PlaylistDeleteMutationPayload.self, from: mutation.payload),
                  payload.playlistSourceCompositeKey == ownerKey,
                  isValidPlaylistSourceKey(ownerKey) else {
                return nil
            }
            return [ownerKey]
        }
    }

    private func isValidPlaylistSourceKey(_ sourceKey: String) -> Bool {
        guard let identity = MediaSourceIdentity.parse(sourceKey) else { return false }
        return !identity.isServerScoped || identity.sourceType.capabilities.playlistsAreServerScoped
    }

    private func replayMutationIfCurrent(
        _ mutation: PendingMutationRecord,
        sourceKeys: Set<String>
    ) async -> Bool? {
        guard let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(sourceKeys: sourceKeys) else {
            return nil
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }
        let currentMutations = try? await repository.fetchPendingMutationRecords()
        guard currentMutations?.contains(where: { $0.id == mutation.id }) == true else {
            return nil
        }
        return await replayMutation(mutation)
    }

    // MARK: - Replay

    /// Attempt to replay a single persisted mutation against the server
    private func replayMutation(_ mutation: PendingMutationRecord) async -> Bool {
        switch mutation.mutationType {
        case .trackRating:
            return await replayTrackRating(mutation)
        case .collectionRating:
            return await replayCollectionRating(mutation)
        case .playlistAdd:
            return await replayPlaylistAdd(mutation)
        case .playlistRemove:
            // playlistRemove not currently enqueued but handled for future completeness
            return true
        case .playlistRename:
            return await replayPlaylistRename(mutation)
        case .playlistDelete:
            return await replayPlaylistDelete(mutation)
        case .scrobble:
            return await replayScrobble(mutation)
        }
    }

    private func replayTrackRating(_ mutation: PendingMutationRecord) async -> Bool {
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
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed trackRating for \(payload.trackRatingKey)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying trackRating: \(error)")
            return false
        }
    }

    private func replayCollectionRating(_ mutation: PendingMutationRecord) async -> Bool {
        guard let payload = try? JSONDecoder().decode(
            CollectionRatingMutationPayload.self,
            from: mutation.payload
        ) else {
            return false
        }
        do {
            try await syncCoordinator.rateCollection(
                ratingKey: payload.ratingKey,
                sourceCompositeKey: payload.sourceCompositeKey,
                rating: payload.rating
            )
            return true
        } catch {
            EnsembleLogger.debug("MutationCoordinator: Failed replaying collection rating: \(error)")
            return false
        }
    }

    private func replayPlaylistAdd(_ mutation: PendingMutationRecord) async -> Bool {
        guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) else {
            return false
        }

        let tracks = payload.trackReferences.map { reference in
            Track(
                id: reference.trackRatingKey,
                key: "/library/metadata/\(reference.trackRatingKey)",
                title: "",
                sourceCompositeKey: reference.trackSourceCompositeKey
            )
        }
        let playlist = Playlist(
            id: payload.playlistRatingKey,
            key: "/playlists/\(payload.playlistRatingKey)",
            title: payload.playlistTitle ?? "",
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
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistAdd for playlist \(payload.playlistRatingKey)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistAdd: \(error)")
            return false
        }
    }

    private func replayPlaylistRename(_ mutation: PendingMutationRecord) async -> Bool {
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
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistRename for \(payload.playlistRatingKey)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistRename: \(error)")
            return false
        }
    }

    private func replayPlaylistDelete(_ mutation: PendingMutationRecord) async -> Bool {
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
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed playlistDelete for \(payload.playlistRatingKey)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying playlistDelete: \(error)")
            return false
        }
    }

    private func replayScrobble(_ mutation: PendingMutationRecord) async -> Bool {
        guard let payload = try? JSONDecoder().decode(ScrobbleMutationPayload.self, from: mutation.payload) else {
            return false
        }

        let track = Track(
            id: payload.trackRatingKey,
            key: "/library/metadata/\(payload.trackRatingKey)",
            title: "",
            sourceCompositeKey: payload.sourceCompositeKey
        )
        do {
            try await syncCoordinator.scrobbleTrackThrowing(track)
            EnsembleLogger.debug("✅ MutationCoordinator: Replayed scrobble for \(payload.trackRatingKey)")
            return true
        } catch {
            EnsembleLogger.debug("❌ MutationCoordinator: Failed replaying scrobble: \(error)")
            return false
        }
    }
}
