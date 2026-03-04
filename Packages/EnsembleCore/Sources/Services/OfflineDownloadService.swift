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
    private var unsupportedTranscodeServerKeys: Set<String> = []
    private var downloadedBytesByTargetKey: [String: Int64] = [:]
    private var qualityMismatchByTargetKey: [String: Int] = [:]
    private var failedTracksByTargetKey: [String: Int] = [:]

    private static let unsupportedTranscodeServerDefaultsKey = "offlineTranscodeUnsupportedServerKeys"

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
        self.unsupportedTranscodeServerKeys = Set(
            UserDefaults.standard.stringArray(forKey: Self.unsupportedTranscodeServerDefaultsKey) ?? []
        )

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

            if requeuedCount > 0 {
                await refreshAllTargetProgresses()
                startQueueIfNeeded()
                let pendingCount = (try? await downloadManager.fetchPendingDownloads().count) ?? 0
                backgroundExecutionCoordinator.requestContinuedProcessingIfAvailable(
                    pendingTrackCount: pendingCount
                )
            }

            #if DEBUG
            EnsembleLogger.debug(
                "🔄 Re-queued completed downloads for quality refresh: count=\(requeuedCount) targetQuality=\(desiredQuality)"
            )
            #endif

            if requeuedCount > 0 {
                NotificationCenter.default.post(name: Self.downloadsDidChange, object: nil)
            }

            return OfflineDownloadQualityRefreshResult(
                requeuedCount: requeuedCount,
                skippedUnsupportedCount: 0
            )
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "❌ Failed re-queueing completed downloads for quality refresh: \(error.localizedDescription)"
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
            try await targetRepository.deleteTarget(key: key)

            let total = previousReferences.count
            if total > 0 {
                removalInProgress[key] = RemovalProgress(targetTitle: targetTitle, completed: 0, total: total)
            }

            // Reference-counted cleanup: only remove a track file when no target still references it.
            for (index, reference) in previousReferences.enumerated() {
                let count = try await targetRepository.membershipCount(for: reference)
                if count == 0 {
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

    private func runQueueLoop() async {
        while !Task.isCancelled {
            do {
                try await applyNetworkPolicy()

                guard canExecuteDownloads else {
                    isQueueRunning = false
                    // Publish a descriptive reason so detail views can show a banner
                    queueStatusReason = queueReasonForCurrentState()
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                let pendingDownloads = try await downloadManager.fetchPendingDownloads()
                guard let nextDownload = pendingDownloads.first else {
                    isQueueRunning = false
                    queueStatusReason = .idle
                    backgroundExecutionCoordinator.finishCurrentTask(success: true)
                    queueTask = nil
                    return
                }

                isQueueRunning = true
                queueStatusReason = .downloading
                await process(download: nextDownload)

                // Keep BG progress updates coarse-grained to avoid update churn.
                let completedCount = targets.reduce(0) { $0 + $1.completedTrackCount }
                let totalCount = targets.reduce(0) { $0 + $1.totalTrackCount }
                backgroundExecutionCoordinator.setProgress(
                    completedUnitCount: completedCount,
                    totalUnitCount: totalCount
                )
            } catch {
                #if DEBUG
                EnsembleLogger.debug("❌ Offline queue iteration failed: \(error.localizedDescription)")
                #endif
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        isQueueRunning = false
        queueTask = nil
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

            if requestedQuality != .original {
                do {
                    #if DEBUG
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(track.ratingKey) stage=download-queue quality=\(requestedQuality.rawValue)"
                    )
                    #endif
                    let queuePayload = try await syncCoordinator.getOfflineDownloadQueueMedia(
                        for: domainTrack,
                        quality: requestedQuality
                    )
                    guard !queuePayload.data.isEmpty else {
                        throw DownloadProcessingError.emptyPayload("download-queue")
                    }

                    let destinationURL = localFileURL(
                        for: track,
                        quality: requestedQuality,
                        suggestedFilename: queuePayload.suggestedFilename,
                        mimeType: queuePayload.mimeType,
                        payload: queuePayload.data
                    )
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try? FileManager.default.removeItem(at: destinationURL)
                    }
                    try queuePayload.data.write(to: destinationURL, options: [.atomic])

                    let attributes = try? FileManager.default.attributesOfItem(atPath: destinationURL.path)
                    let persistedFileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? Int64(queuePayload.data.count)
                    guard persistedFileSize > 0 else {
                        throw DownloadProcessingError.emptyPayload("download-queue")
                    }

                    #if DEBUG
                    EnsembleLogger.debug(
                        "✅ Offline download stored: track=\(track.ratingKey) path=\(destinationURL.lastPathComponent) size=\(persistedFileSize) mode=download-queue"
                    )
                    #endif

                    try await downloadManager.completeDownload(
                        download.objectID,
                        filePath: destinationURL.path,
                        fileSize: persistedFileSize,
                        quality: requestedQuality.rawValue
                    )
                    await cacheArtworkForDownloadedTrack(track)
                    await refreshAllTargetProgresses()
                    return
                } catch {
                    #if DEBUG
                    EnsembleLogger.debug(
                        "⚠️ Download queue transcode attempt failed for track=\(track.ratingKey): \(error.localizedDescription)"
                    )
                    #endif
                }
            }

            var selectedURL: URL
            var selectedMode: String

            if requestedQuality != .original,
               isTranscodeUnsupported(forSourceCompositeKey: sourceCompositeKey) {
                selectedURL = try await syncCoordinator.getStreamURL(for: domainTrack, quality: .original)
                selectedMode = "direct-original-known-unsupported"
                effectiveQuality = .original
                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Skipping offline transcode attempts for server with known unsupported transcode capability: source=\(sourceCompositeKey)"
                )
                #endif
            } else {
                selectedURL = try await syncCoordinator.getOfflineDownloadURL(
                    for: domainTrack,
                    quality: requestedQuality
                )
                selectedMode = "universal"
            }

            #if DEBUG
            EnsembleLogger.debug(
                "⬇️ Offline download attempt: track=\(track.ratingKey) stage=\(selectedMode) url=\(selectedURL)"
            )
            #endif
            var (temporaryURL, response) = try await URLSession.shared.download(from: selectedURL)
            if selectedMode == "universal",
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 400 {
                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Offline universal URL rejected (400), retrying fallback transcode URL for track=\(track.ratingKey)"
                )
                logRejectedDownloadResponse(
                    response: httpResponse,
                    temporaryURL: temporaryURL,
                    stage: "universal",
                    trackRatingKey: track.ratingKey
                )
                #endif
                try? FileManager.default.removeItem(at: temporaryURL)

                let fallbackAttempts = await transcodeFallbackAttempts(
                    for: domainTrack,
                    quality: requestedQuality
                )
                for attempt in fallbackAttempts {
                    selectedURL = attempt.url
                    selectedMode = attempt.mode
                    #if DEBUG
                    EnsembleLogger.debug(
                        "⬇️ Offline download attempt: track=\(track.ratingKey) stage=\(selectedMode) url=\(selectedURL)"
                    )
                    #endif
                    (temporaryURL, response) = try await URLSession.shared.download(from: selectedURL)

                    if let rejection = response as? HTTPURLResponse,
                       rejection.statusCode == 400 {
                        #if DEBUG
                        logRejectedDownloadResponse(
                            response: rejection,
                            temporaryURL: temporaryURL,
                            stage: selectedMode,
                            trackRatingKey: track.ratingKey
                        )
                        #endif
                        try? FileManager.default.removeItem(at: temporaryURL)
                        continue
                    }
                    break
                }
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode),
               selectedMode != "direct-original-fallback" {
                if httpResponse.statusCode == 400, requestedQuality != .original {
                    markTranscodeUnsupported(forSourceCompositeKey: sourceCompositeKey)
                }
                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Offline transcode rejected (status=\(httpResponse.statusCode)) for quality=\(requestedQuality.rawValue); falling back to direct original download for track=\(track.ratingKey)"
                )
                logRejectedDownloadResponse(
                    response: httpResponse,
                    temporaryURL: temporaryURL,
                    stage: selectedMode,
                    trackRatingKey: track.ratingKey
                )
                #endif
                try? FileManager.default.removeItem(at: temporaryURL)

                selectedURL = try await syncCoordinator.getStreamURL(for: domainTrack, quality: .original)
                selectedMode = "direct-original-fallback"
                effectiveQuality = .original
                #if DEBUG
                EnsembleLogger.debug(
                    "⬇️ Offline download attempt: track=\(track.ratingKey) stage=\(selectedMode) url=\(selectedURL)"
                )
                #endif
                (temporaryURL, response) = try await URLSession.shared.download(from: selectedURL)
            }

            if let httpResponse = response as? HTTPURLResponse {
                #if DEBUG
                EnsembleLogger.debug(
                    "⬇️ Offline download response: track=\(track.ratingKey) status=\(httpResponse.statusCode) quality=\(requestedQuality.rawValue) effectiveQuality=\(effectiveQuality.rawValue) mode=\(selectedMode)"
                )
                if let plexError = httpResponse.value(forHTTPHeaderField: "X-Plex-Error"), !plexError.isEmpty {
                    EnsembleLogger.debug("⬇️ Offline download X-Plex-Error: \(plexError)")
                }
                #endif
                guard (200...299).contains(httpResponse.statusCode) else {
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
            EnsembleLogger.debug(
                "✅ Offline download stored: track=\(track.ratingKey) path=\(destinationURL.lastPathComponent) size=\(persistedFileSize) mode=\(selectedMode)"
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
        } catch {
            if Task.isCancelled {
                try? await downloadManager.updateDownloadStatus(download.objectID, status: .paused)
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

    #if DEBUG
    private func logRejectedDownloadResponse(
        response: HTTPURLResponse,
        temporaryURL: URL,
        stage: String,
        trackRatingKey: String
    ) {
        EnsembleLogger.debug(
            "⬇️ Offline download intermediate rejection: track=\(trackRatingKey) stage=\(stage) status=\(response.statusCode)"
        )

        if let plexError = response.value(forHTTPHeaderField: "X-Plex-Error"), !plexError.isEmpty {
            EnsembleLogger.debug("⬇️ Offline download intermediate X-Plex-Error: \(plexError)")
        }

        if let data = try? Data(contentsOf: temporaryURL), !data.isEmpty {
            let preview = String(decoding: data.prefix(200), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
            EnsembleLogger.debug("⬇️ Offline download intermediate body (preview): \(preview)")
        }
    }
    #endif

    private func transcodeFallbackAttempts(
        for track: Track,
        quality: StreamingQuality
    ) async -> [(mode: String, url: URL)] {
        let candidates: [(
            mode: String,
            preferStreamKeyPath: Bool,
            useAbsolutePathParameter: Bool,
            useAudioEndpoint: Bool,
            useStartWithoutExtension: Bool
        )] = [
            ("transcode-fallback-music-metadata", false, false, false, false),
            ("transcode-fallback-music-part", true, false, false, false),
            ("transcode-fallback-music-metadata-absolute", false, true, false, false),
            ("transcode-fallback-music-part-absolute", true, true, false, false),
            ("transcode-fallback-audio-metadata", false, false, true, false),
            ("transcode-fallback-audio-part", true, false, true, false),
            ("transcode-fallback-audio-metadata-absolute", false, true, true, false),
            ("transcode-fallback-audio-part-absolute", true, true, true, false),
            ("transcode-fallback-music-start-metadata", false, false, false, true),
            ("transcode-fallback-audio-start-metadata", false, false, true, true)
        ]

        var attempts: [(mode: String, url: URL)] = []
        var seen = Set<String>()

        for candidate in candidates {
            do {
                let url = try await syncCoordinator.getOfflineDownloadFallbackURL(
                    for: track,
                    quality: quality,
                    preferStreamKeyPath: candidate.preferStreamKeyPath,
                    useAbsolutePathParameter: candidate.useAbsolutePathParameter,
                    useAudioEndpoint: candidate.useAudioEndpoint,
                    useStartWithoutExtension: candidate.useStartWithoutExtension
                )
                if seen.insert(url.absoluteString).inserted {
                    attempts.append((candidate.mode, url))
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug(
                    "⚠️ Failed building transcode fallback URL (mode=\(candidate.mode)): \(error.localizedDescription)"
                )
                #endif
            }
        }

        return attempts
    }

    private func isTranscodeUnsupported(forSourceCompositeKey sourceCompositeKey: String) -> Bool {
        guard let serverSourceKey = serverSourceKey(fromSourceCompositeKey: sourceCompositeKey) else {
            return false
        }
        return unsupportedTranscodeServerKeys.contains(serverSourceKey)
    }

    private func markTranscodeUnsupported(forSourceCompositeKey sourceCompositeKey: String) {
        guard let serverSourceKey = serverSourceKey(fromSourceCompositeKey: sourceCompositeKey) else {
            return
        }
        guard unsupportedTranscodeServerKeys.insert(serverSourceKey).inserted else {
            return
        }

        UserDefaults.standard.set(
            Array(unsupportedTranscodeServerKeys).sorted(),
            forKey: Self.unsupportedTranscodeServerDefaultsKey
        )

        #if DEBUG
        EnsembleLogger.debug(
            "⚠️ Marked server as offline-transcode-unsupported: \(serverSourceKey)"
        )
        #endif
    }

    private func serverSourceKey(fromSourceCompositeKey sourceCompositeKey: String) -> String? {
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 4 else { return nil }
        return "\(components[0]):\(components[1]):\(components[2])"
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

    private var canExecuteDownloads: Bool {
        switch networkMonitor.networkState {
        case .online(.wifi), .online(.wired):
            return true
        case .online(.cellular), .online(.other), .offline, .limited, .unknown:
            return false
        }
    }

    /// Maps current network state to a user-facing queue pause reason
    private func queueReasonForCurrentState() -> QueueStatusReason {
        switch networkMonitor.networkState {
        case .offline:
            return .offline
        case .online(.cellular), .online(.other):
            return .waitingForWiFi
        case .unknown, .limited:
            return .offline
        case .online(.wifi), .online(.wired):
            return .idle
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
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed refreshing offline target progress: \(error.localizedDescription)")
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
