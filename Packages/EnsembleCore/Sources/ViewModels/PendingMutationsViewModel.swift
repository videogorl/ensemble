import Combine
import EnsemblePersistence
import Foundation

/// Display model for a single pending or failed mutation
public struct PendingMutationRow: Identifiable {
    public let id: String
    public let description: String
    public let status: CDPendingMutation.MutationStatus
    public let createdAt: Date
    public let retryCount: Int16
    public let mutationType: CDPendingMutation.MutationType
}

/// ViewModel for the Pending Mutations screen showing offline-queued changes
@MainActor
public final class PendingMutationsViewModel: ObservableObject {
    @Published public private(set) var rows: [PendingMutationRow] = []
    @Published public private(set) var isLoading = false

    private let mutationCoordinator: MutationCoordinator
    private let repository: PendingMutationRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        mutationCoordinator: MutationCoordinator,
        repository: PendingMutationRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.mutationCoordinator = mutationCoordinator
        self.repository = repository
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository

        // Refresh rows whenever the queue count changes (drain/enqueue events)
        mutationCoordinator.$pendingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadMutations()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    public func loadMutations() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let mutations = try await repository.fetchAllMutations()
            var result: [PendingMutationRow] = []

            for mutation in mutations {
                let description = await describePayload(mutation)
                result.append(PendingMutationRow(
                    id: mutation.id,
                    description: description,
                    status: mutation.mutationStatus,
                    createdAt: mutation.createdAt,
                    retryCount: mutation.retryCount,
                    mutationType: mutation.mutationType
                ))
            }

            rows = result
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationsViewModel: Failed loading mutations: \(error)")
            #endif
        }
    }

    /// Retry a single failed mutation (reset to pending so the queue picks it up)
    public func retryMutation(id: String) async {
        do {
            try await repository.resetToRetry(id: id)
            await mutationCoordinator.refreshCount()
            await mutationCoordinator.drainQueue()
            await loadMutations()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationsViewModel: Failed retrying mutation \(id): \(error)")
            #endif
        }
    }

    /// Delete a single mutation
    public func deleteMutation(id: String) async {
        do {
            try await repository.deleteMutation(id: id)
            await mutationCoordinator.refreshCount()
            await loadMutations()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ PendingMutationsViewModel: Failed deleting mutation \(id): \(error)")
            #endif
        }
    }

    /// Clear all failed mutations
    public func clearAllFailed() async {
        let failedIDs = rows.filter { $0.status == .failed }.map(\.id)
        for id in failedIDs {
            try? await repository.deleteMutation(id: id)
        }
        await mutationCoordinator.refreshCount()
        await loadMutations()
    }

    public var hasFailedMutations: Bool {
        rows.contains { $0.status == .failed }
    }

    // MARK: - Private

    /// Decode mutation payload and resolve human-readable descriptions from repositories
    private func describePayload(_ mutation: CDPendingMutation) async -> String {
        switch mutation.mutationType {
        case .trackRating:
            return await describeTrackRating(mutation)
        case .playlistAdd:
            return await describePlaylistAdd(mutation)
        case .playlistRemove:
            return await describePlaylistRemove(mutation)
        case .playlistRename:
            return await describePlaylistRename(mutation)
        case .playlistDelete:
            return await describePlaylistDelete(mutation)
        }
    }

    private func describeTrackRating(_ mutation: CDPendingMutation) async -> String {
        guard let payload = try? JSONDecoder().decode(TrackRatingMutationPayload.self, from: mutation.payload) else {
            return "Rate track"
        }

        let trackTitle = await resolveTrackTitle(
            ratingKey: payload.trackRatingKey,
            sourceCompositeKey: payload.sourceCompositeKey
        )

        if let rating = payload.rating, rating > 0 {
            return "Set \(trackTitle) as Loved"
        } else {
            return "Removed rating from \(trackTitle)"
        }
    }

    private func describePlaylistAdd(_ mutation: CDPendingMutation) async -> String {
        guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) else {
            return "Add tracks to playlist"
        }

        let playlistTitle = await resolvePlaylistTitle(
            ratingKey: payload.playlistRatingKey,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )
        let count = payload.trackRatingKeys.count
        let noun = count == 1 ? "track" : "tracks"
        return "Add \(count) \(noun) to \(playlistTitle)"
    }

    private func describePlaylistRemove(_ mutation: CDPendingMutation) async -> String {
        guard let payload = try? JSONDecoder().decode(PlaylistMutationPayload.self, from: mutation.payload) else {
            return "Remove tracks from playlist"
        }

        let playlistTitle = await resolvePlaylistTitle(
            ratingKey: payload.playlistRatingKey,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )
        return "Remove tracks from \(playlistTitle)"
    }

    private func describePlaylistRename(_ mutation: CDPendingMutation) async -> String {
        guard let payload = try? JSONDecoder().decode(PlaylistRenameMutationPayload.self, from: mutation.payload) else {
            return "Rename playlist"
        }

        let playlistTitle = await resolvePlaylistTitle(
            ratingKey: payload.playlistRatingKey,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )
        return "Rename \(playlistTitle) to \"\(payload.newTitle)\""
    }

    private func describePlaylistDelete(_ mutation: CDPendingMutation) async -> String {
        guard let payload = try? JSONDecoder().decode(PlaylistDeleteMutationPayload.self, from: mutation.payload) else {
            return "Delete playlist"
        }

        let playlistTitle = await resolvePlaylistTitle(
            ratingKey: payload.playlistRatingKey,
            sourceCompositeKey: payload.playlistSourceCompositeKey
        )
        return "Delete \(playlistTitle)"
    }

    // MARK: - Title Resolution

    private func resolveTrackTitle(ratingKey: String, sourceCompositeKey: String) async -> String {
        if let track = try? await libraryRepository.fetchTrack(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey) {
            return track.title
        }
        return ratingKey
    }

    private func resolvePlaylistTitle(ratingKey: String, sourceCompositeKey: String) async -> String {
        if let playlist = try? await playlistRepository.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey) {
            return playlist.title
        }
        return ratingKey
    }
}
