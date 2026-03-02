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
    public let progress: Float

    public var isComplete: Bool {
        totalTrackCount > 0 && completedTrackCount >= totalTrackCount
    }
}

@MainActor
public final class OfflineDownloadService: ObservableObject {
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

    private let downloadManager: DownloadManagerProtocol
    private let targetRepository: OfflineDownloadTargetRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let networkMonitor: NetworkMonitor
    private let backgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating

    private var queueTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastObservedSyncBySource: [String: Date] = [:]

    public init(
        downloadManager: DownloadManagerProtocol,
        targetRepository: OfflineDownloadTargetRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        networkMonitor: NetworkMonitor,
        backgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating
    ) {
        self.downloadManager = downloadManager
        self.targetRepository = targetRepository
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.networkMonitor = networkMonitor
        self.backgroundExecutionCoordinator = backgroundExecutionCoordinator

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
    /// Returns the number of tracks re-queued for refresh.
    public func requeueCompletedDownloadsForCurrentQuality() async -> Int {
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

            return requeuedCount
        } catch {
            #if DEBUG
            EnsembleLogger.debug(
                "❌ Failed re-queueing completed downloads for quality refresh: \(error.localizedDescription)"
            )
            #endif
            return 0
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
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed enabling offline target \(key): \(error.localizedDescription)")
            #endif
        }
    }

    private func disableTarget(key: String) async {
        do {
            let previousReferences = try await targetRepository.fetchTrackReferences(targetKey: key)
            try await targetRepository.deleteTarget(key: key)

            // Reference-counted cleanup: only remove a track file when no target still references it.
            for reference in previousReferences {
                let count = try await targetRepository.membershipCount(for: reference)
                if count == 0 {
                    try await downloadManager.deleteDownload(
                        forTrackRatingKey: reference.trackRatingKey,
                        sourceCompositeKey: reference.trackSourceCompositeKey
                    )
                }
            }

            await refreshTargetSnapshots()
            await refreshAllTargetProgresses()
        } catch {
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
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    continue
                }

                let pendingDownloads = try await downloadManager.fetchPendingDownloads()
                guard let nextDownload = pendingDownloads.first else {
                    isQueueRunning = false
                    backgroundExecutionCoordinator.finishCurrentTask(success: true)
                    queueTask = nil
                    return
                }

                isQueueRunning = true
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
            let primaryURL = try await syncCoordinator.getOfflineDownloadURL(for: domainTrack, quality: requestedQuality)
            var selectedURL = primaryURL
            var selectedMode = "universal"

            #if DEBUG
            EnsembleLogger.debug(
                "⬇️ Offline download attempt: track=\(track.ratingKey) stage=\(selectedMode) url=\(selectedURL)"
            )
            #endif
            var (temporaryURL, response) = try await URLSession.shared.download(from: selectedURL)
            if let httpResponse = response as? HTTPURLResponse,
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

    private func localFileURL(for track: CDTrack, quality: StreamingQuality, response: URLResponse) -> URL {
        let safeSource = (track.sourceCompositeKey ?? "unknown")
            .replacingOccurrences(of: ":", with: "_")
        let responseExtension = response.suggestedFilename.flatMap { URL(fileURLWithPath: $0).pathExtension }
        let ext = responseExtension?.isEmpty == false ? responseExtension! : "m4a"
        let fileName = "\(track.ratingKey)_\(safeSource)_\(quality.rawValue).\(ext)"
        return DownloadManager.downloadsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    private var canExecuteDownloads: Bool {
        switch networkMonitor.networkState {
        case .online(.wifi), .online(.wired):
            return true
        case .online(.cellular), .online(.other), .offline, .limited, .unknown:
            return false
        }
    }

    // MARK: - Progress / Snapshots

    private func refreshTargetSnapshots() async {
        do {
            let fetched = try await targetRepository.fetchTargets()
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
                    progress: $0.progress
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

            var completed = 0
            var downloading = 0
            var pending = 0
            var paused = 0
            var failed = 0
            var firstFailure: String?

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
            } else if downloading > 0 {
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
