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
        let clearLyricsCache: (_ ratingKey: String, _ sourceCompositeKey: String) -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Deletes completed downloads whose track is no longer referenced by any
    /// offline target membership.
    func removeOrphanedCompletedDownloads() async throws -> Int {
        let completedDownloads = try await dependencies.downloadManager.fetchCompletedDownloads()
        var removedCount = 0

        for download in completedDownloads {
            guard let track = download.track,
                  let sourceCompositeKey = track.sourceCompositeKey else {
                continue
            }

            let reference = OfflineTrackReference(
                trackRatingKey: track.ratingKey,
                trackSourceCompositeKey: sourceCompositeKey
            )

            guard try await dependencies.targetRepository.membershipCount(for: reference) == 0 else {
                continue
            }

            try await dependencies.downloadManager.deleteDownload(
                forTrackRatingKey: reference.trackRatingKey,
                sourceCompositeKey: reference.trackSourceCompositeKey
            )
            dependencies.clearLyricsCache(
                reference.trackRatingKey,
                reference.trackSourceCompositeKey
            )
            removedCount += 1
        }

        _ = try await dependencies.downloadManager.removeOrphanedDownloadFiles()
        return removedCount
    }
}
