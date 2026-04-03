import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

public struct OfflineDownloadTargetSnapshot: Identifiable {
    public let id: String
    public let key: String
    public let kind: CDOfflineDownloadTarget.Kind
    public let ratingKey: String?
    public let sourceCompositeKey: String?
    public let displayName: String
    public let status: CDOfflineDownloadTarget.Status
    public let totalTrackCount: Int
    public let completedTrackCount: Int
    public let downloadedBytes: Int64
    public let progress: Float
    /// Number of completed tracks whose download quality differs from the current setting
    public let qualityMismatchCount: Int
    /// Number of tracks in a failed state
    public let failedTrackCount: Int

    public var isComplete: Bool {
        totalTrackCount > 0 && completedTrackCount >= totalTrackCount
    }

    /// True when this target has actionable issues a refresh could resolve
    public var needsRefresh: Bool {
        qualityMismatchCount > 0 || failedTrackCount > 0
    }
}

public struct OfflineDownloadQualityRefreshResult: Sendable {
    public let requeuedCount: Int
    public let skippedUnsupportedCount: Int

    public init(requeuedCount: Int, skippedUnsupportedCount: Int) {
        self.requeuedCount = requeuedCount
        self.skippedUnsupportedCount = skippedUnsupportedCount
    }
}

/// Describes why the download queue is currently idle or paused
public enum QueueStatusReason: Equatable, Sendable {
    case idle
    case downloading
    case waitingForWiFi
    case offline
    case paused
}

/// Tracks progress of a target removal operation (per-track file deletion)
public struct RemovalProgress: Equatable {
    public let targetTitle: String
    public let completed: Int
    public let total: Int
}

enum DownloadWorkMode: Equatable, Sendable {
    case interactivePlayback
    case foregroundIdle
    case background
}

@MainActor
public final class OfflineDownloadService: ObservableObject {
    /// Posted when download targets change (enable/disable/quality refresh) so track-displaying VMs can re-fetch
    public static let downloadsDidChange = Notification.Name("OfflineDownloadsDidChange")
    private enum DownloadProcessingError: LocalizedError {
        case invalidHTTPStatus(Int)
        case emptyPayload(String)
        case truncatedPayload(fileDuration: Double, expectedDuration: Double)

        var errorDescription: String? {
            switch self {
            case .invalidHTTPStatus(let statusCode):
                return "Download HTTP status \(statusCode)"
            case .emptyPayload(let url):
                return "Download payload was empty for \(url)"
            case .truncatedPayload(let fileDuration, let expectedDuration):
                return "Download truncated: file is \(String(format: "%.1f", fileDuration))s but expected \(String(format: "%.1f", expectedDuration))s"
            }
        }
    }

    /// Transport-level error for incomplete byte transfer.
    /// Separate from DownloadProcessingError because these are retryable —
    /// the download should be re-queued as pending, not permanently failed.
    private enum DownloadTransferError: LocalizedError {
        case incompleteTransfer(bytesReceived: Int64, bytesExpected: Int64, percentComplete: Int)

        var errorDescription: String? {
            switch self {
            case .incompleteTransfer(let received, let expected, let pct):
                return "Incomplete transfer: received \(received)/\(expected) bytes (\(pct)%)"
            }
        }
    }

    /// Value-type snapshot of CDDownload + CDTrack properties captured before async download begins.
    /// Prevents issues when viewContext.reset() invalidates managed objects mid-download
    /// or when cascade deletes remove the CDDownload from the store during sync.
    private struct DownloadContext {
        let downloadObjectID: NSManagedObjectID
        let trackRatingKey: String
        let sourceCompositeKey: String
        let trackDuration: Int64
        let downloadQuality: String?
        let domainTrack: Track
        /// sourceCompositeKey with colons replaced for safe file naming
        let safeSourceKey: String
        // For artwork caching
        let trackThumbPath: String?
        let albumRatingKey: String?
        let albumThumbPath: String?
    }

    @Published public private(set) var targets: [OfflineDownloadTargetSnapshot] = []
    @Published public private(set) var isQueueRunning = false
    /// Current reason the queue is idle/paused — observed by detail views for status banners
    @Published public private(set) var queueStatusReason: QueueStatusReason = .idle
    /// Per-target removal progress — keyed by target key, shown in DownloadsView during cleanup
    @Published public private(set) var removalInProgress: [String: RemovalProgress] = [:]
    /// Track ratingKeys currently pending or actively downloading — used by TrackRow to show spinners.
    @Published public private(set) var activeDownloadRatingKeys: Set<String> = []

    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let backgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let toastCenter: ToastCenter
    private let lyricsService: LyricsService

    private var cancellables = Set<AnyCancellable>()
    private var lastObservedSyncBySource: [String: Date] = [:]

    private var downloadedBytesByTargetKey: [String: Int64] = [:]
    private var qualityMismatchByTargetKey: [String: Int] = [:]
    private var failedTracksByTargetKey: [String: Int] = [:]

    /// Debounced notification task so individual download completions don't
    /// spam `downloadsDidChange` during bulk queue processing.
    private var downloadChangeNotificationTask: Task<Void, Never>?
    /// Coalesces expensive target progress refreshes so queue/network churn
    /// doesn't rebuild every target on each state transition.
    private var fullProgressRefreshTask: Task<Void, Never>?
    private var hasQueuedFullProgressRefresh = false

    /// Serializes post-download frequency analysis so only one FFT runs at a time.
    /// Supports suspend/resume for app lifecycle and priority bumping for the playing track.
    private let sidecarAnalysisQueue = SidecarAnalysisQueue()
    private var isUserPaused = false
    private var isLowPowerSuspended = false
    private var isAppInBackground = false
    private var allowsBackgroundContinuation = false
    private var isPlaybackSensitive = false
    private let retryPolicy = DownloadRetryPolicy()
    private lazy var queueCoordinator = DownloadQueueCoordinator(
        dependencies: .init(
            canRunAutomatically: { [weak self] in self?.canRunQueueAutomatically ?? false },
            setQueueRunning: { [weak self] value in self?.isQueueRunning = value },
            refreshQueueStatus: { [weak self] in self?.refreshQueueStatusReason() },
            fetchPendingCount: { [weak self] in
                guard let self else { return 0 }
                return (try? await self.downloadManager.fetchPendingDownloads().count) ?? 0
            },
            currentWorkMode: { [weak self] in self?.currentDownloadWorkMode ?? .foregroundIdle },
            queueWorkerCount: { [weak self] pendingCount, workMode in
                self?.queueWorkerCount(forPendingCount: pendingCount, workMode: workMode) ?? 1
            },
            runWorker: { [weak self] applyInteractiveCooldown in
                guard let self else { return false }
                return await self.workerLoop(applyInteractiveCooldown: applyInteractiveCooldown)
            },
            applyNetworkPolicy: { [weak self] in
                try? await self?.applyNetworkPolicy()
            },
            finishBackgroundTask: { [weak self] success in
                self?.backgroundExecutionCoordinator.finishCurrentTask(success: success)
            },
            showCompletionToast: { [weak self] in
                self?.toastCenter.show(ToastPayload(
                    style: .success,
                    iconSystemName: "arrow.down.circle.fill",
                    title: "Downloads Complete"
                ))
            }
        )
    )

    private static let maxConcurrentDownloads = 2
    private static let interactivePlaybackConcurrentDownloads = 1
    private static let interactivePlaybackRefreshDelayNs: UInt64 = 1_500_000_000
    private static let foregroundIdleRefreshDelayNs: UInt64 = 250_000_000
    private static let backgroundRefreshDelayNs: UInt64 = 2_500_000_000
    private static let interactivePlaybackWorkerCooldownNs: UInt64 = 750_000_000

    public init(
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        backgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        toastCenter: ToastCenter,
        lyricsService: LyricsService
    ) {
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.backgroundExecutionCoordinator = backgroundExecutionCoordinator
        self.artworkDownloadManager = artworkDownloadManager
        self.toastCenter = toastCenter
        self.lyricsService = lyricsService

        // Clean up legacy keys from the old transcode blacklist approach.
        UserDefaults.standard.removeObject(forKey: "offlineTranscodeUnsupportedServerKeys")
        UserDefaults.standard.removeObject(forKey: "offlineTranscodeProfileV2Migrated")

        backgroundExecutionCoordinator.onExecutionRequested = { [weak self] in
            Task { @MainActor in
                await self?.handleBackgroundExecutionRequest()
            }
        }
        backgroundExecutionCoordinator.onExpiration = { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }

        observeNetworkState()
        observeSyncCompletions()

        Task {
            // Self-heal download metadata first: verify files on disk,
            // mark missing/invalid downloads as failed so progress counts
            // are accurate before we compute target state.
            _ = try? await downloadManager.fetchDownloads()

            // Scan for truncated audio files that passed basic payload checks
            // but have significantly shorter duration than expected (e.g. interrupted downloads)
            await scanForTruncatedDownloads()

            await refreshState()
            // Reset stale .downloading status from previous app session.
            // At init time, no download can be actively in-progress.
            try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .pending)
            startQueueIfNeeded()
        }
    }

    // MARK: - Public API

    /// Called when PMS download queue completes an item (via WebSocket activity event).
    /// Restarts the download queue if it's idle, ensuring prepared downloads are picked up.
    public func handleDownloadQueueCompleted() async {
        EnsembleLogger.debug("⬇️ WebSocket: download queue completed — queueTask=\(queueCoordinator.hasActiveTask ? "active" : "nil"), isQueueRunning=\(isQueueRunning)")
        startQueueIfNeeded()
    }

    public func refreshState() async {
        await refreshTargetSnapshots()
        await refreshAllTargetProgresses()
    }

    /// Extended refresh that also runs download file self-healing.
    /// Use for pull-to-refresh to detect missing files and orphaned targets.
    public func refreshStateWithHealing() async {
        // Verify files on disk, mark missing/invalid downloads as failed
        _ = try? await downloadManager.fetchDownloads()
        // Catch truncated audio files (interrupted downloads that passed basic checks)
        await scanForTruncatedDownloads()
        await refreshState()
    }

    public func isLibraryDownloadEnabled(sourceCompositeKey: String) -> Bool {
        targets.contains { $0.key == Self.targetKey(kind: .library, ratingKey: nil, sourceCompositeKey: sourceCompositeKey) }
    }

    public func isAlbumDownloadEnabled(_ album: Album) -> Bool {
        guard let sourceCompositeKey = album.sourceCompositeKey else { return false }
        return targets.contains {
            $0.key == Self.targetKey(
                kind: .album,
                ratingKey: album.id,
                sourceCompositeKey: sourceCompositeKey
            )
        }
    }

    public func isArtistDownloadEnabled(_ artist: Artist) -> Bool {
        guard let sourceCompositeKey = artist.sourceCompositeKey else { return false }
        return targets.contains {
            $0.key == Self.targetKey(
                kind: .artist,
                ratingKey: artist.id,
                sourceCompositeKey: sourceCompositeKey
            )
        }
    }

    public func isPlaylistDownloadEnabled(_ playlist: Playlist) -> Bool {
        guard let sourceCompositeKey = playlist.sourceCompositeKey else { return false }
        return targets.contains {
            $0.key == Self.targetKey(
                kind: .playlist,
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey
            )
        }
    }

    // MARK: - Favorites Download Target

    /// Target key for the cross-library favorites download target
    public static let favoritesTargetKey = "offline:favorites:*:*"

    public func isFavoritesDownloadEnabled() -> Bool {
        targets.contains { $0.key == Self.favoritesTargetKey }
    }

    public func setFavoritesDownloadEnabled(isEnabled: Bool) async {
        let key = Self.favoritesTargetKey
        if isEnabled {
            await enableTarget(
                key: key,
                kind: .favorites,
                ratingKey: nil,
                sourceCompositeKey: nil,
                displayName: "Favorites"
            )
        } else {
            await disableTarget(key: key)
        }
    }

    /// Reconciles the favorites download target if it exists.
    /// Called after rating changes and source syncs to keep downloaded favorites in sync.
    public func reconcileFavoritesTargetIfEnabled() async {
        guard isFavoritesDownloadEnabled() else { return }
        do {
            try await reconcileTarget(key: Self.favoritesTargetKey)
            await refreshTargetSnapshots()
            startQueueIfNeeded()
        } catch {
            EnsembleLogger.debug("❌ Failed reconciling favorites target: \(error.localizedDescription)")
        }
    }

    // MARK: - Library Download Target

    public func setLibraryDownloadEnabled(
        sourceCompositeKey: String,
        displayName: String,
        isEnabled: Bool
    ) async {
        let key = Self.targetKey(kind: .library, ratingKey: nil, sourceCompositeKey: sourceCompositeKey)
        if isEnabled {
            await enableTarget(
                key: key,
                kind: .library,
                ratingKey: nil,
                sourceCompositeKey: sourceCompositeKey,
                displayName: displayName
            )
        } else {
            await disableTarget(key: key)
        }
    }

    public func setAlbumDownloadEnabled(_ album: Album, isEnabled: Bool) async {
        guard let sourceCompositeKey = album.sourceCompositeKey else { return }
        let key = Self.targetKey(kind: .album, ratingKey: album.id, sourceCompositeKey: sourceCompositeKey)
        if isEnabled {
            await enableTarget(
                key: key,
                kind: .album,
                ratingKey: album.id,
                sourceCompositeKey: sourceCompositeKey,
                displayName: album.title
            )
            // Cache album artwork for offline use
            await cacheArtworkForTarget(
                ratingKey: album.id,
                thumbPath: album.thumbPath,
                sourceKey: sourceCompositeKey,
                type: .album
            )
        } else {
            await disableTarget(key: key)
        }
    }

    public func setArtistDownloadEnabled(_ artist: Artist, isEnabled: Bool) async {
        guard let sourceCompositeKey = artist.sourceCompositeKey else { return }
        let key = Self.targetKey(kind: .artist, ratingKey: artist.id, sourceCompositeKey: sourceCompositeKey)
        if isEnabled {
            await enableTarget(
                key: key,
                kind: .artist,
                ratingKey: artist.id,
                sourceCompositeKey: sourceCompositeKey,
                displayName: artist.name
            )
            // Cache artist artwork for offline use
            await cacheArtworkForTarget(
                ratingKey: artist.id,
                thumbPath: artist.thumbPath,
                sourceKey: sourceCompositeKey,
                type: .artist
            )
        } else {
            await disableTarget(key: key)
        }
    }

    public func setPlaylistDownloadEnabled(_ playlist: Playlist, isEnabled: Bool) async {
        guard let sourceCompositeKey = playlist.sourceCompositeKey else { return }
        let key = Self.targetKey(kind: .playlist, ratingKey: playlist.id, sourceCompositeKey: sourceCompositeKey)
        if isEnabled {
            await enableTarget(
                key: key,
                kind: .playlist,
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey,
                displayName: playlist.title
            )
            // Cache playlist composite artwork for offline use
            await cacheArtworkForTarget(
                ratingKey: playlist.id,
                thumbPath: playlist.compositePath,
                sourceKey: sourceCompositeKey,
                type: .playlist
            )
        } else {
            await disableTarget(key: key)
        }
    }

    public func removeTarget(key: String) async {
        await disableTarget(key: key)
    }

    /// Remove all download targets, memberships, and downloaded files.
    public func removeAllDownloads() async {
        // Stop the download queue first.
        queueCoordinator.cancelCurrentTask()
        isQueueRunning = false
        refreshQueueStatusReason()

        do {
            // Delete all targets and memberships from CoreData
            try await targetRepository.deleteAllTargets()

            // Delete all download records and files from disk
            try await downloadManager.deleteAllDownloads()

            // Clear local state
            removalInProgress.removeAll()
            targets.removeAll()

            CoreDataStack.shared.refreshViewContext()
            NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)

            EnsembleLogger.debug("🗑️ Removed all downloads, targets, and files")
        } catch {
            EnsembleLogger.debug("❌ Failed to remove all downloads: \(error.localizedDescription)")
        }
    }

    /// Refresh a single target: reconcile memberships, re-queue quality-mismatched and failed downloads
    public func refreshTarget(key: String) async {
        do {
            // Re-reconcile memberships (adds new tracks, drops orphans)
            try await reconcileTarget(key: key)

            // Re-queue completed downloads whose quality doesn't match the current setting
            let desiredQuality = currentDownloadQuality()
            let references = try await targetRepository.fetchTrackReferences(targetKey: key)
            for ref in references {
                guard let download = try? await downloadManager.fetchDownload(
                    forTrackRatingKey: ref.trackRatingKey,
                    sourceCompositeKey: ref.trackSourceCompositeKey
                ) else { continue }

                let status = download.downloadStatus

                // Re-queue quality-mismatched completed downloads
                if status == .completed,
                   let existing = download.quality, existing != desiredQuality {
                    _ = try await downloadManager.createDownload(
                        forTrackRatingKey: ref.trackRatingKey,
                        sourceCompositeKey: ref.trackSourceCompositeKey,
                        quality: desiredQuality
                    )
                    continue
                }

                // Retry failed downloads
                if status == .failed {
                    try await downloadManager.deleteDownload(
                        forTrackRatingKey: ref.trackRatingKey,
                        sourceCompositeKey: ref.trackSourceCompositeKey
                    )
                    _ = try await downloadManager.createDownload(
                        forTrackRatingKey: ref.trackRatingKey,
                        sourceCompositeKey: ref.trackSourceCompositeKey,
                        quality: desiredQuality
                    )
                }
            }

            await refreshAllTargetProgresses()
            startQueueIfNeeded()

            let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)
        } catch {
            EnsembleLogger.debug("❌ OfflineDownloadService: Failed refreshing target \(key): \(error.localizedDescription)")
        }
    }

    public func handlePlaylistRefreshCompleted(serverSourceKey: String) async {
        await reconcilePlaylistTargets(forServerSourceKey: serverSourceKey)
    }

    /// Requeue a failed/offline download for a specific track and wake the queue immediately.
    public func retryDownload(trackRatingKey: String, sourceCompositeKey: String?) async {
        do {
            let existing = try await downloadManager.fetchDownload(
                forTrackRatingKey: trackRatingKey,
                sourceCompositeKey: sourceCompositeKey
            )
            let quality = existing?.quality ?? currentDownloadQuality()

            try await downloadManager.deleteDownload(
                forTrackRatingKey: trackRatingKey,
                sourceCompositeKey: sourceCompositeKey
            )
            _ = try await downloadManager.createDownload(
                forTrackRatingKey: trackRatingKey,
                sourceCompositeKey: sourceCompositeKey,
                quality: quality
            )

            EnsembleLogger.debug(
                "🔁 Retrying download: track=\(trackRatingKey) source=\(sourceCompositeKey ?? "nil") quality=\(quality)"
            )

            await refreshAllTargetProgresses()
            startQueueIfNeeded()

            let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)
        } catch {
            EnsembleLogger.debug(
                "❌ Retry download failed: track=\(trackRatingKey) source=\(sourceCompositeKey ?? "nil") reason=\(error.localizedDescription)"
            )
        }
    }

    /// Re-queue completed downloads that do not match the current quality setting.
    /// Returns a summary including re-queued tracks and tracks skipped due to known
    /// server-side transcode limitations.
    public func requeueCompletedDownloadsForCurrentQuality() async -> OfflineDownloadQualityRefreshResult {
        do {
            let desiredQuality = currentDownloadQuality()
            let completedDownloads = try await downloadManager.fetchCompletedDownloads()
            var requeuedCount = 0

            for download in completedDownloads {
                guard let track = download.track,
                      let sourceCompositeKey = track.sourceCompositeKey else {
                    continue
                }

                let currentQuality = download.quality ?? "original"
                guard currentQuality != desiredQuality else { continue }

                let reference = OfflineTrackReference(
                    trackRatingKey: track.ratingKey,
                    trackSourceCompositeKey: sourceCompositeKey
                )

                // Only refresh downloads still referenced by at least one active target.
                guard try await targetRepository.hasAnyMembership(for: reference) else {
                    continue
                }

                _ = try await downloadManager.createDownload(
                    forTrackRatingKey: track.ratingKey,
                    sourceCompositeKey: sourceCompositeKey,
                    quality: desiredQuality
                )
                requeuedCount += 1
            }

            // Update quality on pending/downloading downloads that have the wrong quality.
            // Without this, workers pick up stale-quality downloads from a previous
            // re-queue before the new quality was set.
            let allDownloads = try await downloadManager.fetchDownloads()
            for download in allDownloads where download.downloadStatus == .pending || download.downloadStatus == .downloading {
                let dlQuality = download.quality ?? "original"
                if dlQuality != desiredQuality {
                    try? await downloadManager.updateDownloadStatus(
                        download.objectID,
                        status: download.downloadStatus,
                        quality: desiredQuality
                    )
                }
            }

            // Also retry all failed downloads
            var retriedCount = 0
            for download in allDownloads where download.downloadStatus == .failed {
                guard let track = download.track,
                      let sourceCompositeKey = track.sourceCompositeKey else {
                    continue
                }

                let reference = OfflineTrackReference(
                    trackRatingKey: track.ratingKey,
                    trackSourceCompositeKey: sourceCompositeKey
                )
                guard try await targetRepository.hasAnyMembership(for: reference) else {
                    continue
                }

                try await downloadManager.deleteDownload(
                    forTrackRatingKey: track.ratingKey,
                    sourceCompositeKey: sourceCompositeKey
                )
                _ = try await downloadManager.createDownload(
                    forTrackRatingKey: track.ratingKey,
                    sourceCompositeKey: sourceCompositeKey,
                    quality: desiredQuality
                )
                retriedCount += 1
            }

            let totalRequeued = requeuedCount + retriedCount
            if totalRequeued > 0 {
                await refreshAllTargetProgresses()
                startQueueIfNeeded()
                let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
                backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(
                    pendingTrackCount: pendingCount
                )
            }

            EnsembleLogger.debug(
                "🔄 Refresh: re-queued \(requeuedCount) quality-mismatched + \(retriedCount) failed downloads (targetQuality=\(desiredQuality))"
            )

            if totalRequeued > 0 {
                CoreDataStack.shared.refreshViewContext()
                NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
            }

            return OfflineDownloadQualityRefreshResult(
                requeuedCount: totalRequeued,
                skippedUnsupportedCount: 0
            )
        } catch {
            EnsembleLogger.debug(
                "❌ Failed re-queueing downloads for refresh: \(error.localizedDescription)"
            )
            return OfflineDownloadQualityRefreshResult(requeuedCount: 0, skippedUnsupportedCount: 0)
        }
    }

    // MARK: - Target Lifecycle

    private func enableTarget(
        key: String,
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?,
        displayName: String
    ) async {
        do {
            _ = try await targetRepository.upsertTarget(
                key: key,
                kind: kind,
                ratingKey: ratingKey,
                sourceCompositeKey: sourceCompositeKey,
                displayName: displayName
            )
            try await reconcileTarget(key: key)
            await refreshTargetSnapshots()
            startQueueIfNeeded()

            let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)

            CoreDataStack.shared.refreshViewContext()
            NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
        } catch {
            EnsembleLogger.debug("❌ Failed enabling offline target \(key): \(error.localizedDescription)")
        }
    }

    private func disableTarget(key: String) async {
        do {
            // Resolve title before deletion for progress UI
            let targetTitle = (try? await targetRepository.fetchTarget(key: key))?.displayName ?? key
            let previousReferences = try await targetRepository.fetchTrackReferences(targetKey: key)

            // Pre-compute which tracks are only referenced by this target BEFORE
            // deleting it. Querying after the delete is unreliable because the
            // cascade-deleted memberships are saved on a background context and the
            // view context may not have merged yet, causing membershipCount to return
            // stale (non-zero) values and skipping the file cleanup.
            var orphanedReferences = Set<OfflineTrackReference>()
            for reference in previousReferences {
                let count = try await targetRepository.membershipCount(for: reference)
                // Count of 1 means only this target references the track
                if count <= 1 {
                    orphanedReferences.insert(reference)
                }
            }

            try await targetRepository.deleteTarget(key: key)

            let total = previousReferences.count
            if total > 0 {
                removalInProgress[key] = RemovalProgress(targetTitle: targetTitle, completed: 0, total: total)
            }

            // Reference-counted cleanup: remove track files that no other target references.
            for (index, reference) in previousReferences.enumerated() {
                if orphanedReferences.contains(reference) {
                    try await downloadManager.deleteDownload(
                        forTrackRatingKey: reference.trackRatingKey,
                        sourceCompositeKey: reference.trackSourceCompositeKey
                    )
                }
                removalInProgress[key] = RemovalProgress(targetTitle: targetTitle, completed: index + 1, total: total)
            }

            removalInProgress.removeValue(forKey: key)

            await refreshTargetSnapshots()
            await refreshAllTargetProgresses()

            // Notify track-displaying VMs so they re-fetch and reflect updated offline state
            CoreDataStack.shared.refreshViewContext()
            NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
        } catch {
            removalInProgress.removeValue(forKey: key)
            EnsembleLogger.debug("❌ Failed disabling offline target \(key): \(error.localizedDescription)")
        }
    }

    private func reconcileTarget(key: String) async throws {
        guard let target = try await targetRepository.fetchTarget(key: key) else {
            return
        }

        let previousReferences = try await targetRepository.fetchTrackReferences(targetKey: key)
        let trackReferences = try await resolveTrackReferences(for: target)
        try await targetRepository.replaceMemberships(targetKey: key, trackReferences: trackReferences)

        // Queue missing tracks at the selected download quality.
        // batchCreateDownloads handles existing records (skips if quality satisfies)
        // and returns the count of newly created/re-queued pending downloads.
        let downloadQuality = currentDownloadQuality()
        let newPendingCount = try await downloadManager.batchCreateDownloads(
            references: trackReferences,
            quality: downloadQuality
        )
        if newPendingCount > 0 {
            EnsembleLogger.debug(
                "📥 reconcileTarget: key=\(key) totalRefs=\(trackReferences.count) newPending=\(newPendingCount) quality=\(downloadQuality)"
            )
        }

        // Drop orphaned files no longer referenced by any target.
        let removedReferences = Set(previousReferences).subtracting(Set(trackReferences))
        for reference in removedReferences {
            let count = try await targetRepository.membershipCount(for: reference)
            if count == 0 {
                try await downloadManager.deleteDownload(
                    forTrackRatingKey: reference.trackRatingKey,
                    sourceCompositeKey: reference.trackSourceCompositeKey
                )
            }
        }

        await refreshTargetProgress(forTargetKey: key)
    }

    private func resolveTrackReferences(for target: CDOfflineDownloadTarget) async throws -> [OfflineTrackReference] {
        let kind = target.targetKind

        switch kind {
        case .library:
            guard let sourceKey = target.sourceCompositeKey else { return [] }
            let tracks = try await libraryRepository.fetchTracks(forSource: sourceKey)
            return normalizedTrackReferences(from: tracks)

        case .album:
            guard let ratingKey = target.ratingKey else { return [] }
            let tracks: [CDTrack]
            if let sourceKey = target.sourceCompositeKey {
                tracks = try await libraryRepository.fetchTracks(forAlbum: ratingKey, sourceCompositeKey: sourceKey)
            } else {
                tracks = try await libraryRepository.fetchTracks(forAlbum: ratingKey)
            }
            return normalizedTrackReferences(from: tracks)

        case .artist:
            guard let ratingKey = target.ratingKey else { return [] }
            let tracks: [CDTrack]
            if let sourceKey = target.sourceCompositeKey {
                tracks = try await libraryRepository.fetchTracks(forArtist: ratingKey, sourceCompositeKey: sourceKey)
            } else {
                tracks = try await libraryRepository.fetchTracks(forArtist: ratingKey)
            }
            return normalizedTrackReferences(from: tracks)

        case .playlist:
            guard let ratingKey = target.ratingKey else { return [] }
            guard let playlist = try await playlistRepository.fetchPlaylist(
                ratingKey: ratingKey,
                sourceCompositeKey: target.sourceCompositeKey
            ) else {
                return []
            }
            return normalizedTrackReferences(from: playlist.tracksArray)

        case .favorites:
            let tracks = try await libraryRepository.fetchFavoriteTracks()
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

    // MARK: - Queue Control

    /// Pauses the download queue — cancels the current download task and marks
    /// any actively downloading tracks as paused so they can be resumed later.
    public func pauseQueue() async {
        isUserPaused = true
        await stopQueueForSuspension()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
    }

    /// Resumes the download queue — unpauses tracks and restarts the queue loop.
    public func resumeQueue() async {
        isUserPaused = false
        try? await applyNetworkPolicy()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
        startQueueIfNeeded()
    }

    /// Applies the Low Power Mode policy without overwriting the user's manual pause state.
    public func setLowPowerModePaused(_ isPaused: Bool) async {
        guard isLowPowerSuspended != isPaused else { return }
        isLowPowerSuspended = isPaused
        if isPaused {
            await stopQueueForSuspension()
        } else {
            try? await applyNetworkPolicy()
        }
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
        if !isPaused {
            startQueueIfNeeded()
        }
    }

    // MARK: - Sidecar Analysis Lifecycle

    /// Suspend sidecar analysis when the app backgrounds to prevent background CPU abuse.
    /// Any in-progress FFT stops at the next cancellation checkpoint (~0.1s); the
    /// interrupted item is re-queued at the front and retries when the app foregrounds.
    public func suspendSidecarAnalysis() async {
        await sidecarAnalysisQueue.suspend()
        EnsembleLogger.info("Sidecar analysis suspended — app backgrounded")
    }

    /// Resume sidecar analysis when the app foregrounds.
    public func resumeSidecarAnalysis() async {
        await sidecarAnalysisQueue.resume()
        EnsembleLogger.info("Sidecar analysis resumed — app foregrounded")
    }

    /// Subscribe to playback publishers so download work can protect active listening.
    /// Track changes still prioritize sidecar generation, while playback-state changes
    /// switch the queue into a lower-impact mode during active playback.
    public func observePlayback(
        trackPublisher: AnyPublisher<Track?, Never>,
        playbackStatePublisher: AnyPublisher<PlaybackState, Never>
    ) {
        observePlayback(trackPublisher)

        playbackStatePublisher
            .map(Self.isPlaybackSensitiveState)
            .removeDuplicates()
            .sink { [weak self] isSensitive in
                Task { @MainActor in
                    await self?.handlePlaybackSensitivityChange(isSensitive)
                }
            }
            .store(in: &cancellables)
    }

    /// Subscribe to a playback track publisher and prioritize sidecar generation for the
    /// playing track. If the track has a local file but no sidecar yet, it moves to the
    /// front of the queue so the visualizer is ready quickly.
    /// Call once after init, passing PlaybackService.currentTrackPublisher.
    public func observePlayback(_ publisher: AnyPublisher<Track?, Never>) {
        publisher
            .compactMap { $0?.localFilePath }
            .removeDuplicates()
            .sink { [weak self] localPath in
                guard let self else { return }
                let sourceURL = URL(fileURLWithPath: localPath)
                let sidecarURL = sourceURL.appendingPathExtension("freq")
                Task {
                    await self.sidecarAnalysisQueue.prioritize(sourceURL: sourceURL, sidecarURL: sidecarURL)
                }
            }
            .store(in: &cancellables)
    }

    /// Stops all in-progress downloads immediately and re-queues them as pending.
    /// Used when download quality changes to avoid continuing old-quality downloads.
    public func cancelInProgressDownloads() async {
        await stopQueueForSuspension()
        try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .pending)
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
    }

    /// Called when the app backgrounds. Suspends discretionary queue work unless
    /// the OS explicitly grants a continued-processing window later.
    public func handleAppDidEnterBackground() async {
        isAppInBackground = true
        allowsBackgroundContinuation = false
        await stopQueueForSuspension()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
    }

    /// Called when the app foregrounds so the queue can resume under the current policy.
    public func handleAppWillEnterForeground() async {
        isAppInBackground = false
        allowsBackgroundContinuation = false
        try? await applyNetworkPolicy()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh(forceImmediate: true)
        startQueueIfNeeded()
    }

    // MARK: - Queue Execution

    private func startQueueIfNeeded() {
        queueCoordinator.startIfNeeded()
    }

    private func handleBackgroundExecutionRequest() async {
        allowsBackgroundContinuation = true
        await queueCoordinator.handleBackgroundExecutionRequest()
    }

    private func handleBackgroundTaskExpiration() {
        allowsBackgroundContinuation = false
        queueCoordinator.cancelCurrentTask()
        Task {
            try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
            await refreshAllTargetProgresses()
            refreshQueueStatusReason()
        }
    }

    /// Single download worker — loops pulling the next pending download until
    /// the queue is empty or the task is cancelled.
    /// Runs the actual download in a detached task so multiple workers execute
    /// their network I/O truly in parallel instead of serializing on @MainActor.
    /// Returns true if at least one download was processed.
    private func workerLoop(applyInteractiveCooldown: Bool) async -> Bool {
        var didProcess = false
        while !Task.isCancelled {
            do {
                // Wait for network availability (lightweight main-actor check)
                try await applyNetworkPolicy()

                guard canRunQueueAutomatically else {
                    // Exit instead of polling every 2s — lets the CPU idle on dual-core devices.
                    // The network state observer calls startQueueIfNeeded() reactively when
                    // conditions change, so we don't need to spin here.
                    isQueueRunning = false
                    refreshQueueStatusReason()
                    EnsembleLogger.debug("📥 Worker exit: queue unavailable (\(queueStatusReason))")
                    return didProcess
                }

                // Claim a single pending download (atomic, sets status to .downloading)
                guard let nextDownload = try await downloadManager.fetchNextPendingDownload() else {
                    let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? -1
                    EnsembleLogger.debug("📥 Worker exit: no pending download (pendingCount=\(pendingCount), didProcess=\(didProcess))")
                    return didProcess
                }

                didProcess = true
                isQueueRunning = true
                refreshQueueStatusReason()

                // Run process() in a detached task so it doesn't serialize on @MainActor.
                // The detached task hops to main actor only when calling @MainActor services,
                // but network I/O runs fully in parallel across workers.
                let selfRef = self
                let detachedProcess = Task.detached(priority: .utility) {
                    await selfRef.process(download: nextDownload)
                }
                // Bridge cancellation so pause/cancel stops the download
                await withTaskCancellationHandler {
                    await detachedProcess.value
                } onCancel: {
                    detachedProcess.cancel()
                }

                // Update background execution progress
                let completedCount = targets.reduce(0) { $0 + $1.completedTrackCount }
                let totalCount = targets.reduce(0) { $0 + $1.totalTrackCount }
                backgroundExecutionCoordinator.setProgress(
                    completedUnitCount: completedCount,
                    totalUnitCount: totalCount
                )

                if applyInteractiveCooldown {
                    try? await Task.sleep(nanoseconds: Self.interactivePlaybackWorkerCooldownNs)
                }
            } catch {
                if Task.isCancelled { return didProcess }
                EnsembleLogger.debug("❌ Offline queue worker failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return didProcess
    }

    private func applyNetworkPolicy() async throws {
        if canRunQueueAutomatically {
            try await downloadManager.updateDownloads(withStatuses: [.paused], to: .pending)
        } else {
            try await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
        }
        refreshQueueStatusReason()
    }

    private func process(download: CDDownload) async {
        // ── Capture all managed-object properties into value types BEFORE any async work. ──
        // viewContext.reset() during sync can invalidate CDTrack/CDDownload at any time,
        // and cascade deletes (CDTrack deletion removes CDDownload) can remove the store
        // record entirely. After this block, we never access the managed objects again.
        guard let track = download.track,
              let sourceCompositeKey = track.sourceCompositeKey else {
            try? await downloadManager.failDownload(download.objectID, error: "Missing track context")
            await refreshAllTargetProgresses()
            return
        }

        let ctx = DownloadContext(
            downloadObjectID: download.objectID,
            trackRatingKey: track.ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            trackDuration: track.duration,
            downloadQuality: download.quality,
            domainTrack: Track(from: track),
            safeSourceKey: sourceCompositeKey.replacingOccurrences(of: ":", with: "_"),
            trackThumbPath: track.thumbPath,
            albumRatingKey: track.album?.ratingKey,
            albumThumbPath: track.album?.thumbPath
        )

        let reference = OfflineTrackReference(
            trackRatingKey: ctx.trackRatingKey,
            trackSourceCompositeKey: ctx.sourceCompositeKey
        )
        var attemptedDirectFallback = false

        do {
            // Target could be removed while this transfer is waiting.
            let stillReferenced = try await targetRepository.hasAnyMembership(for: reference)
            if !stillReferenced {
                try await downloadManager.deleteDownload(
                    forTrackRatingKey: reference.trackRatingKey,
                    sourceCompositeKey: reference.trackSourceCompositeKey
                )
                await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)
                return
            }

            try await downloadManager.updateDownloadStatus(ctx.downloadObjectID, status: .downloading, quality: nil)

            let requestedQuality = streamingQuality(from: ctx.downloadQuality)
            var effectiveQuality = requestedQuality
            let sizeEstimate = estimatedFileSize(durationMs: ctx.trackDuration, quality: requestedQuality)

            // Strategy for non-original quality downloads:
            // 1. Use the Plex download queue API (server transcodes, we download the result)
            // 2. Fall back to direct original download if the queue fails
            //
            // The universal transcode endpoint (`start.mp3`) is not a valid Plex API path —
            // it only supports HLS (`start.m3u8`) for streaming, not direct file downloads.
            // The download queue is the proper mechanism (what Plexamp uses for offline sync).

            var selectedURL: URL
            var selectedMode: String

            if requestedQuality != .original {
                // Try the download queue for transcoded downloads.
                do {
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(ctx.trackRatingKey) stage=download-queue quality=\(requestedQuality.rawValue)"
                    )
                    let completed = try await completeViaDownloadQueue(
                        ctx: ctx,
                        quality: requestedQuality,
                        mode: "download-queue"
                    )
                    if completed { return }
                } catch is CancellationError {
                    // Task cancelled (quality change, pause, etc.) — reset to pending
                    // at the current quality so the worker downloads at the correct setting.
                    let updatedQuality = currentDownloadQuality()
                    EnsembleLogger.debug(
                        "⏸️ Download queue cancelled for track=\(ctx.trackRatingKey); resetting to pending at quality=\(updatedQuality)"
                    )
                    try? await downloadManager.updateDownloadStatus(ctx.downloadObjectID, status: .pending, quality: updatedQuality)
                    return
                } catch {
                    // Download queue failed — fall through to direct original download.
                    if !shouldAttemptDirectFallback(after: error, for: ctx) {
                        throw error
                    }
                    EnsembleLogger.debug(
                        "⚠️ Download queue failed for track=\(ctx.trackRatingKey): \(error.localizedDescription); falling back to direct original"
                    )
                    effectiveQuality = .original
                }
            }

            // Original quality or download queue failed — download the original file directly.
            selectedURL = try await syncCoordinator.getDownloadURL(for: ctx.domainTrack, quality: .original)
            selectedMode = requestedQuality == .original ? "direct-original" : "direct-original-fallback"
            effectiveQuality = .original
            attemptedDirectFallback = requestedQuality != .original

            EnsembleLogger.debug(
                "⬇️ Offline download attempt: track=\(ctx.trackRatingKey) stage=\(selectedMode) url=\(selectedURL)"
            )
            let (temporaryURL, response) = try await downloadWithProgress(from: selectedURL, downloadID: ctx.downloadObjectID, estimatedSize: sizeEstimate)

            if let httpResponse = response as? HTTPURLResponse {
                EnsembleLogger.debug(
                    "⬇️ Offline download response: track=\(ctx.trackRatingKey) status=\(httpResponse.statusCode) quality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) mode=\(selectedMode)"
                )
                if let plexError = httpResponse.value(forHTTPHeaderField: "X-Plex-Error"), !plexError.isEmpty {
                    EnsembleLogger.debug("⬇️ Offline download X-Plex-Error: \(plexError)")
                }
                if !(200...299).contains(httpResponse.statusCode) {
                    if let data = try? Data(contentsOf: temporaryURL), !data.isEmpty {
                        let preview = String(decoding: data.prefix(200), as: UTF8.self)
                            .replacingOccurrences(of: "\n", with: " ")
                        EnsembleLogger.debug("⬇️ Offline download error body (preview): \(preview)")
                    }
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw DownloadProcessingError.invalidHTTPStatus(httpResponse.statusCode)
                }
            }

            let temporaryAttributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let temporaryFileSize = (temporaryAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard temporaryFileSize > 0 else {
                throw DownloadProcessingError.emptyPayload(selectedURL.absoluteString)
            }

            let destinationURL = localFileURL(
                ratingKey: ctx.trackRatingKey,
                safeSourceKey: ctx.safeSourceKey,
                quality: effectiveQuality,
                response: response
            )
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

            let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let destinationFileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let persistedFileSize = max(temporaryFileSize, destinationFileSize)
            guard persistedFileSize > 0 else {
                throw DownloadProcessingError.emptyPayload(selectedURL.absoluteString)
            }

            // Diagnostic: log Content-Type and file magic bytes to verify transcode actually happened
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            var magicBytesHex = "?"
            if let handle = FileHandle(forReadingAtPath: destinationURL.path),
               let header = try? handle.read(upToCount: 12) {
                magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
                try? handle.close()
            }
            EnsembleLogger.debug(
                "✅ Offline download stored: track=\(ctx.trackRatingKey) path=\(destinationURL.lastPathComponent) size=\(persistedFileSize) mode=\(selectedMode) contentType=\(contentType) requestedQuality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) magic=\(magicBytesHex)"
            )

            // Validate that the downloaded file isn't truncated (interrupted connection, etc.).
            // Must happen BEFORE marking complete — a truncated file should stay as "failed"
            // so the download queue retries it on the next pass.
            try validateDownloadDuration(fileURL: destinationURL, ctx: ctx)

            // Persist completion to CoreData with recovery for cascade-deleted records.
            try await completeDownloadWithRecovery(
                ctx: ctx,
                filePath: destinationURL.lastPathComponent,
                fileSize: persistedFileSize,
                quality: effectiveQuality
            )
            await cacheArtworkForDownloadedTrack(ctx: ctx)
            // Targeted refresh: only update targets that own this track (not all targets)
            await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)

            // Pre-compute frequency analysis sidecar for the visualizer.
            // Uses the serial queue so only one FFT runs at a time (A9 dual-core friendly).
            let sidecarURL = destinationURL.appendingPathExtension("freq")
            await sidecarAnalysisQueue.enqueue(sourceURL: destinationURL, sidecarURL: sidecarURL)

            // Pre-cache lyrics for offline playback
            let lyricsRatingKey = ctx.trackRatingKey
            let lyricsSCK = ctx.sourceCompositeKey
            let lyricsServiceRef = self.lyricsService
            Task.detached(priority: .utility) {
                await lyricsServiceRef.fetchAndCacheLyrics(
                    trackRatingKey: lyricsRatingKey,
                    sourceCompositeKey: lyricsSCK
                )
            }

            retryPolicy.recordSuccess(
                trackRatingKey: ctx.trackRatingKey,
                sourceCompositeKey: ctx.sourceCompositeKey,
                attemptedDirectFallback: attemptedDirectFallback
            )

            // Notify track-displaying VMs so they re-fetch and reflect updated
            // offline state (e.g. dimming). Debounced to avoid spamming during
            // bulk queue processing.
            scheduleDownloadChangeNotification()
        } catch {
            let resolution = retryPolicy.resolveFailure(
                .init(
                    trackRatingKey: ctx.trackRatingKey,
                    sourceCompositeKey: ctx.sourceCompositeKey,
                    attemptedDirectFallback: attemptedDirectFallback,
                    updatedQuality: currentDownloadQuality(),
                    isCancellation: Task.isCancelled,
                    isNetworkLoss: isNetworkLossError(error),
                    isRetryableTransfer: error is DownloadTransferError || isRetryableTruncation(error),
                    errorDescription: error.localizedDescription
                )
            )

            switch resolution {
            case .resetToPending(let quality):
                // Quality changes cancel in-flight downloads and re-queue at the
                // new quality; .paused would leave the old-quality download stuck.
                try? await downloadManager.updateDownloadStatus(
                    ctx.downloadObjectID,
                    status: .pending,
                    quality: quality
                )
            case .pauseForNetworkLoss:
                // Network dropped mid-transfer — pause so the download auto-resumes
                // when connectivity returns, instead of marking as permanently failed.
                try? await downloadManager.updateDownloadStatus(ctx.downloadObjectID, status: .paused, quality: nil)
                EnsembleLogger.debug(
                    "⏸️ Offline download paused (network lost): track=\(ctx.trackRatingKey) source=\(ctx.sourceCompositeKey)"
                )
            case .retryPending(let attempt, let maxAttempts, _):
                // Incomplete transfer or truncated payload — re-queue as pending so the
                // download worker automatically retries. These are transient failures.
                try? await downloadManager.updateDownloadStatus(ctx.downloadObjectID, status: .pending, quality: nil)
                EnsembleLogger.debug(
                    "🔄 Offline download re-queued (attempt \(attempt)/\(maxAttempts)): track=\(ctx.trackRatingKey) reason=\(error.localizedDescription)"
                )
            case .fail(let message, _):
                try? await downloadManager.failDownload(ctx.downloadObjectID, error: message)
                EnsembleLogger.debug(
                    "❌ Offline download failed: track=\(ctx.trackRatingKey) source=\(ctx.sourceCompositeKey) reason=\(error.localizedDescription)"
                )
            }
            // Targeted refresh: only update targets that own this track
            await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)
        }
    }

    /// Downloads a URL to a temporary file while periodically reporting progress to CoreData.
    /// Uses URLSession.bytes(from:) to stream data and compare bytes received against Content-Length.
    /// Falls back to `estimatedSize` when Content-Length is absent (common for transcode streams).
    /// Progress is throttled to ~1 update/second to avoid excessive CoreData writes.
    /// Runs the byte-streaming loop off the main actor so UI updates aren't blocked.
    private func downloadWithProgress(
        from url: URL,
        downloadID: NSManagedObjectID,
        estimatedSize: Int64 = -1
    ) async throws -> (URL, URLResponse) {
        let dm = downloadManager
        let estimate = estimatedSize

        // Run the streaming I/O in a detached task to avoid blocking @MainActor.
        // withTaskCancellationHandler bridges parent cancellation to the detached task
        // so the download stops when the queue is paused/cancelled.
        let detachedTask = Task.detached(priority: .utility) { [dm] () -> (URL, URLResponse) in
            let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)
            // Use Content-Length if the server provides it, otherwise fall back to the
            // bitrate-based estimate passed by the caller
            let totalExpected = response.expectedContentLength > 0
                ? response.expectedContentLength
                : estimate

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)

            do {
                let fileHandle = try FileHandle(forWritingTo: tempURL)

                var bytesReceived: Int64 = 0
                var buffer = Data()
                let flushThreshold = 65_536 // 64KB chunks
                var lastProgressUpdate = Date.distantPast
                let progressInterval: TimeInterval = 1.0

                for try await byte in asyncBytes {
                    try Task.checkCancellation()
                    buffer.append(byte)

                    if buffer.count >= flushThreshold {
                        fileHandle.write(buffer)
                        bytesReceived += Int64(buffer.count)
                        buffer.removeAll(keepingCapacity: true)

                        // Report progress when total size is known (or estimated), throttled
                        if totalExpected > 0 {
                            let now = Date()
                            if now.timeIntervalSince(lastProgressUpdate) >= progressInterval {
                                let progress = min(Float(bytesReceived) / Float(totalExpected), 0.99)
                                try? await dm.updateDownloadProgress(downloadID, progress: progress)
                                lastProgressUpdate = now
                            }
                        }
                    }
                }

                // Flush remaining bytes
                if !buffer.isEmpty {
                    bytesReceived += Int64(buffer.count)
                    fileHandle.write(buffer)
                }
                try fileHandle.close()

                // Validate bytes received against Content-Length when available.
                // URLSession.bytes exits silently when the server closes the connection
                // mid-stream (e.g. app backgrounded, server timeout, FFmpeg crash).
                // Without this check, a partial file passes as "complete."
                let expectedLength = response.expectedContentLength
                if expectedLength > 0 {
                    if bytesReceived < expectedLength {
                        let pctReceived = Int(Double(bytesReceived) / Double(expectedLength) * 100)
                        EnsembleLogger.debug(
                            "⚠️ Download incomplete: received \(bytesReceived)/\(expectedLength) bytes (\(pctReceived)%)"
                        )
                        try? FileManager.default.removeItem(at: tempURL)
                        throw DownloadTransferError.incompleteTransfer(
                            bytesReceived: bytesReceived,
                            bytesExpected: expectedLength,
                            percentComplete: pctReceived
                        )
                    }
                } else if estimate > 0, bytesReceived < estimate / 2 {
                    // No Content-Length (chunked transcode) but received less than half
                    // the bitrate estimate — likely truncated. Log for diagnostics but
                    // let validateDownloadDuration() make the final call with audio probing.
                    let pctOfEstimate = Int(Double(bytesReceived) / Double(estimate) * 100)
                    EnsembleLogger.debug(
                        "⚠️ Download suspiciously short: received \(bytesReceived) bytes vs ~\(estimate) estimated (\(pctOfEstimate)%)"
                    )
                }

                return (tempURL, response)
            } catch {
                // Clean up partial temp file on failure
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
        }

        return try await withTaskCancellationHandler {
            try await detachedTask.value
        } onCancel: {
            detachedTask.cancel()
        }
    }

    /// Estimates file size in bytes for a track at a given quality based on duration and bitrate.
    /// Returns -1 for original quality since the original file size is unknown.
    private func estimatedFileSize(durationMs: Int64, quality: StreamingQuality) -> Int64 {
        guard quality != .original else { return -1 }
        let durationSeconds = Double(durationMs) / 1000.0
        let bitrateKbps: Double
        switch quality {
        case .high: bitrateKbps = 320
        case .medium: bitrateKbps = 192
        case .low: bitrateKbps = 128
        case .original: return -1
        }
        // kbps = 1000 bits/s; bytes/s = kbps * 1000 / 8
        return Int64(durationSeconds * bitrateKbps * 1000.0 / 8.0)
    }

    /// Download a transcoded track via the Plex download queue API.
    /// Returns `true` if the download completed successfully, `false` if the payload was empty.
    /// Uses captured DownloadContext values to avoid accessing invalidated managed objects.
    private func completeViaDownloadQueue(
        ctx: DownloadContext,
        quality: StreamingQuality,
        mode: String
    ) async throws -> Bool {
        let queuePayload = try await syncCoordinator.getOfflineDownloadQueueMedia(
            for: ctx.domainTrack,
            quality: quality
        )
        guard !queuePayload.data.isEmpty else {
            return false
        }

        let destinationURL = localFileURL(
            ratingKey: ctx.trackRatingKey,
            safeSourceKey: ctx.safeSourceKey,
            quality: quality,
            suggestedFilename: queuePayload.suggestedFilename,
            mimeType: queuePayload.mimeType,
            payload: queuePayload.data
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        try queuePayload.data.write(to: destinationURL, options: [.atomic])

        let queueAttributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
        let queueFileSize = (queueAttributes?[.size] as? NSNumber)?.int64Value ?? Int64(queuePayload.data.count)
        guard queueFileSize > 0 else {
            return false
        }

        // Log magic bytes for format verification
        var magicBytesHex = "?"
        if let handle = FileHandle(forReadingAtPath: destinationURL.path),
           let header = try? handle.read(upToCount: 12) {
            magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            try? handle.close()
        }
        EnsembleLogger.debug(
            "✅ Offline download stored: track=\(ctx.trackRatingKey) path=\(destinationURL.lastPathComponent) size=\(queueFileSize) mode=\(mode) contentType=\(queuePayload.mimeType ?? "unknown") magic=\(magicBytesHex)"
        )

        // Validate that the downloaded file isn't truncated
        try validateDownloadDuration(fileURL: destinationURL, ctx: ctx)

        // Persist completion to CoreData with recovery for cascade-deleted records.
        try await completeDownloadWithRecovery(
            ctx: ctx,
            filePath: destinationURL.lastPathComponent,
            fileSize: queueFileSize,
            quality: quality
        )
        await cacheArtworkForDownloadedTrack(ctx: ctx)
        // Targeted refresh: only update targets that own this track
        await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)

        // Pre-compute frequency analysis sidecar for the visualizer.
        // Uses the serial queue so only one FFT runs at a time (A9 dual-core friendly).
        let sidecarURL2 = destinationURL.appendingPathExtension("freq")
        await sidecarAnalysisQueue.enqueue(sourceURL: destinationURL, sidecarURL: sidecarURL2)

        scheduleDownloadChangeNotification()
        return true
    }

    /// Build local file URL for a direct download using captured value-type properties.
    private func localFileURL(ratingKey: String, safeSourceKey: String, quality: StreamingQuality, response: URLResponse) -> URL {
        let responseExtension = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = responseExtension?.isEmpty == false
            ? responseExtension!
            : inferredFileExtension(mimeType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), payload: nil)
        let fileName = "\(ratingKey)_\(safeSourceKey)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Best-effort artwork caching for newly downloaded tracks so offline lists/details keep artwork.
    /// Uses captured value-type properties from DownloadContext to avoid accessing invalidated managed objects.
    private func cacheArtworkForDownloadedTrack(ctx: DownloadContext) async {
        var candidates: [(ratingKey: String, path: String)] = []
        if let path = ctx.trackThumbPath, !path.isEmpty {
            candidates.append((ctx.trackRatingKey, path))
        }
        if let albumRatingKey = ctx.albumRatingKey, let albumThumbPath = ctx.albumThumbPath, !albumThumbPath.isEmpty {
            candidates.append((albumRatingKey, albumThumbPath))
        }

        guard !candidates.isEmpty else { return }

        var seen = Set<String>()
        for candidate in candidates {
            let dedupeKey = "\(candidate.ratingKey)|\(candidate.path)"
            guard seen.insert(dedupeKey).inserted else { continue }

            let cachedArtworkPath = ArtworkDownloadManager.artworkDirectory
                .appendingPathComponent("\(candidate.ratingKey)_album.jpg")
                .path
            if FileManager.default.fileExists(atPath: cachedArtworkPath) {
                continue
            }

            do {
                guard let artworkURL = try await syncCoordinator.getArtworkURL(
                    path: candidate.path,
                    sourceKey: ctx.sourceCompositeKey,
                    size: 500
                ) else {
                    continue
                }

                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: artworkURL,
                    ratingKey: candidate.ratingKey,
                    type: .album
                )

                EnsembleLogger.debug(
                    "🖼️ Cached artwork for downloaded track: track=\(ctx.trackRatingKey) artworkKey=\(candidate.ratingKey)"
                )
            } catch {
                EnsembleLogger.debug(
                    "⚠️ Failed caching artwork for downloaded track \(ctx.trackRatingKey): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Validate that a downloaded audio file's duration is consistent with the track's metadata.
    /// Catches truncated downloads from interrupted connections or server-side errors.
    /// Throws `truncatedPayload` if the file is less than 50% of expected duration.
    private func validateDownloadDuration(
        fileURL: URL,
        ctx: DownloadContext
    ) throws {
        let expectedDurationMs = ctx.trackDuration
        guard expectedDurationMs > 10_000 else { return } // Skip very short tracks
        let expectedSeconds = Double(expectedDurationMs) / 1000.0

        do {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { return }
            let fileDuration = Double(audioFile.length) / sampleRate

            if fileDuration < expectedSeconds * 0.5 && fileDuration < expectedSeconds - 10 {
                EnsembleLogger.debug(
                    "⚠️ Truncated download for track=\(ctx.trackRatingKey): file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedSeconds))s — rejecting"
                )
                // Clean up the truncated file
                try? FileManager.default.removeItem(at: fileURL)
                throw DownloadProcessingError.truncatedPayload(
                    fileDuration: fileDuration,
                    expectedDuration: expectedSeconds
                )
            }
        } catch let error as DownloadProcessingError {
            throw error // Re-throw our own errors
        } catch {
            // AVAudioFile failed to open — file may be corrupt. Log but don't block
            // completion since the format might just be unrecognizable to AVAudioFile.
            EnsembleLogger.debug(
                "⚠️ Could not validate download duration for track=\(ctx.trackRatingKey): \(error.localizedDescription)"
            )
        }
    }

    /// Scan all completed downloads for truncated audio files and mark them as failed.
    /// Runs at startup (after DownloadManager's own self-healing) to catch truncated files
    /// that passed the basic HTML/empty payload checks but have significantly shorter audio
    /// duration than expected (e.g. interrupted network transfer that closed cleanly).
    private func scanForTruncatedDownloads() async {
        do {
            let completed = try await downloadManager.fetchCompletedDownloads()
            guard !completed.isEmpty else { return }

            var truncatedCount = 0
            for download in completed {
                guard let filename = download.filePath, !filename.isEmpty,
                      let track = download.track else { continue }

                let expectedMs = track.duration
                guard expectedMs > 10_000 else { continue } // Skip very short tracks
                let expectedSeconds = Double(expectedMs) / 1000.0

                let absolutePath = DownloadManager.absolutePath(forFilename: filename)
                guard FileManager.default.fileExists(atPath: absolutePath) else { continue }

                let fileURL = URL(fileURLWithPath: absolutePath)
                do {
                    let audioFile = try AVAudioFile(forReading: fileURL)
                    let sampleRate = audioFile.processingFormat.sampleRate
                    guard sampleRate > 0 else { continue }
                    let fileDuration = Double(audioFile.length) / sampleRate

                    if fileDuration < expectedSeconds * 0.5 && fileDuration < expectedSeconds - 10 {
                        EnsembleLogger.debug(
                            "[OfflineDownloads] Truncated download detected: '\(track.title)' file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedSeconds))s — marking failed"
                        )
                        // Delete truncated file so DownloadManager self-healing won't recover it.
                        // resolveAudioFile checks fileExists before using localFilePath, so the
                        // stale path is harmless — playback will fall through to streaming.
                        try? FileManager.default.removeItem(at: fileURL)
                        try? await downloadManager.failDownload(
                            download.objectID,
                            error: "Truncated (\(String(format: "%.0f", fileDuration))s vs \(String(format: "%.0f", expectedSeconds))s expected)"
                        )
                        truncatedCount += 1
                    }
                } catch {
                    // AVAudioFile can't read this file — skip, don't block other checks
                    continue
                }
            }

            if truncatedCount > 0 {
                EnsembleLogger.debug("[OfflineDownloads] Startup scan found \(truncatedCount) truncated download(s) — marked as failed for re-download")
            }
        } catch {
            EnsembleLogger.debug("[OfflineDownloads] Truncation scan failed: \(error.localizedDescription)")
        }
    }

    /// Complete a download in CoreData with recovery for cascade-deleted CDDownload records.
    /// When sync deletes a CDTrack during an active download, the CDTrack→CDDownload cascade
    /// delete rule removes the CDDownload from the store. This method tries the primary
    /// objectID path first, then falls back to recreating the download record by ratingKey.
    private func completeDownloadWithRecovery(
        ctx: DownloadContext,
        filePath: String,
        fileSize: Int64,
        quality: StreamingQuality
    ) async throws {
        do {
            try await downloadManager.completeDownload(
                ctx.downloadObjectID,
                filePath: filePath,
                fileSize: fileSize,
                quality: quality.rawValue
            )
        } catch {
            // CDDownload was likely cascade-deleted when sync removed its CDTrack.
            // Try to recreate the download record and mark it complete.
            #if DEBUG
            EnsembleLogger.debug(
                "⚠️ completeDownload(\(ctx.trackRatingKey)) objectID not found: \(error.localizedDescription); attempting recovery"
            )
            #endif
            let recovered = try await downloadManager.createDownload(
                forTrackRatingKey: ctx.trackRatingKey,
                sourceCompositeKey: ctx.sourceCompositeKey,
                quality: quality.rawValue
            )
            try await downloadManager.completeDownload(
                recovered.objectID,
                filePath: filePath,
                fileSize: fileSize,
                quality: quality.rawValue
            )
            #if DEBUG
            EnsembleLogger.debug("✅ Download recovery successful for track=\(ctx.trackRatingKey)")
            #endif
        }
    }

    /// Cache artwork for a download target (album, artist, or playlist) so it's available offline.
    private func cacheArtworkForTarget(
        ratingKey: String,
        thumbPath: String?,
        sourceKey: String,
        type: ArtworkType
    ) async {
        guard let thumbPath, !thumbPath.isEmpty else { return }

        // Skip if already cached
        let typeString: String
        switch type {
        case .album: typeString = "album"
        case .artist: typeString = "artist"
        case .playlist: typeString = "playlist"
        case .track: typeString = "track"
        }
        let cachedPath = ArtworkDownloadManager.artworkDirectory
            .appendingPathComponent("\(ratingKey)_\(typeString).jpg").path
        if FileManager.default.fileExists(atPath: cachedPath) { return }

        do {
            guard let artworkURL = try await syncCoordinator.getArtworkURL(
                path: thumbPath,
                sourceKey: sourceKey,
                size: 500
            ) else { return }

            try await artworkDownloadManager.downloadAndCacheArtwork(
                from: artworkURL,
                ratingKey: ratingKey,
                type: type
            )
            EnsembleLogger.debug("🖼️ Cached \(typeString) artwork for download target: \(ratingKey)")
        } catch {
            EnsembleLogger.debug("⚠️ Failed caching \(typeString) artwork for target \(ratingKey): \(error.localizedDescription)")
        }
    }

    /// Build local file URL for a download queue result using captured value-type properties.
    private func localFileURL(
        ratingKey: String,
        safeSourceKey: String,
        quality: StreamingQuality,
        suggestedFilename: String?,
        mimeType: String?,
        payload: Data?
    ) -> URL {
        let suggestedExtension = suggestedFilename
            .flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = suggestedExtension?.isEmpty == false
            ? suggestedExtension!
            : inferredFileExtension(mimeType: mimeType, payload: payload)
        let fileName = "\(ratingKey)_\(safeSourceKey)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private func inferredFileExtension(mimeType: String?, payload: Data?) -> String {
        if let mimeType {
            let normalized = mimeType.lowercased()
            if normalized.contains("mpeg") || normalized.contains("mp3") {
                return "mp3"
            }
            if normalized.contains("mp4") || normalized.contains("m4a") {
                return "m4a"
            }
            if normalized.contains("aac") {
                return "aac"
            }
            if normalized.contains("flac") {
                return "flac"
            }
        }

        guard let payload, payload.count >= 4 else {
            return "m4a"
        }

        if payload.starts(with: [0x49, 0x44, 0x33]) { // ID3
            return "mp3"
        }
        if payload.starts(with: [0x66, 0x4C, 0x61, 0x43]) { // fLaC
            return "flac"
        }
        if payload.starts(with: [0xFF, 0xFB]) || payload.starts(with: [0xFF, 0xF3]) || payload.starts(with: [0xFF, 0xF2]) {
            return "mp3"
        }
        if payload.count >= 12 {
            let ftypMarker = Data([0x66, 0x74, 0x79, 0x70]) // ftyp
            if payload.subdata(in: 4..<8) == ftypMarker {
                return "m4a"
            }
        }

        return "m4a"
    }

    /// Returns true if the error indicates a network/connectivity loss rather than a server-side
    /// or content error. Used to pause (not fail) downloads when connectivity drops mid-transfer.
    /// Returns true for truncated payload errors that should be retried automatically.
    private func isRetryableTruncation(_ error: Error) -> Bool {
        if case DownloadProcessingError.truncatedPayload = error { return true }
        return false
    }

    private func isNetworkLossError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        return false
    }

    private var canExecuteDownloads: Bool {
        switch networkMonitor.networkState {
        case .online(.wifi), .online(.wired):
            return true
        case .online(.cellular):
            return UserDefaults.standard.bool(forKey: "allowCellularDownloads")
        case .online(.other), .offline, .limited, .unknown:
            return false
        }
    }

    private var canRunQueueAutomatically: Bool {
        canExecuteDownloads
            && !isUserPaused
            && !isLowPowerSuspended
            && (!isAppInBackground || allowsBackgroundContinuation)
    }

    internal var currentDownloadWorkMode: DownloadWorkMode {
        if isAppInBackground && !allowsBackgroundContinuation {
            return .background
        }
        if isPlaybackSensitive {
            return .interactivePlayback
        }
        return .foregroundIdle
    }

    internal var shouldDeferForegroundHealthRefresh: Bool {
        currentDownloadWorkMode == .interactivePlayback
            && (queueCoordinator.hasActiveTask || isQueueRunning || !activeDownloadRatingKeys.isEmpty || fullProgressRefreshTask != nil)
    }

    /// Maps current network state to a user-facing queue pause reason
    private func queueReasonForCurrentState() -> QueueStatusReason {
        switch networkMonitor.networkState {
        case .offline:
            return .offline
        case .online(.cellular):
            if UserDefaults.standard.bool(forKey: "allowCellularDownloads") {
                return .idle
            }
            return .waitingForWiFi
        case .online(.other):
            return .waitingForWiFi
        case .unknown, .limited:
            return .offline
        case .online(.wifi), .online(.wired):
            return .idle
        }
    }

    /// Re-evaluates network policy and restarts the queue if conditions now allow downloads.
    /// Called when the user toggles the cellular download setting.
    public func reevaluateQueuePolicy() async {
        try? await applyNetworkPolicy()
        refreshQueueStatusReason()
        if canExecuteDownloads {
            startQueueIfNeeded()
        }
    }

    // MARK: - Progress / Snapshots

    private func refreshTargetSnapshots() async {
        do {
            let fetched = try await targetRepository.fetchTargets()
            let existingTargetKeys = Set(fetched.map(\.key))
            downloadedBytesByTargetKey = downloadedBytesByTargetKey.filter { existingTargetKeys.contains($0.key) }
            qualityMismatchByTargetKey = qualityMismatchByTargetKey.filter { existingTargetKeys.contains($0.key) }
            failedTracksByTargetKey = failedTracksByTargetKey.filter { existingTargetKeys.contains($0.key) }
            targets = fetched.map {
                OfflineDownloadTargetSnapshot(
                    id: $0.key,
                    key: $0.key,
                    kind: $0.targetKind,
                    ratingKey: $0.ratingKey,
                    sourceCompositeKey: $0.sourceCompositeKey,
                    displayName: $0.displayName ?? defaultDisplayName(for: $0),
                    status: $0.targetStatus,
                    totalTrackCount: Int($0.totalTrackCount),
                    completedTrackCount: Int($0.completedTrackCount),
                    downloadedBytes: downloadedBytesByTargetKey[$0.key] ?? 0,
                    progress: $0.progress,
                    qualityMismatchCount: qualityMismatchByTargetKey[$0.key] ?? 0,
                    failedTrackCount: failedTracksByTargetKey[$0.key] ?? 0
                )
            }
        } catch {
            EnsembleLogger.debug("❌ Failed fetching offline target snapshots: \(error.localizedDescription)")
        }
    }

    /// Refreshes only the targets that contain the given track.
    /// Much cheaper than refreshAllTargetProgresses() during bulk downloads — O(owning targets)
    /// instead of O(all targets × tracks per target).
    /// Note: activeDownloadRatingKeys is NOT refreshed here — the debounced
    /// scheduleDownloadChangeNotification() handles that to batch spinner updates
    /// instead of firing per-track during bulk downloads.
    private func refreshTargetsForTrack(ratingKey: String, sourceCompositeKey: String) async {
        do {
            let reference = OfflineTrackReference(
                trackRatingKey: ratingKey,
                trackSourceCompositeKey: sourceCompositeKey
            )
            let targetKeys = try await targetRepository.fetchTargetKeys(containing: reference)
            for key in targetKeys {
                await refreshTargetProgress(forTargetKey: key)
            }
            await refreshTargetSnapshots()
        } catch {
            EnsembleLogger.debug("❌ Failed targeted refresh for track \(ratingKey): \(error.localizedDescription)")
            // Fall back to full refresh on error
            await refreshAllTargetProgresses()
        }
    }

    private func refreshAllTargetProgresses() async {
        do {
            let allTargets = try await targetRepository.fetchTargets()
            for target in allTargets {
                await refreshTargetProgress(forTargetKey: target.key)
            }
            await refreshTargetSnapshots()
            await refreshActiveDownloadRatingKeys()

            // Self-heal orphaned targets: rebuild memberships for targets that
            // lost their track references (e.g., after iOS update or data issue).
            // This runs after the initial snapshot publish so the UI shows stale-
            // but-useful counts while reconciliation proceeds in the background.
            await reconcileOrphanedTargets()
        } catch {
            EnsembleLogger.debug("❌ Failed refreshing offline target progress: \(error.localizedDescription)")
        }
    }

    /// Detects targets with 0 memberships but non-zero stale total track counts
    /// (orphaned) and rebuilds their memberships from existing library/playlist data.
    private func reconcileOrphanedTargets() async {
        do {
            let allTargets = try await targetRepository.fetchTargets()
            var reconciledAny = false

            for target in allTargets {
                let memberships = try await targetRepository.fetchTrackReferences(targetKey: target.key)
                guard memberships.isEmpty && target.totalTrackCount > 0 else { continue }

                #if DEBUG
                EnsembleLogger.debug("🔧 Reconciling orphaned target \(target.key) (stale count: \(target.totalTrackCount))")
                #endif
                try? await reconcileTarget(key: target.key)
                reconciledAny = true
            }

            if reconciledAny {
                await refreshTargetSnapshots()
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed reconciling orphaned targets: \(error.localizedDescription)")
            #endif
        }
    }

    /// Recomputes the set of track ratingKeys that are pending or actively downloading.
    private func refreshActiveDownloadRatingKeys() async {
        do {
            let pending = try await downloadManager.fetchPendingDownloads()
            let keys = Set(pending.compactMap { $0.track?.ratingKey })
            if keys != activeDownloadRatingKeys {
                activeDownloadRatingKeys = keys
            }
        } catch {
            EnsembleLogger.debug("❌ Failed refreshing active download ratingKeys: \(error.localizedDescription)")
        }
    }

    private func refreshTargetProgress(forTargetKey targetKey: String) async {
        do {
            let references = try await targetRepository.fetchTrackReferences(targetKey: targetKey)
            guard !references.isEmpty else {
                // Check if this is an orphaned target: previously had tracks but
                // memberships were lost (e.g., after iOS update or data corruption).
                // Preserve stale total count so UI shows "37 tracks • Queued" instead
                // of "0 tracks • Downloaded" while reconciliation rebuilds memberships.
                let existingTarget = try? await targetRepository.fetchTarget(key: targetKey)
                if let existing = existingTarget, existing.totalTrackCount > 0 {
                    downloadedBytesByTargetKey[targetKey] = 0
                    qualityMismatchByTargetKey[targetKey] = 0
                    failedTracksByTargetKey[targetKey] = 0
                    try await targetRepository.updateTarget(
                        key: targetKey,
                        status: .pending,
                        totalTrackCount: Int(existing.totalTrackCount),
                        completedTrackCount: 0,
                        progress: 0,
                        lastError: nil
                    )
                    #if DEBUG
                    EnsembleLogger.debug("⚠️ Orphaned download target \(targetKey): preserved stale count of \(existing.totalTrackCount) tracks")
                    #endif
                } else {
                    // Genuinely empty target (newly created or all tracks removed)
                    downloadedBytesByTargetKey[targetKey] = 0
                    qualityMismatchByTargetKey[targetKey] = 0
                    failedTracksByTargetKey[targetKey] = 0
                    try await targetRepository.updateTarget(
                        key: targetKey,
                        status: .completed,
                        totalTrackCount: 0,
                        completedTrackCount: 0,
                        progress: 1,
                        lastError: nil
                    )
                }
                return
            }

            // Batch-fetch all downloads for this target in a single CoreData query
            // instead of N individual queries (was O(N) queries per target refresh)
            let downloadsByKey = try await downloadManager.fetchDownloadsBatch(forReferences: references)

            let desiredQuality = currentDownloadQuality()
            var completed = 0
            var downloading = 0
            var pending = 0
            var paused = 0
            var failed = 0
            var qualityMismatch = 0
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
                    // Only count as mismatch when existing quality is LOWER than desired.
                    // A fallback to "original" when the user wants "medium" is fine — the
                    // file exceeds the request and shouldn't show the refresh indicator.
                    if let quality = download.quality,
                       !DownloadManager.qualitySatisfies(existing: quality, desired: desiredQuality) {
                        qualityMismatch += 1
                    }
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
            } else if downloading > 0 || (isQueueRunning && pending > 0) {
                status = .downloading
            } else if !canExecuteDownloads && (pending > 0 || paused > 0) {
                status = .paused
            } else {
                status = .pending
            }

            try await targetRepository.updateTarget(
                key: targetKey,
                status: status,
                totalTrackCount: total,
                completedTrackCount: completed,
                progress: progress,
                lastError: firstFailure
            )
            downloadedBytesByTargetKey[targetKey] = downloadedBytes
            qualityMismatchByTargetKey[targetKey] = qualityMismatch
            failedTracksByTargetKey[targetKey] = failed
        } catch {
            EnsembleLogger.debug("❌ Failed refreshing target progress for \(targetKey): \(error.localizedDescription)")
        }
    }

    private func defaultDisplayName(for target: CDOfflineDownloadTarget) -> String {
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

    // MARK: - Sync / Network Reconciliation

    /// Schedules a debounced `downloadsDidChange` notification so detail views
    /// re-fetch tracks after individual downloads complete without flooding during
    /// bulk queue processing. Refreshes the view context first so managed objects
    /// reflect the latest background-context saves (e.g. CDTrack.localFilePath).
    private func scheduleDownloadChangeNotification() {
        downloadChangeNotificationTask?.cancel()
        downloadChangeNotificationTask = Task { @MainActor [weak self] in
            // Longer debounce during bulk downloads to avoid spamming UI updates.
            // Completions arrive faster than 1s so the short debounce never fires.
            let pendingCount = (try? await self?.downloadManager.fetchPendingDownloads().count) ?? 0
            let debounceNs: UInt64 = pendingCount > 3 ? 3_000_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: debounceNs)
            guard !Task.isCancelled else { return }
            // Force-refault all view context objects so the next fetch reads
            // the latest store data (localFilePath, download status, etc.).
            CoreDataStack.shared.refreshViewContext()
            // Update active download set so TrackRow spinners reflect completions
            await self?.refreshActiveDownloadRatingKeys()
            NotificationCenter.default.post(
                name: OfflineDownloadService.downloadsDidChange,
                object: nil
            )
            self?.downloadChangeNotificationTask = nil
        }
    }

    private func observeNetworkState() {
        networkMonitor.$networkState
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        if !self.canExecuteDownloads {
                            await self.stopQueueForSuspension()
                        }
                        try await self.applyNetworkPolicy()
                        self.scheduleFullProgressRefresh()
                        self.startQueueIfNeeded()
                    } catch {
                        EnsembleLogger.debug("❌ Failed applying offline network policy: \(error.localizedDescription)")
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func stopQueueForSuspension() async {
        queueCoordinator.cancelCurrentTask()
        backgroundExecutionCoordinator.finishCurrentTask(success: true)
        try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
    }

    private func refreshQueueStatusReason() {
        if isQueueRunning {
            queueStatusReason = .downloading
        } else if isUserPaused || isLowPowerSuspended || (isAppInBackground && !allowsBackgroundContinuation) {
            queueStatusReason = .paused
        } else {
            queueStatusReason = queueReasonForCurrentState()
        }
    }

    private func queueWorkerCount(forPendingCount pendingCount: Int, workMode: DownloadWorkMode) -> Int {
        let limit: Int
        switch workMode {
        case .interactivePlayback:
            limit = Self.interactivePlaybackConcurrentDownloads
        case .foregroundIdle:
            limit = Self.maxConcurrentDownloads
        case .background:
            limit = 1
        }
        return max(1, min(limit, pendingCount))
    }

    private func scheduleFullProgressRefresh(forceImmediate: Bool = false) {
        if forceImmediate {
            fullProgressRefreshTask?.cancel()
            fullProgressRefreshTask = nil
            hasQueuedFullProgressRefresh = false
            Task { @MainActor [weak self] in
                await self?.refreshAllTargetProgresses()
            }
            return
        }

        guard fullProgressRefreshTask == nil else {
            hasQueuedFullProgressRefresh = true
            return
        }

        let delay = fullProgressRefreshDelay(for: currentDownloadWorkMode)
        fullProgressRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }

            await self.refreshAllTargetProgresses()
            self.fullProgressRefreshTask = nil

            if self.hasQueuedFullProgressRefresh {
                self.hasQueuedFullProgressRefresh = false
                self.scheduleFullProgressRefresh()
            }
        }
    }

    private func fullProgressRefreshDelay(for workMode: DownloadWorkMode) -> UInt64 {
        switch workMode {
        case .interactivePlayback:
            return Self.interactivePlaybackRefreshDelayNs
        case .foregroundIdle:
            return Self.foregroundIdleRefreshDelayNs
        case .background:
            return Self.backgroundRefreshDelayNs
        }
    }

    private func shouldAttemptDirectFallback(after error: Error, for ctx: DownloadContext) -> Bool {
        switch retryPolicy.directFallbackDecision(
            for: .init(
                trackRatingKey: ctx.trackRatingKey,
                sourceCompositeKey: ctx.sourceCompositeKey,
                isOffline: syncCoordinator.isOffline,
                canExecuteDownloads: canExecuteDownloads,
                canRunQueueAutomatically: canRunQueueAutomatically,
                workMode: currentDownloadWorkMode
            )
        ) {
        case .blockedAfterPriorFailure:
            EnsembleLogger.debug(
                "⛔️ Skipping direct-original fallback for track=\(ctx.trackRatingKey) after an earlier fallback failure in this session"
            )
            return false
        case .blockedByNetwork:
            EnsembleLogger.debug(
                "⛔️ Skipping direct-original fallback for track=\(ctx.trackRatingKey) because the network is unavailable"
            )
            return false
        case .blockedWhileSuspended:
            EnsembleLogger.debug(
                "⛔️ Skipping direct-original fallback for track=\(ctx.trackRatingKey) while download work is suspended"
            )
            return false
        case .attempt:
            break
        }

        if isNetworkLossError(error) {
            EnsembleLogger.debug(
                "⛔️ Skipping direct-original fallback for track=\(ctx.trackRatingKey) because the request failed with a network-loss error"
            )
            return false
        }

        return true
    }

    private func handlePlaybackSensitivityChange(_ isSensitive: Bool) async {
        guard isPlaybackSensitive != isSensitive else { return }
        isPlaybackSensitive = isSensitive

        if isSensitive {
            scheduleFullProgressRefresh()
        } else {
            scheduleFullProgressRefresh(forceImmediate: true)
            startQueueIfNeeded()
        }
    }

    private static func isPlaybackSensitiveState(_ state: PlaybackState) -> Bool {
        switch state {
        case .loading, .buffering, .playing:
            return true
        case .stopped, .paused, .failed:
            return false
        }
    }

    private func observeSyncCompletions() {
        syncCoordinator.$sourceStatuses
            .sink { [weak self] statuses in
                Task { @MainActor in
                    await self?.handleSourceSyncUpdate(statuses)
                }
            }
            .store(in: &cancellables)
    }

    private func handleSourceSyncUpdate(_ statuses: [MusicSourceIdentifier: MusicSourceStatus]) async {
        var anySourceUpdated = false
        for (source, status) in statuses {
            guard case .lastSynced(let syncDate) = status.syncStatus else { continue }

            let key = source.compositeKey
            if let existing = lastObservedSyncBySource[key], existing >= syncDate {
                continue
            }

            anySourceUpdated = true
            lastObservedSyncBySource[key] = syncDate
            await reconcileTargets(forSourceCompositeKey: key)
            if let serverSourceKey = Self.serverSourceKey(fromLibrarySourceKey: key) {
                await reconcilePlaylistTargets(forServerSourceKey: serverSourceKey)
            }
        }

        // Reconcile favorites after source syncs so newly rated tracks are picked up
        if anySourceUpdated {
            await reconcileFavoritesTargetIfEnabled()
        }
    }

    private func reconcileTargets(forSourceCompositeKey sourceCompositeKey: String) async {
        do {
            let allTargets = try await targetRepository.fetchTargets()
            let sourceTargets = allTargets.filter {
                guard $0.sourceCompositeKey == sourceCompositeKey else { return false }
                return $0.targetKind == .library || $0.targetKind == .album || $0.targetKind == .artist
            }

            for target in sourceTargets {
                try await reconcileTarget(key: target.key)
            }
            await refreshTargetSnapshots()

            // Start downloading any newly-queued tracks from the reconciliation
            startQueueIfNeeded()
        } catch {
            EnsembleLogger.debug("❌ Failed reconciling source targets for \(sourceCompositeKey): \(error.localizedDescription)")
        }
    }

    private func reconcilePlaylistTargets(forServerSourceKey serverSourceKey: String) async {
        do {
            let allTargets = try await targetRepository.fetchTargets()
            let playlistTargets = allTargets.filter {
                $0.targetKind == .playlist && $0.sourceCompositeKey == serverSourceKey
            }

            for target in playlistTargets {
                try await reconcileTarget(key: target.key)
            }
            await refreshTargetSnapshots()

            // Start downloading any newly-queued tracks from the reconciliation
            startQueueIfNeeded()
        } catch {
            EnsembleLogger.debug("❌ Failed reconciling playlist targets for \(serverSourceKey): \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func currentDownloadQuality() -> String {
        let raw = UserDefaults.standard.string(forKey: "downloadQuality") ?? "high"
        switch raw {
        case "original", "high", "medium", "low":
            return raw
        default:
            return "high"
        }
    }

    private func streamingQuality(from raw: String?) -> StreamingQuality {
        switch raw {
        case "high":
            return .high
        case "medium":
            return .medium
        case "low":
            return .low
        case "original":
            return .original
        default:
            return .original
        }
    }

    private static func serverSourceKey(fromLibrarySourceKey sourceCompositeKey: String) -> String? {
        let parts = sourceCompositeKey.split(separator: ":")
        guard parts.count >= 3 else { return nil }
        return "\(parts[0]):\(parts[1]):\(parts[2])"
    }

    public static func targetKey(
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?
    ) -> String {
        let ratingComponent = ratingKey ?? "*"
        let sourceComponent = sourceCompositeKey ?? "*"
        return "offline:\(kind.rawValue):\(sourceComponent):\(ratingComponent)"
    }
}

// MARK: - Sidecar Analysis Queue

/// Serializes post-download frequency analysis so only one FFT runs at a time.
/// Supports suspend/resume for app lifecycle and priority bumping so the currently-
/// playing track's sidecar is generated first.
///
/// Design notes:
/// - Pending items are stored in an explicit array (not chained Task references) so they
///   can be reordered and inspected.
/// - On suspend(), the worker Task is cancelled. FrequencyAnalysisService.analyzeForSidecar
///   calls analyzeFile() directly (no inner Task.detached), so Task.isCancelled inside the
///   FFT loop (~every 0.1s at 10fps) responds to our cancellation.
/// - The interrupted item is re-queued at the front so it retries on resume().
private actor SidecarAnalysisQueue {
    private var pending: [(sourceURL: URL, sidecarURL: URL)] = []
    /// The item currently being analyzed (popped from pending, held here for re-queuing on suspend).
    private var currentItem: (sourceURL: URL, sidecarURL: URL)?
    /// Active worker task. Cancelled on suspend().
    private var workerTask: Task<Void, Never>?
    private var isSuspended = false

    // MARK: - Public Interface

    /// Add an item to the end of the queue. Skips duplicates (same sourceURL already pending).
    func enqueue(sourceURL: URL, sidecarURL: URL) {
        guard !pending.contains(where: { $0.sourceURL == sourceURL }) else { return }
        pending.append((sourceURL: sourceURL, sidecarURL: sidecarURL))
        startWorkerIfNeeded()
    }

    /// Move an item to the front so it runs next. If not already queued, inserts it.
    /// No-op if the sidecar file already exists.
    func prioritize(sourceURL: URL, sidecarURL: URL) {
        guard !FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        pending.removeAll { $0.sourceURL == sourceURL }
        pending.insert((sourceURL: sourceURL, sidecarURL: sidecarURL), at: 0)
        startWorkerIfNeeded()
    }

    /// Suspend the queue. Cancels the worker task — the FFT loop checks Task.isCancelled
    /// every ~0.1s, so it stops quickly. The interrupted item is re-queued at the front.
    func suspend() {
        isSuspended = true
        workerTask?.cancel()
        workerTask = nil
        if let item = currentItem {
            pending.insert(item, at: 0)
            currentItem = nil
        }
    }

    /// Resume processing the queue.
    func resume() {
        isSuspended = false
        startWorkerIfNeeded()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard !isSuspended, workerTask == nil, !pending.isEmpty else { return }
        let task = Task.detached(priority: .background) { [self] in
            while let item = await self.popNextItem() {
                // Skip if sidecar was already generated (e.g. by the playback path)
                if FileManager.default.fileExists(atPath: item.sidecarURL.path) {
                    await self.clearCurrentItem()
                    continue
                }
                // Brief delay so download workers can start the next transfer first.
                // Task.sleep is cancellation-aware — exits immediately on cancel.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else {
                    await self.requeueCurrentItem()
                    break
                }
                if let timeline = await FrequencyAnalysisService.analyzeForSidecar(fileURL: item.sourceURL) {
                    try? FrequencyTimelinePersistence.save(timeline, to: item.sidecarURL)
                }
                await self.clearCurrentItem()
            }
            await self.markWorkerFinished()
        }
        workerTask = task
    }

    /// Pop the next item. Returns nil if suspended or empty (stops the worker loop).
    private func popNextItem() -> (sourceURL: URL, sidecarURL: URL)? {
        guard !isSuspended, !pending.isEmpty else { return nil }
        let item = pending.removeFirst()
        currentItem = item
        return item
    }

    private func clearCurrentItem() {
        currentItem = nil
    }

    /// Re-insert the current item at the front so it retries after resume().
    private func requeueCurrentItem() {
        if let item = currentItem {
            pending.insert(item, at: 0)
            currentItem = nil
        }
    }

    /// Called when the worker loop exits naturally. Clears task reference and
    /// restarts if items arrived while the last worker was finishing.
    private func markWorkerFinished() {
        workerTask = nil
        startWorkerIfNeeded()
    }
}
