import EnsemblePersistence
import Foundation

/// Resolves target memberships and download records for offline targets.
/// OfflineDownloadService stays responsible for UI-facing orchestration while this
/// type owns the membership + orphan-cleanup algorithm.
@MainActor
final class DownloadTargetReconciler {
    struct TargetDescriptor: Equatable {
        let key: String
        let kind: CDOfflineDownloadTarget.Kind
        let ratingKey: String?
        let sourceCompositeKey: String?
    }

    struct ReconcileResult: Equatable {
        let trackReferenceCount: Int
        let newPendingCount: Int
        let downloadQuality: String
    }

    struct Dependencies {
        let targetRepository: OfflineDownloadTargetRepositoryProtocol
        let libraryRepository: LibraryRepositoryProtocol
        let playlistRepository: PlaylistRepositoryProtocol
        let downloadManager: DownloadManagerProtocol
        let currentDownloadQuality: @MainActor () -> String
        let clearLyricsCaches: ([OfflineTrackReference]) async -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func reconcileTarget(_ target: TargetDescriptor) async throws -> ReconcileResult {
        let previousReferences = try await dependencies.targetRepository.fetchTrackReferences(targetKey: target.key)
        let trackReferences = try await resolveTrackReferences(for: target)
        try await dependencies.targetRepository.replaceMemberships(targetKey: target.key, trackReferences: trackReferences)

        let downloadQuality = dependencies.currentDownloadQuality()
        let newPendingCount = try await dependencies.downloadManager.batchCreateDownloads(
            references: trackReferences,
            quality: downloadQuality
        )

        let removedReferences = Array(Set(previousReferences).subtracting(Set(trackReferences)))
        let unreferenced = try await dependencies.targetRepository.unreferencedTrackReferences(
            from: removedReferences
        )
        try await dependencies.downloadManager.deleteDownloads(forReferences: unreferenced)
        await dependencies.clearLyricsCaches(unreferenced)

        return ReconcileResult(
            trackReferenceCount: trackReferences.count,
            newPendingCount: newPendingCount,
            downloadQuality: downloadQuality
        )
    }

    private func resolveTrackReferences(for target: TargetDescriptor) async throws -> [OfflineTrackReference] {
        switch target.kind {
        case .library:
            guard let sourceKey = target.sourceCompositeKey else { return [] }
            let tracks = try await dependencies.libraryRepository.fetchTracks(forSource: sourceKey)
            return normalizedTrackReferences(from: tracks)

        case .album:
            guard let ratingKey = target.ratingKey else { return [] }
            let tracks: [CDTrack]
            if let sourceKey = target.sourceCompositeKey {
                tracks = try await dependencies.libraryRepository.fetchTracks(
                    forAlbum: ratingKey,
                    sourceCompositeKey: sourceKey
                )
            } else {
                tracks = try await dependencies.libraryRepository.fetchTracks(forAlbum: ratingKey)
            }
            return normalizedTrackReferences(from: tracks)

        case .artist:
            guard let ratingKey = target.ratingKey else { return [] }
            let tracks: [CDTrack]
            if let sourceKey = target.sourceCompositeKey {
                tracks = try await dependencies.libraryRepository.fetchTracks(
                    forArtist: ratingKey,
                    sourceCompositeKey: sourceKey
                )
            } else {
                tracks = try await dependencies.libraryRepository.fetchTracks(forArtist: ratingKey)
            }
            return normalizedTrackReferences(from: tracks)

        case .playlist:
            guard let ratingKey = target.ratingKey else { return [] }
            guard let playlist = try await dependencies.playlistRepository.fetchPlaylist(
                ratingKey: ratingKey,
                sourceCompositeKey: target.sourceCompositeKey
            ) else {
                return []
            }
            return normalizedTrackReferences(from: playlist.tracksArray)

        case .favorites:
            let tracks = try await dependencies.libraryRepository.fetchFavoriteTracks()
            return normalizedTrackReferences(from: tracks)
        }
    }

    private func normalizedTrackReferences(from tracks: [CDTrack]) -> [OfflineTrackReference] {
        let references = tracks.compactMap { track -> OfflineTrackReference? in
            guard let sourceCompositeKey = track.sourceCompositeKey else { return nil }
            return OfflineTrackReference(
                trackRatingKey: track.ratingKey,
                trackSourceCompositeKey: sourceCompositeKey
            )
        }

        return Array(Set(references)).sorted {
            if $0.trackSourceCompositeKey != $1.trackSourceCompositeKey {
                return $0.trackSourceCompositeKey < $1.trackSourceCompositeKey
            }
            return $0.trackRatingKey < $1.trackRatingKey
        }
    }
}
