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

@MainActor
public final class OfflineDownloadService: ObservableObject {
    /// Posted when download targets change (enable/disable/quality refresh) so track-displaying VMs can re-fetch
    public static let downloadsDidChange = Notification.Name("OfflineDownloadsDidChange")
    private enum DownloadProcessingError: LocalizedError {
        case invalidHTTPStatus(Int)
        case emptyPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidHTTPStatus(let statusCode):
                return "Download HTTP status \(statusCode)"
            case .emptyPayload(let url):
                return "Download payload was empty for \(url)"
            }
        }
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

    private var queueTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastObservedSyncBySource: [String: Date] = [:]

    private var downloadedBytesByTargetKey: [String: Int64] = [:]
    private var qualityMismatchByTargetKey: [String: Int] = [:]
    private var failedTracksByTargetKey: [String: Int] = [:]

    /// Debounced notification task so individual download completions don't
    /// spam `downloadsDidChange` during bulk queue processing.
    private var downloadChangeNotificationTask: Task<Void, Never>?

    public init(
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        backgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating,
        artworkDownloadManager: ArtworkDownloadManagerProtocol
    ) {
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.backgroundExecutionCoordinator = backgroundExecutionCoordinator
        self.artworkDownloadManager = artworkDownloadManager

        // Clean up legacy keys from the old transcode blacklist approach.
        UserDefaults.standard.removeObject(forKey: "offlineTranscodeUnsupportedServerKeys")
        UserDefaults.standard.removeObject(forKey: "offlineTranscodeProfileV2Migrated")

        backgroundExecutionCoordinator.onExecutionRequested = { [weak self] in
            self?.startQueueIfNeeded()
        }
        backgroundExecutionCoordinator.onExpiration = { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }

        observeNetworkState()
        observeSyncCompletions()

        Task {
            await refreshState()
            startQueueIfNeeded()
        }
    }

    // MARK: - Public API

    public func refreshState() async {
        await refreshTargetSnapshots()
        await refreshAllTargetProgresses()
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
        } else {
            await disableTarget(key: key)
        }
    }

    public func removeTarget(key: String) async {
        await disableTarget(key: key)
    }

    /// Remove all download targets, memberships, and downloaded files.
    public func removeAllDownloads() async {
        // Stop the download queue first
        queueTask?.cancel()
        queueTask = nil
        isQueueRunning = false
        queueStatusReason = .idle

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

            #if DEBUG
            EnsembleLogger.debug("🗑️ Removed all downloads, targets, and files")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to remove all downloads: \(error.localizedDescription)")
            #endif
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
            #if DEBUG
            EnsembleLogger.debug("❌ OfflineDownloadService: Failed refreshing target \(key): \(error.localizedDescription)")
            #endif
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

            #if DEBUG
            EnsembleLogger.debug(
                "🔁 Retrying download: track=\(trackRatingKey) source=\(sourceCompositeKey ?? "nil") quality=\(quality)"
            )
            #endif

            await refreshAllTargetProgresses()
            startQueueIfNeeded()

            let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
            backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(pendingTrackCount: pendingCount)
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "❌ Retry download failed: track=\(trackRatingKey) source=\(sourceCompositeKey ?? "nil") reason=\(error.localizedDescription)"
            )
            #endif
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

            // Also retry all failed downloads
            let allDownloads = try await downloadManager.fetchDownloads()
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

            #if DEBUG
            EnsembleLogger.debug(
                "🔄 Refresh: re-queued \(requeuedCount) quality-mismatched + \(retriedCount) failed downloads (targetQuality=\(desiredQuality))"
            )
            #endif

            if totalRequeued > 0 {
                CoreDataStack.shared.refreshViewContext()
                NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
            }

            return OfflineDownloadQualityRefreshResult(
                requeuedCount: totalRequeued,
                skippedUnsupportedCount: 0
            )
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "❌ Failed re-queueing downloads for refresh: \(error.localizedDescription)"
            )
            #endif
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed enabling offline target \(key): \(error.localizedDescription)")
            #endif
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed disabling offline target \(key): \(error.localizedDescription)")
            #endif
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
        let downloadQuality = currentDownloadQuality()
        for reference in trackReferences {
            _ = try await downloadManager.createDownload(
                forTrackRatingKey: reference.trackRatingKey,
                sourceCompositeKey: reference.trackSourceCompositeKey,
                quality: downloadQuality
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
        queueTask?.cancel()
        queueTask = nil
        isQueueRunning = false
        queueStatusReason = .paused
        try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
        await refreshAllTargetProgresses()
    }

    /// Resumes the download queue — unpauses tracks and restarts the queue loop.
    public func resumeQueue() async {
        try? await downloadManager.updateDownloads(withStatuses: [.paused], to: .pending)
        await refreshAllTargetProgresses()
        startQueueIfNeeded()
    }

    /// Stops all in-progress downloads immediately and re-queues them as pending.
    /// Used when download quality changes to avoid continuing old-quality downloads.
    public func cancelInProgressDownloads() async {
        queueTask?.cancel()
        queueTask = nil
        isQueueRunning = false
        queueStatusReason = .idle
        try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .pending)
        await refreshAllTargetProgresses()
    }

    // MARK: - Queue Execution

    private func startQueueIfNeeded() {
        guard queueTask == nil else { return }

        queueTask = Task { [weak self] in
            guard let self else { return }
            await self.runQueueLoop()
        }
    }

    private func handleBackgroundTaskExpiration() {
        queueTask?.cancel()
        queueTask = nil
        isQueueRunning = false
        Task {
            try? await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
            await refreshAllTargetProgresses()
        }
    }

    /// Maximum number of downloads that run simultaneously
    private static let maxConcurrentDownloads = 3

    private func runQueueLoop() async {
        // Spawn N independent workers that each pull the next pending download
        // when they finish. This keeps all slots busy without batch-and-wait.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.maxConcurrentDownloads {
                group.addTask { await self.workerLoop() }
            }
        }

        // All workers exited — queue is drained or cancelled
        isQueueRunning = false
        queueStatusReason = .idle
        backgroundExecutionCoordinator.finishCurrentTask(success: true)
        queueTask = nil
    }

    /// Single download worker — loops pulling the next pending download until
    /// the queue is empty or the task is cancelled.
    /// Runs the actual download in a detached task so multiple workers execute
    /// their network I/O truly in parallel instead of serializing on @MainActor.
    private func workerLoop() async {
        while !Task.isCancelled {
            do {
                // Wait for network availability (lightweight main-actor check)
                try await applyNetworkPolicy()

                guard canExecuteDownloads else {
                    isQueueRunning = false
                    queueStatusReason = queueReasonForCurrentState()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                // Claim a single pending download (atomic, sets status to .downloading)
                guard let nextDownload = try await downloadManager.fetchNextPendingDownload() else {
                    // No more work for this worker
                    return
                }

                isQueueRunning = true
                queueStatusReason = .downloading

                // Run process() in a detached task so it doesn't serialize on @MainActor.
                // The detached task hops to main actor only when calling @MainActor services,
                // but network I/O runs fully in parallel across workers.
                let selfRef = self
                let detachedProcess = Task.detached {
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
            } catch {
                if Task.isCancelled { return }
                #if DEBUG
                EnsembleLogger.debug("❌ Offline queue worker failed: \(error.localizedDescription)")
                #endif
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func applyNetworkPolicy() async throws {
        if canExecuteDownloads {
            try await downloadManager.updateDownloads(withStatuses: [.paused], to: .pending)
        } else {
            try await downloadManager.updateDownloads(withStatuses: [.downloading], to: .paused)
        }
    }

    private func process(download: CDDownload) async {
        guard let track = download.track,
              let sourceCompositeKey = track.sourceCompositeKey else {
            try? await downloadManager.failDownload(download.objectID, error: "Missing track context")
            await refreshAllTargetProgresses()
            return
        }

        let reference = OfflineTrackReference(
            trackRatingKey: track.ratingKey,
            trackSourceCompositeKey: sourceCompositeKey
        )

        do {
            // Target could be removed while this transfer is waiting.
            let stillReferenced = try await targetRepository.hasAnyMembership(for: reference)
            if !stillReferenced {
                try await downloadManager.deleteDownload(
                    forTrackRatingKey: reference.trackRatingKey,
                    sourceCompositeKey: reference.trackSourceCompositeKey
                )
                await refreshAllTargetProgresses()
                return
            }

            try await downloadManager.updateDownloadStatus(download.objectID, status: .downloading)

            let requestedQuality = streamingQuality(from: download.quality)
            var effectiveQuality = requestedQuality
            let domainTrack = Track(from: track)
            let sizeEstimate = estimatedFileSize(durationMs: track.duration, quality: requestedQuality)

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
                    #if DEBUG
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(track.ratingKey) stage=download-queue quality=\(requestedQuality.rawValue)"
                    )
                    #endif
                    let completed = try await completeViaDownloadQueue(
                        download: download,
                        track: track,
                        domainTrack: domainTrack,
                        quality: requestedQuality,
                        mode: "download-queue"
                    )
                    if completed { return }
                } catch {
                    // Download queue failed — fall through to direct original download.
                    #if DEBUG
                    EnsembleLogger.debug(
                        "⚠️ Download queue failed for track=\(track.ratingKey): \(error.localizedDescription); falling back to direct original"
                    )
                    #endif
                    effectiveQuality = .original
                }
            }

            // Original quality or download queue failed — download the original file directly.
            selectedURL = try await syncCoordinator.getStreamURL(for: domainTrack, quality: .original)
            selectedMode = requestedQuality == .original ? "direct-original" : "direct-original-fallback"
            effectiveQuality = .original

            #if DEBUG
            EnsembleLogger.debug(
                "⬇️ Offline download attempt: track=\(track.ratingKey) stage=\(selectedMode) url=\(selectedURL)"
            )
            #endif
            let (temporaryURL, response) = try await downloadWithProgress(from: selectedURL, downloadID: download.objectID, estimatedSize: sizeEstimate)

            if let httpResponse = response as? HTTPURLResponse {
                #if DEBUG
                EnsembleLogger.debug(
                    "⬇️ Offline download response: track=\(track.ratingKey) status=\(httpResponse.statusCode) quality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) mode=\(selectedMode)"
                )
                if let plexError = httpResponse.value(forHTTPHeaderField: "X-Plex-Error"), !plexError.isEmpty {
                    EnsembleLogger.debug("⬇️ Offline download X-Plex-Error: \(plexError)")
                }
                #endif
                if !(200...299).contains(httpResponse.statusCode) {
                    #if DEBUG
                    if let data = try? Data(contentsOf: temporaryURL), !data.isEmpty {
                        let preview = String(decoding: data.prefix(200), as: UTF8.self)
                            .replacingOccurrences(of: "\n", with: " ")
                        EnsembleLogger.debug("⬇️ Offline download error body (preview): \(preview)")
                    }
                    #endif
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw DownloadProcessingError.invalidHTTPStatus(httpResponse.statusCode)
                }
            }

            let temporaryAttributes = try? FileManager.default.attributesOfItem(atPath: temporaryURL.path)
            let temporaryFileSize = (temporaryAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            guard temporaryFileSize > 0 else {
                throw DownloadProcessingError.emptyPayload(selectedURL.absoluteString)
            }

            let destinationURL = localFileURL(for: track, quality: effectiveQuality, response: response)
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

            #if DEBUG
            // Diagnostic: log Content-Type and file magic bytes to verify transcode actually happened
            let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
            var magicBytesHex = "?"
            if let handle = FileHandle(forReadingAtPath: destinationURL.path),
               let header = try? handle.read(upToCount: 12) {
                magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
                try? handle.close()
            }
            EnsembleLogger.debug(
                "✅ Offline download stored: track=\(track.ratingKey) path=\(destinationURL.lastPathComponent) size=\(persistedFileSize) mode=\(selectedMode) contentType=\(contentType) requestedQuality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) magic=\(magicBytesHex)"
            )
            #endif

            try await downloadManager.completeDownload(
                download.objectID,
                filePath: destinationURL.path,
                fileSize: persistedFileSize,
                quality: effectiveQuality.rawValue
            )
            await cacheArtworkForDownloadedTrack(track)
            await refreshAllTargetProgresses()

            // Notify track-displaying VMs so they re-fetch and reflect updated
            // offline state (e.g. dimming). Debounced to avoid spamming during
            // bulk queue processing.
            scheduleDownloadChangeNotification()
        } catch {
            if Task.isCancelled {
                try? await downloadManager.updateDownloadStatus(download.objectID, status: .paused)
            } else if isNetworkLossError(error) {
                // Network dropped mid-transfer — pause so the download auto-resumes
                // when connectivity returns, instead of marking as permanently failed
                try? await downloadManager.updateDownloadStatus(download.objectID, status: .paused)
                #if DEBUG
                EnsembleLogger.debug(
                    "⏸️ Offline download paused (network lost): track=\(track.ratingKey) source=\(sourceCompositeKey)"
                )
                #endif
            } else {
                try? await downloadManager.failDownload(download.objectID, error: error.localizedDescription)
                #if DEBUG
                EnsembleLogger.debug(
                    "❌ Offline download failed: track=\(track.ratingKey) source=\(sourceCompositeKey) reason=\(error.localizedDescription)"
                )
                #endif
            }
            await refreshAllTargetProgresses()
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
        let detachedTask = Task.detached { [dm] () -> (URL, URLResponse) in
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
                    fileHandle.write(buffer)
                }
                try fileHandle.close()

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
    private func completeViaDownloadQueue(
        download: CDDownload,
        track: CDTrack,
        domainTrack: Track,
        quality: StreamingQuality,
        mode: String
    ) async throws -> Bool {
        let queuePayload = try await syncCoordinator.getOfflineDownloadQueueMedia(
            for: domainTrack,
            quality: quality
        )
        guard !queuePayload.data.isEmpty else {
            return false
        }

        let destinationURL = localFileURL(
            for: track,
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

        #if DEBUG
        // Log magic bytes for format verification
        var magicBytesHex = "?"
        if let handle = FileHandle(forReadingAtPath: destinationURL.path),
           let header = try? handle.read(upToCount: 12) {
            magicBytesHex = header.map { String(format: "%02x", $0) }.joined(separator: " ")
            try? handle.close()
        }
        EnsembleLogger.debug(
            "✅ Offline download stored: track=\(track.ratingKey) path=\(destinationURL.lastPathComponent) size=\(queueFileSize) mode=\(mode) contentType=\(queuePayload.mimeType ?? "unknown") magic=\(magicBytesHex)"
        )
        #endif

        try await downloadManager.completeDownload(
            download.objectID,
            filePath: destinationURL.path,
            fileSize: queueFileSize,
            quality: quality.rawValue
        )
        await cacheArtworkForDownloadedTrack(track)
        await refreshAllTargetProgresses()
        scheduleDownloadChangeNotification()
        return true
    }

    private func localFileURL(for track: CDTrack, quality: StreamingQuality, response: URLResponse) -> URL {
        let safeSource = (track.sourceCompositeKey ?? "unknown")
            .replacingOccurrences(of: ":", with: "_")
        let responseExtension = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = responseExtension?.isEmpty == false
            ? responseExtension!
            : inferredFileExtension(mimeType: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), payload: nil)
        let fileName = "\(track.ratingKey)_\(safeSource)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Best-effort artwork caching for newly downloaded tracks so offline lists/details keep artwork.
    private func cacheArtworkForDownloadedTrack(_ track: CDTrack) async {
        let sourceKey = track.sourceCompositeKey
        let albumRatingKey = track.album?.ratingKey
        let albumThumbPath = track.album?.thumbPath

        var candidates: [(ratingKey: String, path: String)] = []
        if let path = track.thumbPath, !path.isEmpty {
            candidates.append((track.ratingKey, path))
        }
        if let albumRatingKey, let albumThumbPath, !albumThumbPath.isEmpty {
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
                    sourceKey: sourceKey,
                    size: 500
                ) else {
                    continue
                }

                try await artworkDownloadManager.downloadAndCacheArtwork(
                    from: artworkURL,
                    ratingKey: candidate.ratingKey,
                    type: .album
                )

                #if DEBUG
                EnsembleLogger.debug(
                    "🖼️ Cached artwork for downloaded track: track=\(track.ratingKey) artworkKey=\(candidate.ratingKey)"
                )
                #endif
            } catch {
                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Failed caching artwork for downloaded track \(track.ratingKey): \(error.localizedDescription)"
                )
                #endif
            }
        }
    }

    private func localFileURL(
        for track: CDTrack,
        quality: StreamingQuality,
        suggestedFilename: String?,
        mimeType: String?,
        payload: Data?
    ) -> URL {
        let safeSource = (track.sourceCompositeKey ?? "unknown")
            .replacingOccurrences(of: ":", with: "_")
        let suggestedExtension = suggestedFilename
            .flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = suggestedExtension?.isEmpty == false
            ? suggestedExtension!
            : inferredFileExtension(mimeType: mimeType, payload: payload)
        let fileName = "\(track.ratingKey)_\(safeSource)_\(quality.rawValue).\(ext)"
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
        queueStatusReason = queueReasonForCurrentState()
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed fetching offline target snapshots: \(error.localizedDescription)")
            #endif
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
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed refreshing offline target progress: \(error.localizedDescription)")
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed refreshing active download ratingKeys: \(error.localizedDescription)")
            #endif
        }
    }

    private func refreshTargetProgress(forTargetKey targetKey: String) async {
        do {
            let references = try await targetRepository.fetchTrackReferences(targetKey: targetKey)
            guard !references.isEmpty else {
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
                return
            }

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
                guard let download = try await downloadManager.fetchDownload(
                    forTrackRatingKey: reference.trackRatingKey,
                    sourceCompositeKey: reference.trackSourceCompositeKey
                ) else {
                    pending += 1
                    continue
                }

                switch download.downloadStatus {
                case .completed:
                    completed += 1
                    downloadedBytes += max(download.fileSize, 0)
                    // Track quality mismatches for the refresh indicator
                    if let quality = download.quality, quality != desiredQuality {
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
                // Show "Downloading" when tracks are actively downloading OR when
                // the queue is running with pending tracks (between track completions)
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed refreshing target progress for \(targetKey): \(error.localizedDescription)")
            #endif
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
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s debounce
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
                        try await self.applyNetworkPolicy()
                        await self.refreshAllTargetProgresses()
                        self.startQueueIfNeeded()
                    } catch {
                        #if DEBUG
                        EnsembleLogger.debug("❌ Failed applying offline network policy: \(error.localizedDescription)")
                        #endif
                    }
                }
            }
            .store(in: &cancellables)
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
        for (source, status) in statuses {
            guard case .lastSynced(let syncDate) = status.syncStatus else { continue }

            let key = source.compositeKey
            if let existing = lastObservedSyncBySource[key], existing >= syncDate {
                continue
            }

            lastObservedSyncBySource[key] = syncDate
            await reconcileTargets(forSourceCompositeKey: key)
            if let serverSourceKey = Self.serverSourceKey(fromLibrarySourceKey: key) {
                await reconcilePlaylistTargets(forServerSourceKey: serverSourceKey)
            }
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed reconciling source targets for \(sourceCompositeKey): \(error.localizedDescription)")
            #endif
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
            #if DEBUG
            EnsembleLogger.debug("❌ Failed reconciling playlist targets for \(serverSourceKey): \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Helpers

    private func currentDownloadQuality() -> String {
        let raw = UserDefaults.standard.string(forKey: "downloadQuality") ?? "original"
        switch raw {
        case "original", "high", "medium", "low":
            return raw
        default:
            return "original"
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
