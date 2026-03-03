import Combine
import EnsemblePersistence
import Foundation

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

// MARK: - PendingMutationQueue

/// Queues offline mutations (track ratings, playlist changes) and drains them when connectivity resumes.
/// Mutations are persisted in CoreData and survive app restarts.
@MainActor
public final class PendingMutationQueue: ObservableObject {
    /// How many pending (non-failed) mutations are queued
    @Published public private(set) var pendingCount: Int = 0

    private static let maxRetries: Int16 = 3

    private let repository: PendingMutationRepositoryProtocol
    private let networkMonitor: NetworkMonitor
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var isDraining = false

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

    // MARK: - Public Interface

    /// Enqueue a track rating mutation to be applied when online
    public func enqueueTrackRating(_ payload: TrackRatingMutationPayload) async {
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try await repository.enqueueMutation(
                id: id,
                type: .trackRating,
                payload: data,
                sourceCompositeKey: payload.sourceCompositeKey
            )
            await refreshCount()
            #if DEBUG
            EnsembleLogger.debug("📬 PendingMutationQueue: Enqueued trackRating for \(payload.trackRatingKey)")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationQueue: Failed to enqueue: \(error)")
            #endif
        }
    }

    /// Enqueue a playlist add mutation to be applied when online
    public func enqueuePlaylistAdd(_ payload: PlaylistMutationPayload) async {
        let id = UUID().uuidString
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try await repository.enqueueMutation(
                id: id,
                type: .playlistAdd,
                payload: data,
                sourceCompositeKey: payload.playlistSourceCompositeKey
            )
            await refreshCount()
            #if DEBUG
            EnsembleLogger.debug("📬 PendingMutationQueue: Enqueued playlistAdd for playlist \(payload.playlistRatingKey)")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationQueue: Failed to enqueue: \(error)")
            #endif
        }
    }

    /// Drain queued mutations now (called on app launch when online, or after reconnect)
    public func drainQueue() async {
        guard !isDraining, networkMonitor.isConnected else { return }
        isDraining = true
        defer { isDraining = false }

        do {
            let mutations = try await repository.fetchPendingMutations()
            guard !mutations.isEmpty else { return }

            #if DEBUG
            EnsembleLogger.debug("⬆️ PendingMutationQueue: Draining \(mutations.count) mutations")
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
                        EnsembleLogger.debug("⚠️ PendingMutationQueue: Mutation \(mutation.id) failed after \(Self.maxRetries) retries")
                        #endif
                    }
                }
            }

            await refreshCount()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationQueue: Error draining queue: \(error)")
            #endif
        }
    }

    /// Refresh the published pending count from the repository
    public func refreshCount() async {
        pendingCount = (try? await repository.countPendingMutations()) ?? 0
    }

    // MARK: - Private

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
            EnsembleLogger.debug("✅ PendingMutationQueue: Replayed trackRating for \(payload.trackRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationQueue: Failed replaying trackRating: \(error)")
            #endif
            return false
        }
    }

    private func replayPlaylistAdd(_ mutation: CDPendingMutation) async -> Bool {
        guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) else {
            return false
        }

        // addTracksToPlaylist only uses track.id and track.sourceCompositeKey
        let tracks = payload.trackRatingKeys.map { ratingKey in
            Track(
                id: ratingKey,
                key: "/library/metadata/\(ratingKey)",
                title: "",
                sourceCompositeKey: payload.trackSourceCompositeKey
            )
        }
        // addTracksToPlaylist uses playlist.isSmart, playlist.sourceCompositeKey, and playlist.id (ratingKey)
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
            EnsembleLogger.debug("✅ PendingMutationQueue: Replayed playlistAdd for playlist \(payload.playlistRatingKey)")
            #endif
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationQueue: Failed replaying playlistAdd: \(error)")
            #endif
            return false
        }
    }
}
