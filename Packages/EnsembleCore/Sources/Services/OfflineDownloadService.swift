import AVFoundation
import Combine
import CoreData
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
    /// Number of tracks in a failed state
    public let failedTrackCount: Int

    public var isComplete: Bool {
        totalTrackCount > 0 && completedTrackCount >= totalTrackCount
    }

    public var hasFailedTracks: Bool { failedTrackCount > 0 }
}

public struct OfflineDownloadQualityRefreshResult: Sendable {
    public let requeuedCount: Int
    public let skippedUnsupportedCount: Int

    public init(requeuedCount: Int, skippedUnsupportedCount: Int) {
        self.requeuedCount = requeuedCount
        self.skippedUnsupportedCount = skippedUnsupportedCount
    }
}

struct OfflineDownloadHealingSummary: Equatable, Sendable {
    let ranAt: Date?
    let orphanedCompletedDownloadsRemoved: Int
    let errorDescription: String?

    static let notRun = OfflineDownloadHealingSummary(
        ranAt: nil,
        orphanedCompletedDownloadsRemoved: 0,
        errorDescription: nil
    )

    var diagnosticsDescription: String {
        guard let ranAt else { return "not-run" }
        let timestamp = Self.diagnosticsDateFormatter.string(from: ranAt)
        let errorText = errorDescription ?? "none"
        return "removed=\(orphanedCompletedDownloadsRemoved),error=\(errorText),at=\(timestamp)"
    }

    private static let diagnosticsDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct TruncationScanCandidate: @unchecked Sendable {
    let downloadObjectID: NSManagedObjectID
    let title: String
    let absolutePath: String
    let expectedSeconds: Double
}

private struct TruncatedDownloadResult: @unchecked Sendable {
    let downloadObjectID: NSManagedObjectID
    let title: String
    let fileDuration: Double
    let expectedSeconds: Double
}

/// Describes why the download queue is currently idle or paused
public enum QueueStatusReason: Equatable, Sendable {
    case idle
    case downloading
    case waitingForWiFi
    case lowDataMode
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

enum OfflineDownloadRecoveryReason: Equatable, Sendable {
    case launch
    case foreground
    case backgroundURLSession(String)
    case systemWillSleep
    case systemDidWake
    case backgroundExpiration

    var logDescription: String {
        switch self {
        case .launch:
            return "launch"
        case .foreground:
            return "foreground"
        case .backgroundURLSession(let identifier):
            return "background-url-session(\(identifier))"
        case .systemWillSleep:
            return "system-will-sleep"
        case .systemDidWake:
            return "system-did-wake"
        case .backgroundExpiration:
            return "background-expiration"
        }
    }
}

@MainActor
public final class OfflineDownloadService: ObservableObject {
    /// Posted when download targets change (enable/disable/quality refresh) so track-displaying VMs can re-fetch
    nonisolated public static let downloadsDidChange = Notification.Name("OfflineDownloadsDidChange")
    @Published public private(set) var targets: [OfflineDownloadTargetSnapshot] = []
    @Published public private(set) var isQueueRunning = false {
        didSet {
            guard isQueueRunning != oldValue else { return }
            if isQueueRunning {
                foregroundWorkScheduler?.beginInteraction(.downloadTransfer)
            } else {
                foregroundWorkScheduler?.endInteraction(.downloadTransfer)
            }
        }
    }
    /// Current reason the queue is idle/paused — observed by detail views for status banners
    @Published public private(set) var queueStatusReason: QueueStatusReason = .idle
    /// Per-target removal progress — keyed by target key, shown in DownloadsView during cleanup
    @Published public private(set) var removalInProgress: [String: RemovalProgress] = [:]
    /// Track source-scoped identities currently pending or actively downloading, used by track-list rows to show spinners.
    @Published public private(set) var activeDownloadTrackIdentities: Set<String> = []
    internal private(set) var lastHealingSummary: OfflineDownloadHealingSummary = .notRun

    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let backgroundExecutionCoordinator: OfflineDownloadBackgroundCoordinating
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let toastCenter: ToastCenter
    private let lyricsService: LyricsService
    private let foregroundWorkScheduler: ForegroundWorkScheduling?
    private let launchRecoveryStartedAt: Date

    private var cancellables = Set<AnyCancellable>()
    private var lastObservedSyncBySource: [String: Date] = [:]

    /// Coalesces expensive target progress refreshes so queue/network churn
    /// doesn't rebuild every target on each state transition.
    private var fullProgressRefreshTask: Task<Void, Never>?
    private var hasQueuedFullProgressRefresh = false
    private var deferredLaunchHealingTask: Task<Void, Never>?
    private var isRecoverySweepInFlight = false
    private var queuedRecoveryRequest: (reason: OfflineDownloadRecoveryReason, resumeEligibleWork: Bool)?

    /// Serializes post-download frequency analysis so only one FFT runs at a time.
    /// Supports suspend/resume for app lifecycle and priority bumping for the playing track.
    private let sidecarAnalysisQueue: SidecarAnalysisQueue
    private let artifactQueue = DownloadArtifactQueue()
    private var isUserPaused = false
    private var isLowPowerSuspended = false
    private var isAppInBackground = false
    private var allowsBackgroundContinuation = false
    private var isPlaybackSensitive = false
    private var isNetworkPolicyOverridden = false
    private var networkPolicyOverrideTask: Task<Void, Never>?
    internal var networkPolicyOverrideDuration: TimeInterval = 60 * 60
    private let retryPolicy = DownloadRetryPolicy()
    private lazy var targetReconciler = DownloadTargetReconciler(
        dependencies: .init(
            targetRepository: targetRepository,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            downloadManager: downloadManager,
            currentDownloadQuality: { [weak self] in self?.currentDownloadQuality() ?? "original" },
            clearLyricsCaches: { [lyricsService] references in
                await lyricsService.clearCaches(for: references)
            }
        )
    )
    private lazy var cleanupCoordinator = OfflineDownloadCleanupCoordinator(
        dependencies: .init(
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            clearLyricsCaches: { [lyricsService] references in
                await lyricsService.clearCaches(for: references)
            }
        )
    )
    private lazy var notificationBridge = OfflineDownloadNotificationBridge(
        dependencies: .init(
            fetchPendingDownloadCount: { [weak self] in
                guard let self else { return 0 }
                return (try? await self.downloadManager.countPendingDownloads()) ?? 0
            },
            refreshActiveDownloadTrackIdentities: { [weak self] in
                await self?.refreshActiveDownloadTrackIdentities()
            },
            refreshViewContext: {
                CoreDataStack.shared.refreshViewContext()
            },
            postDownloadsDidChange: {
                NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
            },
            showCompletionToast: { [weak self] in
                self?.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "arrow.down.circle.fill",
                        title: "Downloads Complete"
                    )
                )
            }
        )
    )
    private lazy var targetProgressController = OfflineDownloadTargetProgressController(
        dependencies: .init(
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            canExecuteDownloads: { [weak self] in self?.canExecuteDownloads ?? false },
            isQueueRunning: { [weak self] in self?.isQueueRunning ?? false },
            reconcileTarget: { [weak self] key in
                guard let self else { return }
                try await self.reconcileTarget(key: key)
            }
        )
    )
    private lazy var transferExecutor = DownloadTransferExecutor(
        dependencies: .init(
            downloadManager: downloadManager,
            fetchDirectDownloadURL: { [syncCoordinator] track, quality in
                try await syncCoordinator.getDownloadURL(for: track, quality: quality)
            },
            fetchOfflineDownloadQueueMedia: { [syncCoordinator] track, quality in
                try await syncCoordinator.getOfflineDownloadQueueMedia(for: track, quality: quality)
            },
            shouldAttemptDirectFallback: { [weak self] error, ctx in
                guard let self else { return false }
                return self.shouldAttemptDirectFallback(after: error, for: ctx)
            },
            performDirectDownload: { [downloadManager] url, downloadID, estimatedSize in
                try await DownloadTransferExecutor.downloadWithProgress(
                    from: url,
                    downloadID: downloadID,
                    estimatedSize: estimatedSize,
                    downloadManager: downloadManager
                )
            },
            didComplete: { [weak self] ctx, fileURL in
                await self?.enqueueArtifactReconciliation(ctx: ctx, fileURL: fileURL)
            },
            scheduleDownloadsChanged: { [weak self] in
                self?.notificationBridge.scheduleDownloadsChanged()
            },
            isStillReferenced: { [weak self] ctx in
                guard let self else { return false }
                let reference = OfflineTrackReference(
                    trackRatingKey: ctx.trackRatingKey,
                    trackSourceCompositeKey: ctx.sourceCompositeKey
                )
                return (try? await self.targetRepository.hasAnyMembership(for: reference)) ?? false
            }
        )
    )
    private lazy var queueCoordinator = DownloadQueueCoordinator(
        dependencies: .init(
            canRunAutomatically: { [weak self] in self?.canRunQueueAutomatically ?? false },
            setQueueRunning: { [weak self] value in self?.isQueueRunning = value },
            refreshQueueStatus: { [weak self] in self?.refreshQueueStatusReason() },
            fetchPendingCount: { [weak self] in
                guard let self else { return 0 }
                return (try? await self.downloadManager.countPendingDownloads()) ?? 0
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
                self?.notificationBridge.showQueueCompletionToast()
            }
        )
    )

    private static let maxConcurrentDownloads = 2
    private static let interactivePlaybackConcurrentDownloads = 1
    private static let interactivePlaybackRefreshDelayNs: UInt64 = 1_500_000_000
    private static let foregroundIdleRefreshDelayNs: UInt64 = 250_000_000
    private static let backgroundRefreshDelayNs: UInt64 = 2_500_000_000
    private static let interactivePlaybackWorkerCooldownNs: UInt64 = 750_000_000
    private static let deferredLaunchHealingDelayNs: UInt64 = 8_000_000_000
    private static let launchForegroundRecoveryGrace: TimeInterval = 8

    public init(
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        backgroundExecutionCoordinator: OfflineDownloadBackgroundCoordinating,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        toastCenter: ToastCenter,
        lyricsService: LyricsService,
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil,
        launchRecoveryStartedAt: Date = Date()
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
        self.foregroundWorkScheduler = foregroundWorkScheduler
        self.launchRecoveryStartedAt = launchRecoveryStartedAt
        self.sidecarAnalysisQueue = SidecarAnalysisQueue(foregroundWorkScheduler: foregroundWorkScheduler)

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
        backgroundExecutionCoordinator.onBackgroundURLSessionEvents = { [weak self] identifier, completion in
            Task { @MainActor in
                guard let self else {
                    completion()
                    return
                }
                await self.handleBackgroundURLSessionEvents(identifier: identifier, completion: completion)
            }
        }
        backgroundExecutionCoordinator.onSystemWillSleep = { [weak self] in
            Task { @MainActor in
                await self?.handleSystemWillSleep()
            }
        }
        backgroundExecutionCoordinator.onSystemDidWake = { [weak self] in
            Task { @MainActor in
                await self?.handleSystemDidWake()
            }
        }

        observeNetworkState()
        observeSyncCompletions()

        Task {
            await recoverInterruptedDownloads(reason: .launch, resumeEligibleWork: true)
        }
    }

    // MARK: - Public API

    /// Called when PMS download queue completes an item (via WebSocket activity event).
    /// Restarts the download queue if it's idle, ensuring prepared downloads are picked up.
    public func handleDownloadQueueCompleted() async {
        guard !queueCoordinator.hasActiveTask else { return }
        EnsembleLogger.debug("⬇️ WebSocket: download queue completed — restarting idle queue")
        startQueueIfNeeded()
    }

    public func refreshState() async {
        await refreshTargetSnapshots()
        await refreshAllTargetProgresses()
    }

    /// Extended refresh that also runs download file self-healing.
    /// Use for pull-to-refresh to detect missing files and orphaned targets.
    public func refreshStateWithHealing() async {
        await runDownloadHealing()
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
        await queueCoordinator.cancelCurrentTask()
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

            notificationBridge.notifyDownloadsChangedImmediately()

            EnsembleLogger.debug("🗑️ Removed all downloads, targets, and files")
        } catch {
            EnsembleLogger.debug("❌ Failed to remove all downloads: \(error.localizedDescription)")
        }
    }

    /// Re-download completed tracks in a target whose stored quality differs from
    /// the current download quality setting. Failed tracks remain owned by retry.
    public func redownloadTargetAtCurrentQuality(key: String) async -> OfflineDownloadQualityRefreshResult {
        do {
            try await reconcileTarget(key: key)

            let desiredQuality = currentDownloadQuality()
            let references = try await targetRepository.fetchTrackReferences(targetKey: key)
            let downloadsByKey = try await downloadManager.fetchDownloadsBatch(forReferences: references)
            var requeuedCount = 0

            for ref in references {
                let lookupKey = "\(ref.trackSourceCompositeKey)|\(ref.trackRatingKey)"

                guard let download = downloadsByKey[lookupKey] else {
                    _ = try await downloadManager.createDownload(
                        forTrackRatingKey: ref.trackRatingKey,
                        sourceCompositeKey: ref.trackSourceCompositeKey,
                        quality: desiredQuality
                    )
                    requeuedCount += 1
                    continue
                }

                let currentQuality = download.quality ?? "original"
                guard currentQuality != desiredQuality else { continue }

                switch download.downloadStatus {
                case .completed:
                    try await downloadManager.requeueDownload(download.objectID, quality: desiredQuality)
                    requeuedCount += 1
                case .pending, .downloading, .paused:
                    try await downloadManager.updateDownloadStatus(
                        download.objectID,
                        status: download.downloadStatus,
                        quality: desiredQuality
                    )
                case .failed:
                    continue
                }
            }

            if requeuedCount > 0 {
                await refreshAllTargetProgresses()
                startQueueIfNeeded()

                let pendingCount = (try? await downloadManager.countPendingDownloads()) ?? 0
                backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)
                notificationBridge.notifyDownloadsChangedImmediately()
            } else {
                await refreshTargetProgress(forTargetKey: key)
                await refreshTargetSnapshots()
            }

            EnsembleLogger.debug(
                "🔄 Redownload target at current quality: key=\(key) quality=\(desiredQuality) requeued=\(requeuedCount)"
            )

            return OfflineDownloadQualityRefreshResult(
                requeuedCount: requeuedCount,
                skippedUnsupportedCount: 0
            )
        } catch {
            EnsembleLogger.debug("❌ OfflineDownloadService: Failed redownloading target \(key): \(error.localizedDescription)")
            return OfflineDownloadQualityRefreshResult(requeuedCount: 0, skippedUnsupportedCount: 0)
        }
    }

    public func handlePlaylistRefreshCompleted(serverSourceKey: String) async {
        await reconcilePlaylistTargets(forServerSourceKey: serverSourceKey)
    }

    /// Requeue a failed/offline download for a specific track and wake the queue immediately.
    public func retryDownload(trackRatingKey: String, sourceCompositeKey: String?) async {
        guard let sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else {
            EnsembleLogger.debug("❌ Retry download failed: invalid music source")
            return
        }
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
                "🔁 Retrying download: track=\(trackRatingKey) source=\(sourceCompositeKey) quality=\(quality)"
            )

            await refreshAllTargetProgresses()
            startQueueIfNeeded()

            let pendingCount = (try? await downloadManager.countPendingDownloads()) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)
        } catch {
            EnsembleLogger.debug(
                "❌ Retry download failed: track=\(trackRatingKey) source=\(sourceCompositeKey) reason=\(error.localizedDescription)"
            )
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

            let pendingCount = (try? await downloadManager.countPendingDownloads()) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)

            notificationBridge.notifyDownloadsChangedImmediately()
        } catch {
            EnsembleLogger.debug("❌ Failed enabling offline target \(key): \(error.localizedDescription)")
        }
    }

    private func disableTarget(key: String) async {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            let targetTitle = (try? await targetRepository.fetchTarget(key: key))?.displayName ?? key
            let previousReferences = try await targetRepository.fetchTrackReferences(targetKey: key)
            let total = previousReferences.count
            if total > 0 {
                removalInProgress[key] = RemovalProgress(targetTitle: targetTitle, completed: 0, total: total)
            }

            try await targetRepository.deleteTarget(key: key)
            let orphanedReferences = try await targetRepository.unreferencedTrackReferences(
                from: previousReferences
            )
            try await downloadManager.deleteDownloads(forReferences: orphanedReferences)
            await lyricsService.clearCaches(for: orphanedReferences)
            if total > 0 {
                removalInProgress[key] = RemovalProgress(
                    targetTitle: targetTitle,
                    completed: total,
                    total: total
                )
            }
            _ = try await downloadManager.removeOrphanedDownloadFiles()

            removalInProgress.removeValue(forKey: key)

            await refreshTargetSnapshots()
            await refreshAllTargetProgresses()

            // Notify track-displaying VMs so they re-fetch and reflect updated offline state
            notificationBridge.notifyDownloadsChangedImmediately()
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            EnsembleLogger.info(
                "Offline target removal finished tracks=\(total) files=\(orphanedReferences.count) elapsedMs=\(elapsedMs)"
            )
        } catch {
            removalInProgress.removeValue(forKey: key)
            EnsembleLogger.debug("❌ Failed disabling offline target \(key): \(error.localizedDescription)")
        }
    }

    private func reconcileTarget(key: String) async throws {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard let target = try await targetRepository.fetchTarget(key: key) else {
            return
        }

        let result = try await targetReconciler.reconcileTarget(
            .init(
                key: key,
                kind: target.targetKind,
                ratingKey: target.ratingKey,
                sourceCompositeKey: target.sourceCompositeKey
            )
        )

        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        EnsembleLogger.info(
            "Offline target reconciliation finished tracks=\(result.trackReferenceCount) newPending=\(result.newPendingCount) elapsedMs=\(elapsedMs)"
        )

        await refreshTargetProgress(forTargetKey: key)
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

    /// Resumes the download queue, temporarily overriding connected network restrictions when needed.
    public func resumeQueue() async {
        isUserPaused = false
        if temporaryNetworkPolicyReason != nil {
            startNetworkPolicyOverride()
        }
        try? await applyNetworkPolicy()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
        startQueueIfNeeded()
    }

    /// The connected network restriction that Play can temporarily override.
    public var temporaryResumeQueueReason: QueueStatusReason? {
        temporaryNetworkPolicyReason
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
        await artifactQueue.suspend()
        await sidecarAnalysisQueue.suspend()
        EnsembleLogger.info("Derived download artifacts suspended — app backgrounded")
    }

    /// Resume sidecar analysis when the app foregrounds.
    public func resumeSidecarAnalysis() async {
        await artifactQueue.resume()
        await sidecarAnalysisQueue.resume()
        EnsembleLogger.info("Derived download artifacts resumed — app foregrounded")
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

    /// Stops all in-progress downloads and re-queues those transfers at the new quality.
    public func cancelInProgressDownloads() async {
        let desiredQuality = currentDownloadQuality()
        let interruptedDownloadIDs = (try? await downloadManager.fetchPendingDownloads())?
            .filter { $0.downloadStatus == .downloading }
            .map(\.objectID) ?? []
        await stopQueueForSuspension()
        for downloadID in interruptedDownloadIDs {
            try? await downloadManager.requeueDownload(downloadID, quality: desiredQuality)
        }
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
        startQueueIfNeeded()
    }

    /// Called when the app backgrounds. Suspends discretionary queue work unless
    /// the OS explicitly grants a continued-processing window later.
    public func handleAppDidEnterBackground() async {
        isAppInBackground = true
        allowsBackgroundContinuation = true
        let pendingCount = (try? await downloadManager.countPendingDownloads()) ?? 0
        let activeOrPendingCount = max(
            pendingCount,
            activeDownloadTrackIdentities.count,
            queueCoordinator.hasActiveTask || isQueueRunning ? 1 : 0
        )
        backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: activeOrPendingCount)
        try? await applyNetworkPolicy()
        startQueueIfNeeded()
        refreshQueueStatusReason()
        scheduleFullProgressRefresh()
    }

    /// Called when the app foregrounds so the queue can resume under the current policy.
    public func handleAppWillEnterForeground() async {
        isAppInBackground = false
        allowsBackgroundContinuation = false
        await recoverInterruptedDownloads(reason: .foreground, resumeEligibleWork: true)
    }

    public func handleSystemWillSleep() async {
        allowsBackgroundContinuation = false
        await stopQueueForSuspension()
        await recoverInterruptedDownloads(reason: .systemWillSleep, resumeEligibleWork: false)
    }

    public func handleSystemDidWake() async {
        await recoverInterruptedDownloads(reason: .systemDidWake, resumeEligibleWork: true)
    }

    private func handleBackgroundURLSessionEvents(identifier: String, completion: @escaping () -> Void) async {
        await recoverInterruptedDownloads(reason: .backgroundURLSession(identifier), resumeEligibleWork: true)
        completion()
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.queueCoordinator.cancelCurrentTask()
            await self.recoverInterruptedDownloads(reason: .backgroundExpiration, resumeEligibleWork: false)
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
                    let pendingCount = (try? await downloadManager.countPendingDownloads()) ?? -1
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

        let ctx = DownloadTransferContext(
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
            let result = try await transferExecutor.execute(ctx: ctx, requestedQuality: requestedQuality)
            await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)

            if result.persisted {
                retryPolicy.recordSuccess(
                    trackRatingKey: ctx.trackRatingKey,
                    sourceCompositeKey: ctx.sourceCompositeKey,
                    attemptedDirectFallback: result.attemptedDirectFallback
                )
            }
        } catch {
            if Task.isCancelled {
                EnsembleLogger.debug(
                    "📥 Download transfer cancelled; lifecycle owner will recover track=\(ctx.trackRatingKey) source=\(ctx.sourceCompositeKey)"
                )
                return
            }

            let executionError = error as? DownloadTransferExecutionError
            let underlyingError = executionError?.underlying ?? error
            let resolution = retryPolicy.resolveFailure(
                .init(
                    trackRatingKey: ctx.trackRatingKey,
                    sourceCompositeKey: ctx.sourceCompositeKey,
                    attemptedDirectFallback: executionError?.attemptedDirectFallback ?? false,
                    isNetworkLoss: isNetworkLossError(underlyingError),
                    isRetryableTransfer: underlyingError is DownloadTransferError || isRetryableTruncation(underlyingError),
                    errorDescription: underlyingError.localizedDescription
                )
            )

            switch resolution {
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
                    "🔄 Offline download re-queued (attempt \(attempt)/\(maxAttempts)): track=\(ctx.trackRatingKey) reason=\(underlyingError.localizedDescription)"
                )
            case .fail(let message, _):
                try? await downloadManager.failDownload(ctx.downloadObjectID, error: message)
                EnsembleLogger.debug(
                    "❌ Offline download failed: track=\(ctx.trackRatingKey) source=\(ctx.sourceCompositeKey) reason=\(underlyingError.localizedDescription)"
                )
            }
            // Targeted refresh: only update targets that own this track
            await refreshTargetsForTrack(ratingKey: ctx.trackRatingKey, sourceCompositeKey: ctx.sourceCompositeKey)
        }
    }

    private func enqueueArtifactReconciliation(
        ctx: DownloadTransferContext,
        fileURL: URL
    ) async {
        await sidecarAnalysisQueue.enqueue(
            sourceURL: fileURL,
            sidecarURL: fileURL.appendingPathExtension("freq")
        )
        await artifactQueue.enqueue(
            key: "\(ctx.sourceCompositeKey)|\(ctx.trackRatingKey)"
        ) { @MainActor [weak self] in
            guard let self, await self.waitUntilArtifactWorkIsAllowed() else { return }
            await self.cacheArtworkForDownloadedTrack(ctx: ctx)
            await self.lyricsService.fetchAndCacheLyrics(for: ctx.domainTrack)
        }
    }

    private func waitUntilArtifactWorkIsAllowed() async -> Bool {
        guard let foregroundWorkScheduler else { return !Task.isCancelled }
        return await foregroundWorkScheduler.waitUntilAllowed(.artworkRetry, policy: .idleOnly)
    }

    /// Best-effort artwork repair for completed downloads so offline surfaces retain artwork.
    private func cacheArtworkForDownloadedTrack(ctx: DownloadTransferContext) async {
        guard let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(
            sourceKey: ctx.sourceCompositeKey
        ) else {
            return
        }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }

        var candidates: [(ratingKey: String, path: String)] = []
        if let path = ctx.trackThumbPath,
           !path.isEmpty,
           path != ctx.albumThumbPath || ctx.albumRatingKey == nil {
            candidates.append((ctx.trackRatingKey, path))
        }
        if let albumRatingKey = ctx.albumRatingKey,
           let albumThumbPath = ctx.albumThumbPath,
           !albumThumbPath.isEmpty {
            candidates.append((albumRatingKey, albumThumbPath))
        }

        var seen = Set<String>()
        for candidate in candidates where seen.insert("\(candidate.ratingKey)|\(candidate.path)").inserted {
            let exists = await artworkDownloadManager.localArtworkExists(
                ratingKey: candidate.ratingKey,
                type: .album,
                sourceCompositeKey: ctx.sourceCompositeKey,
                sourcePath: candidate.path,
                dateModifiedSeconds: nil,
                minimumPixelDimension: nil
            )
            guard !exists else { continue }

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
                    identity: ArtworkIdentity(
                        ratingKey: candidate.ratingKey,
                        type: .album,
                        sourcePath: candidate.path,
                        dateModifiedSeconds: nil,
                        sourceCompositeKey: ctx.sourceCompositeKey
                    )
                )
                EnsembleLogger.debug(
                    "🖼️ Reconciled download artwork: track=\(ctx.trackRatingKey) artworkKey=\(candidate.ratingKey)"
                )
            } catch {
                EnsembleLogger.debug(
                    "⚠️ Download artwork reconciliation failed for \(ctx.trackRatingKey): \(error.localizedDescription)"
                )
            }
        }
    }

    private func reconcileCompletedDownloadArtifacts() async {
        do {
            let completed = try await downloadManager.fetchCompletedDownloads()
            let candidates = completed.compactMap { download -> (DownloadTransferContext, URL)? in
                guard let track = download.track,
                      let sourceCompositeKey = track.sourceCompositeKey,
                      let filePath = download.filePath,
                      !filePath.isEmpty else {
                    return nil
                }
                let ctx = DownloadTransferContext(
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
                return (
                    ctx,
                    DownloadManager.downloadsDirectory.appendingPathComponent(filePath)
                )
            }

            for (ctx, fileURL) in candidates {
                await enqueueArtifactReconciliation(ctx: ctx, fileURL: fileURL)
            }
            if !candidates.isEmpty {
                EnsembleLogger.debug(
                    "📦 Queued derived-artifact reconciliation for \(candidates.count) completed download(s)"
                )
            }
        } catch {
            EnsembleLogger.debug(
                "⚠️ Failed queuing derived download artifact reconciliation: \(error.localizedDescription)"
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

            let candidates = completed.compactMap { download -> TruncationScanCandidate? in
                guard let filename = download.filePath, !filename.isEmpty,
                      let track = download.track else { return nil }

                let expectedMs = track.duration
                guard expectedMs > 10_000 else { return nil } // Skip very short tracks
                let expectedSeconds = Double(expectedMs) / 1000.0

                let absolutePath = DownloadManager.absolutePath(forFilename: filename)
                return TruncationScanCandidate(
                    downloadObjectID: download.objectID,
                    title: track.title,
                    absolutePath: absolutePath,
                    expectedSeconds: expectedSeconds
                )
            }

            let truncatedDownloads = await Self.findTruncatedDownloads(candidates)

            for result in truncatedDownloads {
                EnsembleLogger.debug(
                    "[OfflineDownloads] Truncated download detected: '\(result.title)' file=\(String(format: "%.1f", result.fileDuration))s expected=\(String(format: "%.1f", result.expectedSeconds))s — marking failed"
                )
                try? await downloadManager.failDownload(
                    result.downloadObjectID,
                    error: "Truncated (\(String(format: "%.0f", result.fileDuration))s vs \(String(format: "%.0f", result.expectedSeconds))s expected)"
                )
            }

            if !truncatedDownloads.isEmpty {
                EnsembleLogger.debug("[OfflineDownloads] Startup scan found \(truncatedDownloads.count) truncated download(s) — marked as failed for re-download")
            }
        } catch {
            EnsembleLogger.debug("[OfflineDownloads] Truncation scan failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func findTruncatedDownloads(_ candidates: [TruncationScanCandidate]) async -> [TruncatedDownloadResult] {
        await Task.detached(priority: .utility) {
            var truncatedDownloads: [TruncatedDownloadResult] = []

            for candidate in candidates {
                guard FileManager.default.fileExists(atPath: candidate.absolutePath) else { continue }

                let fileURL = URL(fileURLWithPath: candidate.absolutePath)
                do {
                    let audioFile = try AVAudioFile(forReading: fileURL)
                    let sampleRate = audioFile.processingFormat.sampleRate
                    guard sampleRate > 0 else { continue }
                    let fileDuration = Double(audioFile.length) / sampleRate

                    if fileDuration < candidate.expectedSeconds * 0.5 && fileDuration < candidate.expectedSeconds - 10 {
                        // Delete truncated files off the main actor so DownloadManager
                        // self-healing cannot recover them before the failed state is saved.
                        try? FileManager.default.removeItem(at: fileURL)
                        truncatedDownloads.append(
                            TruncatedDownloadResult(
                                downloadObjectID: candidate.downloadObjectID,
                                title: candidate.title,
                                fileDuration: fileDuration,
                                expectedSeconds: candidate.expectedSeconds
                            )
                        )
                    }
                } catch {
                    // AVAudioFile can't read this file — skip, don't block other checks.
                    continue
                }
            }

            return truncatedDownloads
        }.value
    }

    /// Cache artwork for a download target (album, artist, or playlist) so it's available offline.
    private func cacheArtworkForTarget(
        ratingKey: String,
        thumbPath: String?,
        sourceKey: String,
        type: ArtworkType
    ) async {
        guard let thumbPath, !thumbPath.isEmpty else { return }
        guard let persistenceWork = syncCoordinator.beginCurrentSourcePersistenceWork(
            sourceKey: sourceKey
        ) else { return }
        defer { syncCoordinator.finishSourcePersistenceWork(persistenceWork) }

        // Skip if already cached
        if let cachedPath = try? await artworkDownloadManager.getLocalArtworkPath(
            ratingKey: ratingKey,
            type: type,
            sourceCompositeKey: sourceKey,
            sourcePath: thumbPath,
            dateModifiedSeconds: nil
        ), FileManager.default.fileExists(atPath: cachedPath) {
            return
        }

        do {
            guard let artworkURL = try await syncCoordinator.getArtworkURL(
                path: thumbPath,
                sourceKey: sourceKey,
                size: 500
            ) else { return }

            try await artworkDownloadManager.downloadAndCacheArtwork(
                from: artworkURL,
                identity: ArtworkIdentity(
                    ratingKey: ratingKey,
                    type: type,
                    sourcePath: thumbPath,
                    dateModifiedSeconds: nil,
                    sourceCompositeKey: sourceKey
                )
            )
            EnsembleLogger.debug("🖼️ Cached \(type.rawValue) artwork for download target: \(ratingKey)")
        } catch {
            EnsembleLogger.debug("⚠️ Failed caching \(type.rawValue) artwork for target \(ratingKey): \(error.localizedDescription)")
        }
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
        if isNetworkPolicyOverridden && temporaryNetworkPolicyReason != nil {
            return true
        }

        guard !networkMonitor.isConstrained else { return false }

        switch networkMonitor.networkState {
        case .online(.wifi), .online(.wired):
            return true
        case .online(.cellular):
            return DownloadSettingsPreference.storedAllowCellularDownloads()
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

    private var temporaryNetworkPolicyReason: QueueStatusReason? {
        if networkMonitor.isConstrained,
           case .online = networkMonitor.networkState {
            return .lowDataMode
        }

        if case .online(.cellular) = networkMonitor.networkState {
            return DownloadSettingsPreference.storedAllowCellularDownloads() ? nil : .waitingForWiFi
        }

        return nil
    }

    internal var currentDownloadWorkMode: DownloadWorkMode {
        if isAppInBackground {
            return .background
        }
        if isPlaybackSensitive {
            return .interactivePlayback
        }
        return .foregroundIdle
    }

    internal var shouldDeferForegroundHealthRefresh: Bool {
        currentDownloadWorkMode == .interactivePlayback
            && (queueCoordinator.hasActiveTask || isQueueRunning || !activeDownloadTrackIdentities.isEmpty || fullProgressRefreshTask != nil)
    }

    /// Maps current network state to a user-facing queue pause reason
    private func queueReasonForCurrentState() -> QueueStatusReason {
        if isNetworkPolicyOverridden && temporaryNetworkPolicyReason != nil {
            return .idle
        }

        guard !networkMonitor.isConstrained else { return .lowDataMode }

        switch networkMonitor.networkState {
        case .offline:
            return .offline
        case .online(.cellular):
            if DownloadSettingsPreference.storedAllowCellularDownloads() {
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

    private func startNetworkPolicyOverride() {
        networkPolicyOverrideTask?.cancel()
        isNetworkPolicyOverridden = true
        let duration = networkPolicyOverrideDuration

        EnsembleLogger.info("Temporary download network override started durationSeconds=\(Int(duration))")
        networkPolicyOverrideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }

            self.isNetworkPolicyOverridden = false
            self.networkPolicyOverrideTask = nil
            if !self.canExecuteDownloads {
                await self.stopQueueForSuspension()
            }
            try? await self.applyNetworkPolicy()
            self.refreshQueueStatusReason()
            self.scheduleFullProgressRefresh()
            self.startQueueIfNeeded()
            EnsembleLogger.info("Temporary download network override expired")
        }
    }

    // MARK: - Progress / Snapshots

    private func refreshTargetSnapshots() async {
        if let snapshots = await targetProgressController.refreshTargetSnapshots() {
            targets = snapshots
        }
    }

    /// Refreshes only the targets that contain the given track.
    /// Much cheaper than refreshAllTargetProgresses() during bulk downloads — O(owning targets)
    /// instead of O(all targets × tracks per target).
    /// Note: activeDownloadTrackIdentities is NOT refreshed here — the debounced
    /// scheduleDownloadChangeNotification() handles that to batch spinner updates
    /// instead of firing per-track during bulk downloads.
    private func refreshTargetsForTrack(ratingKey: String, sourceCompositeKey: String) async {
        let result = await targetProgressController.refreshTargetsForTrack(
            ratingKey: ratingKey,
            sourceCompositeKey: sourceCompositeKey
        )
        switch result {
        case .snapshots(let snapshots):
            targets = snapshots
        case .requiresFullRefresh:
            await refreshAllTargetProgresses()
        }
    }

    private func refreshAllTargetProgresses() async {
        if let state = await targetProgressController.refreshAllTargetProgresses() {
            targets = state.snapshots
            if state.activeDownloadTrackIdentities != activeDownloadTrackIdentities {
                activeDownloadTrackIdentities = state.activeDownloadTrackIdentities
            }
        }
    }

    /// Recomputes the set of track source-scoped identities that are pending or actively downloading.
    private func refreshActiveDownloadTrackIdentities() async {
        if let keys = await targetProgressController.refreshActiveDownloadTrackIdentities() {
            if keys != activeDownloadTrackIdentities {
                activeDownloadTrackIdentities = keys
            }
        }
    }

    private func refreshTargetProgress(forTargetKey targetKey: String) async {
        await targetProgressController.refreshTargetProgress(forTargetKey: targetKey)
    }

    // MARK: - Sync / Network Reconciliation

    /// Runs the best-effort healing steps that keep persisted downloads aligned
    /// with target memberships before the UI recomputes its snapshots.
    private func runDownloadHealing() async {
        if !isAppInBackground {
            if let foregroundWorkScheduler {
                guard await foregroundWorkScheduler.waitUntilAllowed(.offlineHealing, policy: .idleOnly) else {
                    return
                }
            }
        }

        let runStartedAt = Date()
        // Verify files on disk, mark missing/invalid downloads as failed.
        try? await downloadManager.repairDownloads()
        // Catch truncated audio files (interrupted downloads that passed basic checks).
        await scanForTruncatedDownloads()

        do {
            let removedCount = try await cleanupCoordinator.removeOrphanedCompletedDownloads()
            lastHealingSummary = OfflineDownloadHealingSummary(
                ranAt: runStartedAt,
                orphanedCompletedDownloadsRemoved: removedCount,
                errorDescription: nil
            )
            if removedCount > 0 {
                EnsembleLogger.debug("🧹 OfflineDownloadService: removed \(removedCount) orphaned completed download(s)")
            }
        } catch {
            lastHealingSummary = OfflineDownloadHealingSummary(
                ranAt: runStartedAt,
                orphanedCompletedDownloadsRemoved: 0,
                errorDescription: error.localizedDescription
            )
            EnsembleLogger.debug("❌ Failed removing orphaned completed downloads: \(error.localizedDescription)")
        }

        await reconcileCompletedDownloadArtifacts()
    }

    /// Reconciles interrupted work after launch, foreground, background URLSession wakes,
    /// and macOS sleep/wake. Persisted downloads should never remain stuck in `.downloading`
    /// after the process or execution window that owned them has ended.
    private func recoverInterruptedDownloads(
        reason: OfflineDownloadRecoveryReason,
        resumeEligibleWork: Bool
    ) async {
        if isRecoverySweepInFlight {
            if queuedRecoveryRequest?.resumeEligibleWork != true || resumeEligibleWork {
                queuedRecoveryRequest = (reason, resumeEligibleWork)
            }
            EnsembleLogger.debug("📦 Offline download recovery sweep queued reason=\(reason.logDescription)")
            return
        }

        isRecoverySweepInFlight = true
        var request = (reason: reason, resumeEligibleWork: resumeEligibleWork)
        repeat {
            queuedRecoveryRequest = nil
            await performInterruptedDownloadRecovery(
                reason: request.reason,
                resumeEligibleWork: request.resumeEligibleWork
            )
            guard let queuedRecoveryRequest else { break }
            request = queuedRecoveryRequest
        } while true
        isRecoverySweepInFlight = false
    }

    private func performInterruptedDownloadRecovery(
        reason: OfflineDownloadRecoveryReason,
        resumeEligibleWork: Bool
    ) async {
        if reason == .foreground,
           Date().timeIntervalSince(launchRecoveryStartedAt) < Self.launchForegroundRecoveryGrace,
           deferredLaunchHealingTask != nil {
            EnsembleLogger.debug("📦 Offline download foreground recovery coalesced with launch recovery")
            return
        }

        EnsembleLogger.debug("📦 Offline download recovery sweep started reason=\(reason.logDescription)")

        let shouldResume = resumeEligibleWork || (reason == .backgroundExpiration && !isAppInBackground)
        let recoveredStatus: CDDownload.Status = shouldResume && canRunQueueAutomatically ? .pending : .paused
        if queueCoordinator.hasActiveTask {
            EnsembleLogger.debug("📦 Offline download recovery preserved records owned by the live queue")
        } else {
            try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: recoveredStatus)
        }

        if shouldResume {
            try? await applyNetworkPolicy()
        } else {
            refreshQueueStatusReason()
        }

        if shouldUseLightweightStartupRecovery(for: reason) {
            await refreshTargetSnapshots()
            scheduleDeferredLaunchHealing()
            if shouldResume {
                startQueueIfNeeded()
            }
            EnsembleLogger.debug(
                "📦 Offline download recovery sweep finished reason=\(reason.logDescription) resume=\(shouldResume) recoveredStatus=\(recoveredStatus.rawValue) deferredHealing=true"
            )
            return
        }

        await runDownloadHealing()
        await refreshAllTargetProgresses()
        scheduleFullProgressRefresh(forceImmediate: true)

        if shouldResume {
            startQueueIfNeeded()
        }

        EnsembleLogger.debug(
            "📦 Offline download recovery sweep finished reason=\(reason.logDescription) resume=\(shouldResume) recoveredStatus=\(recoveredStatus.rawValue)"
        )
    }

    private func shouldUseLightweightStartupRecovery(for reason: OfflineDownloadRecoveryReason) -> Bool {
        switch reason {
        case .launch, .foreground, .backgroundExpiration:
            return true
        case .backgroundURLSession, .systemWillSleep, .systemDidWake:
            return false
        }
    }

    /// Defers disk and progress integrity sweeps until after launch has had time
    /// to render and accept interaction. Whole-library offline targets can own
    /// thousands of files, so startup must not synchronously parse them.
    private func scheduleDeferredLaunchHealing() {
        guard deferredLaunchHealingTask == nil else { return }

        deferredLaunchHealingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.deferredLaunchHealingDelayNs)
            guard let self, !Task.isCancelled else { return }
            guard !self.isAppInBackground else {
                self.deferredLaunchHealingTask = nil
                return
            }

            EnsembleLogger.info("📦 Offline download deferred healing started")
            await self.runDownloadHealing()
            await self.refreshAllTargetProgresses()
            self.deferredLaunchHealingTask = nil
            EnsembleLogger.info("📦 Offline download deferred healing finished")
        }
    }

    private func observeNetworkState() {
        Publishers.Merge(
            networkMonitor.$networkState.map { _ in () },
            networkMonitor.$isConstrained.dropFirst().map { _ in () }
        )
            .sink { [weak self] in
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
        await queueCoordinator.cancelCurrentTask()
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
                guard let self else { return }
                if !self.isAppInBackground,
                   let foregroundWorkScheduler = self.foregroundWorkScheduler {
                    guard await foregroundWorkScheduler.waitUntilAllowed(.downloadProgressRecompute, policy: .idleOnly) else {
                        return
                    }
                }
                await self.refreshAllTargetProgresses()
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

            if let foregroundWorkScheduler = self.foregroundWorkScheduler {
                guard await foregroundWorkScheduler.waitUntilAllowed(.downloadProgressRecompute, policy: .idleOnly) else {
                    self.fullProgressRefreshTask = nil
                    return
                }
            }
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

    private func shouldAttemptDirectFallback(after error: Error, for ctx: DownloadTransferContext) -> Bool {
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

        syncCoordinator.$lastContentChange
            .compactMap { $0 }
            .sink { [weak self] change in
                Task { @MainActor in
                    await self?.handleContentChange(change)
                }
            }
            .store(in: &cancellables)
    }

    func handleContentChange(_ change: SyncContentChange) async {
        guard change.libraryResult?.removedTracks ?? 0 > 0 else { return }

        do {
            let removedFiles = try await downloadManager.removeOrphanedDownloadFiles()
            if removedFiles > 0 {
                EnsembleLogger.info("Removed \(removedFiles) orphaned download artifact(s) after library sync")
            }
        } catch {
            EnsembleLogger.error("Failed removing orphaned download artifacts after library sync: \(error.localizedDescription)")
        }
    }

    private func handleSourceSyncUpdate(_ statuses: [MusicSourceIdentifier: MusicSourceStatus]) async {
        if let foregroundWorkScheduler {
            guard await foregroundWorkScheduler.waitUntilAllowed(.offlineHealing, policy: .idleOnly) else {
                return
            }
        }

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
        let raw = AudioQualityPreference.storedDownloadQuality()
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
        MediaSourceIdentity.serverSourceKey(from: sourceCompositeKey)
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

// MARK: - Derived Download Artifact Queue

actor DownloadArtifactQueue {
    typealias Work = @MainActor @Sendable () async -> Void

    private var pending: [(key: String, work: Work)] = []
    private var activeKey: String?
    private var workerTask: Task<Void, Never>?
    private var isSuspended = false

    func enqueue(key: String, work: @escaping Work) {
        guard activeKey != key, !pending.contains(where: { $0.key == key }) else { return }
        pending.append((key, work))
        startWorkerIfNeeded()
    }

    func suspend() {
        isSuspended = true
    }

    func resume() {
        isSuspended = false
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard !isSuspended, workerTask == nil, !pending.isEmpty else { return }
        workerTask = Task { await drain() }
    }

    private func drain() async {
        while !isSuspended, !pending.isEmpty {
            let item = pending.removeFirst()
            activeKey = item.key
            await item.work()
            activeKey = nil
        }
        workerTask = nil
        startWorkerIfNeeded()
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
    private weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    private var pending: [(sourceURL: URL, sidecarURL: URL)] = []
    /// The item currently being analyzed (popped from pending, held here for re-queuing on suspend).
    private var currentItem: (sourceURL: URL, sidecarURL: URL)?
    /// Active worker task. Cancelled on suspend().
    private var workerTask: Task<Void, Never>?
    private var isSuspended = false

    init(foregroundWorkScheduler: ForegroundWorkScheduling? = nil) {
        self.foregroundWorkScheduler = foregroundWorkScheduler
    }

    // MARK: - Public Interface

    /// Add an item to the end of the queue. Skips duplicates (same sourceURL already pending).
    func enqueue(sourceURL: URL, sidecarURL: URL) {
        guard Self.sourceFileExists(sourceURL, sidecarURL: sidecarURL) else { return }
        guard !FileManager.default.fileExists(atPath: sidecarURL.path) else { return }
        guard !pending.contains(where: { $0.sourceURL == sourceURL }) else { return }
        pending.append((sourceURL: sourceURL, sidecarURL: sidecarURL))
        startWorkerIfNeeded()
    }

    /// Move an item to the front so it runs next. If not already queued, inserts it.
    /// No-op if the sidecar file already exists.
    func prioritize(sourceURL: URL, sidecarURL: URL) {
        guard Self.sourceFileExists(sourceURL, sidecarURL: sidecarURL) else { return }
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
                guard Self.sourceFileExists(item.sourceURL, sidecarURL: item.sidecarURL) else {
                    await self.clearCurrentItem()
                    continue
                }
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
                guard Self.sourceFileExists(item.sourceURL, sidecarURL: item.sidecarURL) else {
                    await self.clearCurrentItem()
                    continue
                }
                if let scheduler = await self.scheduler() {
                    guard await scheduler.waitUntilAllowed(.sidecarAnalysis, policy: .playbackSafe) else {
                        await self.requeueCurrentItem()
                        break
                    }
                }
                if let timeline = await FrequencyAnalysisService.analyzeForSidecar(fileURL: item.sourceURL) {
                    guard Self.sourceFileExists(item.sourceURL, sidecarURL: item.sidecarURL) else {
                        await self.clearCurrentItem()
                        continue
                    }
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

    private func scheduler() -> ForegroundWorkScheduling? {
        foregroundWorkScheduler
    }

    private static func sourceFileExists(_ sourceURL: URL, sidecarURL: URL) -> Bool {
        let exists = FileManager.default.fileExists(atPath: sourceURL.path)
        if !exists {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        return exists
    }
}
