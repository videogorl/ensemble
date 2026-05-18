import EnsemblePersistence
import Foundation

@MainActor
struct OfflineDownloadProgressState {
    let snapshots: [OfflineDownloadTargetSnapshot]
    let activeDownloadTrackIdentities: Set<String>
}

@MainActor
enum OfflineDownloadTargetedProgressRefreshResult {
    case snapshots([OfflineDownloadTargetSnapshot])
    case requiresFullRefresh
}

/// Owns target progress recomputation and target snapshot cache state.
/// OfflineDownloadService remains the UI-facing publisher, while this controller
/// centralizes the repository math used by targeted and full progress refreshes.
@MainActor
final class OfflineDownloadTargetProgressController {
    struct Dependencies {
        let downloadManager: DownloadManagerProtocol
        let targetRepository: OfflineDownloadTargetRepositoryProtocol
        let canExecuteDownloads: @MainActor () -> Bool
        let isQueueRunning: @MainActor () -> Bool
        let reconcileTarget: @MainActor (_ targetKey: String) async throws -> Void
    }

    private let dependencies: Dependencies
    private var downloadedBytesByTargetKey: [String: Int64] = [:]
    private var failedTracksByTargetKey: [String: Int] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func refreshTargetSnapshots() async -> [OfflineDownloadTargetSnapshot]? {
        do {
            return try await makeTargetSnapshots()
        } catch {
            EnsembleLogger.debug("Failed fetching offline target snapshots: \(error.localizedDescription)")
            return nil
        }
    }

    /// Refreshes only the targets that contain the given track.
    func refreshTargetsForTrack(
        ratingKey: String,
        sourceCompositeKey: String
    ) async -> OfflineDownloadTargetedProgressRefreshResult {
        do {
            let reference = OfflineTrackReference(
                trackRatingKey: ratingKey,
                trackSourceCompositeKey: sourceCompositeKey
            )
            let targetKeys = try await dependencies.targetRepository.fetchTargetKeys(containing: reference)
            for key in targetKeys {
                await refreshTargetProgress(forTargetKey: key)
            }
            return .snapshots(try await makeTargetSnapshots())
        } catch {
            EnsembleLogger.debug("Failed targeted refresh for track \(ratingKey): \(error.localizedDescription)")
            return .requiresFullRefresh
        }
    }

    func refreshAllTargetProgresses() async -> OfflineDownloadProgressState? {
        do {
            let allTargets = try await dependencies.targetRepository.fetchTargets()
            for target in allTargets {
                await refreshTargetProgress(forTargetKey: target.key)
            }

            var snapshots = try await makeTargetSnapshots()
            let activeKeys = try await activeDownloadTrackIdentities()

            // Self-heal orphaned targets after publishing stale-but-useful counts.
            // This keeps the service free of target membership repair details.
            if await reconcileOrphanedTargets() {
                snapshots = try await makeTargetSnapshots()
            }

            return OfflineDownloadProgressState(
                snapshots: snapshots,
                activeDownloadTrackIdentities: activeKeys
            )
        } catch {
            EnsembleLogger.debug("Failed refreshing offline target progress: \(error.localizedDescription)")
            return nil
        }
    }

    func refreshActiveDownloadTrackIdentities() async -> Set<String>? {
        do {
            return try await activeDownloadTrackIdentities()
        } catch {
            EnsembleLogger.debug("Failed refreshing active download track identities: \(error.localizedDescription)")
            return nil
        }
    }

    func refreshTargetProgress(forTargetKey targetKey: String) async {
        do {
            let references = try await dependencies.targetRepository.fetchTrackReferences(targetKey: targetKey)
            guard !references.isEmpty else {
                try await updateEmptyTargetProgress(targetKey: targetKey)
                return
            }

            let downloadsByKey = try await dependencies.downloadManager.fetchDownloadsBatch(forReferences: references)
            let progress = makeProgress(for: references, downloadsByKey: downloadsByKey)

            try await dependencies.targetRepository.updateTarget(
                key: targetKey,
                status: progress.status,
                totalTrackCount: progress.totalTrackCount,
                completedTrackCount: progress.completedTrackCount,
                progress: progress.progress,
                lastError: progress.firstFailure
            )
            downloadedBytesByTargetKey[targetKey] = progress.downloadedBytes
            failedTracksByTargetKey[targetKey] = progress.failedTrackCount
        } catch {
            EnsembleLogger.debug("Failed refreshing target progress for \(targetKey): \(error.localizedDescription)")
        }
    }

    private func makeTargetSnapshots() async throws -> [OfflineDownloadTargetSnapshot] {
        let fetched = try await dependencies.targetRepository.fetchTargets()
        let existingTargetKeys = Set(fetched.map(\.key))
        downloadedBytesByTargetKey = downloadedBytesByTargetKey.filter { existingTargetKeys.contains($0.key) }
        failedTracksByTargetKey = failedTracksByTargetKey.filter { existingTargetKeys.contains($0.key) }

        return fetched.map {
            OfflineDownloadTargetSnapshot(
                id: $0.key,
                key: $0.key,
                kind: $0.targetKind,
                ratingKey: $0.ratingKey,
                sourceCompositeKey: $0.sourceCompositeKey,
                displayName: $0.displayName ?? Self.defaultDisplayName(for: $0),
                status: $0.targetStatus,
                totalTrackCount: Int($0.totalTrackCount),
                completedTrackCount: Int($0.completedTrackCount),
                downloadedBytes: downloadedBytesByTargetKey[$0.key] ?? 0,
                progress: $0.progress,
                failedTrackCount: failedTracksByTargetKey[$0.key] ?? 0
            )
        }
    }

    private func updateEmptyTargetProgress(targetKey: String) async throws {
        // Preserve stale counts for orphaned targets so the UI can show queued work
        // while membership reconciliation rebuilds the target in the background.
        let existingTarget = try? await dependencies.targetRepository.fetchTarget(key: targetKey)
        downloadedBytesByTargetKey[targetKey] = 0
        failedTracksByTargetKey[targetKey] = 0

        if let existing = existingTarget, existing.totalTrackCount > 0 {
            try await dependencies.targetRepository.updateTarget(
                key: targetKey,
                status: .pending,
                totalTrackCount: Int(existing.totalTrackCount),
                completedTrackCount: 0,
                progress: 0,
                lastError: nil
            )
            EnsembleLogger.debug("Orphaned download target \(targetKey): preserved stale count of \(existing.totalTrackCount) tracks")
        } else {
            try await dependencies.targetRepository.updateTarget(
                key: targetKey,
                status: .completed,
                totalTrackCount: 0,
                completedTrackCount: 0,
                progress: 1,
                lastError: nil
            )
        }
    }

    private func makeProgress(
        for references: [OfflineTrackReference],
        downloadsByKey: [String: CDDownload]
    ) -> TargetProgress {
        var completed = 0
        var downloading = 0
        var pending = 0
        var paused = 0
        var failed = 0
        var firstFailure: String?
        var downloadedBytes: Int64 = 0

        for reference in references {
            let lookupKey = "\(reference.trackSourceCompositeKey)|\(reference.trackRatingKey)"
            guard let download = downloadsByKey[lookupKey] else {
                pending += 1
                continue
            }

            switch download.downloadStatus {
            case .completed:
                completed += 1
                downloadedBytes += max(download.fileSize, 0)
            case .downloading:
                downloading += 1
            case .pending:
                pending += 1
            case .paused:
                paused += 1
            case .failed:
                failed += 1
                if firstFailure == nil {
                    firstFailure = download.error
                }
            }
        }

        let total = references.count
        let progress = total > 0 ? Float(completed) / Float(total) : 1

        let status: CDOfflineDownloadTarget.Status
        if failed > 0 {
            status = .failed
        } else if completed >= total {
            status = .completed
        } else if downloading > 0 || (dependencies.isQueueRunning() && pending > 0) {
            status = .downloading
        } else if !dependencies.canExecuteDownloads() && (pending > 0 || paused > 0) {
            status = .paused
        } else {
            status = .pending
        }

        return TargetProgress(
            status: status,
            totalTrackCount: total,
            completedTrackCount: completed,
            progress: progress,
            firstFailure: firstFailure,
            downloadedBytes: downloadedBytes,
            failedTrackCount: failed
        )
    }

    /// Detects targets with zero memberships but non-zero stale total track counts.
    private func reconcileOrphanedTargets() async -> Bool {
        do {
            let allTargets = try await dependencies.targetRepository.fetchTargets()
            var reconciledAny = false

            for target in allTargets {
                let memberships = try await dependencies.targetRepository.fetchTrackReferences(targetKey: target.key)
                guard memberships.isEmpty && target.totalTrackCount > 0 else { continue }

                EnsembleLogger.debug("Reconciling orphaned target \(target.key) (stale count: \(target.totalTrackCount))")
                try? await dependencies.reconcileTarget(target.key)
                reconciledAny = true
            }

            return reconciledAny
        } catch {
            EnsembleLogger.debug("Failed reconciling orphaned targets: \(error.localizedDescription)")
            return false
        }
    }

    private func activeDownloadTrackIdentities() async throws -> Set<String> {
        let pending = try await dependencies.downloadManager.fetchPendingDownloads()
        return Set(pending.compactMap { download -> String? in
            guard let track = download.track else { return nil }
            guard let sourceCompositeKey = track.sourceCompositeKey, !sourceCompositeKey.isEmpty else {
                return track.ratingKey
            }
            return "\(sourceCompositeKey)||\(track.ratingKey)"
        })
    }

    private static func defaultDisplayName(for target: CDOfflineDownloadTarget) -> String {
        switch target.targetKind {
        case .library:
            return "Library"
        case .album:
            return "Album"
        case .artist:
            return "Artist"
        case .playlist:
            return "Playlist"
        case .favorites:
            return "Favorites"
        }
    }
}

private struct TargetProgress {
    let status: CDOfflineDownloadTarget.Status
    let totalTrackCount: Int
    let completedTrackCount: Int
    let progress: Float
    let firstFailure: String?
    let downloadedBytes: Int64
    let failedTrackCount: Int
}
