import EnsemblePersistence
import Foundation

/// Owns best-effort cleanup for completed downloads that no longer belong to any
/// offline target membership. This keeps the visible download targets and the
/// persisted track files from drifting apart when target records disappear.
@MainActor
final class OfflineDownloadCleanupCoordinator {
    struct Dependencies {
        let downloadManager: DownloadManagerProtocol
        let targetRepository: OfflineDownloadTargetRepositoryProtocol
        let clearLyricsCaches: ([OfflineTrackReference]) async -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Deletes completed downloads whose track is no longer referenced by any
    /// offline target membership.
    func removeOrphanedCompletedDownloads() async throws -> Int {
        let completedDownloads = try await dependencies.downloadManager.fetchCompletedDownloads()
        let references = completedDownloads.compactMap { download -> OfflineTrackReference? in
            guard let track = download.track,
                  let sourceCompositeKey = track.sourceCompositeKey else { return nil }
            return OfflineTrackReference(
                trackRatingKey: track.ratingKey,
                trackSourceCompositeKey: sourceCompositeKey
            )
        }
        let orphanedReferences = try await dependencies.targetRepository.unreferencedTrackReferences(
            from: references
        )
        try await dependencies.downloadManager.deleteDownloads(forReferences: orphanedReferences)
        await dependencies.clearLyricsCaches(orphanedReferences)

        _ = try await dependencies.downloadManager.removeOrphanedDownloadFiles()
        return orphanedReferences.count
    }
}
