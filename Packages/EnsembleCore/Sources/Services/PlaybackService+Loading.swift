import AVFoundation
import Combine
import EnsembleAPI
import EnsemblePersistence
import EnsembleSiriShared
import Foundation
import EnsembleDomain
import MediaPlayer
import Nuke
#if canImport(QuartzCore)
    import QuartzCore
#endif
#if canImport(UIKit)
    import UIKit
#endif
#if os(macOS)
    import AppKit
#endif

// Resolving, loading, and prefetching sources, and the resolved-file cache.
extension PlaybackService {
    nonisolated static func smartMixTempoMatchingGate(processInfo: ProcessInfo = .processInfo) -> (allowed: Bool, reason: String?) {
        let processorCount = processInfo.processorCount
        if processorCount <= 2 {
            return (false, "processor-count-\(processorCount)")
        }
        if processInfo.isLowPowerModeEnabled {
            return (false, "low-power-mode")
        }
        switch processInfo.thermalState {
        case .serious:
            return (false, "thermal-serious")
        case .critical:
            return (false, "thermal-critical")
        case .nominal, .fair:
            return (true, nil)
        @unknown default:
            return (false, "thermal-unknown")
        }
    }

    nonisolated static func smartMixTempoFallbackReason(
        plan: SmartMixPlan,
        outgoingAnalysis: SmartMixAnalysis,
        incomingAnalysis: SmartMixAnalysis,
        tempoGateReason: String?
    ) -> String? {
        guard !plan.tempoMatched else { return nil }
        if let tempoGateReason {
            return tempoGateReason
        }
        if plan.transitionDuration < SmartMixPlanner.minimumTempoTransitionDuration {
            return "transition-too-short"
        }
        guard let outgoingBPM = outgoingAnalysis.outroTempo.estimatedBPM,
              let incomingBPM = incomingAnalysis.introTempo.estimatedBPM
        else {
            return "tempo-unavailable"
        }
        if outgoingAnalysis.outroTempo.confidence < SmartMixPlanner.minimumTempoConfidence
            || incomingAnalysis.introTempo.confidence < SmartMixPlanner.minimumTempoConfidence {
            return "low-confidence"
        }
        guard let normalizedIncomingBPM = SmartMixPlanner.normalizedIncomingTempo(
            outgoingBPM: outgoingBPM,
            incomingBPM: incomingBPM
        ) else {
            return "tempo-normalization-failed"
        }
        let strongConfidence = outgoingAnalysis.outroTempo.confidence >= SmartMixPlanner.minimumStrongTempoConfidence
            && incomingAnalysis.introTempo.confidence >= SmartMixPlanner.minimumStrongTempoConfidence
        if strongConfidence {
            let outgoingRate = normalizedIncomingBPM / outgoingBPM
            if outgoingRate < SmartMixPlanner.minimumAssertiveTempoRate
                || outgoingRate > SmartMixPlanner.maximumAssertiveTempoRate {
                return "outgoing-rate-out-of-range-\(String(format: "%.3f", outgoingRate))"
            }
        } else {
            let incomingRate = outgoingBPM / normalizedIncomingBPM
            if incomingRate < SmartMixPlanner.minimumSubtleTempoRate
                || incomingRate > SmartMixPlanner.maximumSubtleTempoRate {
                return "incoming-rate-out-of-range-\(String(format: "%.3f", incomingRate))"
            }
        }
        return "beat-alignment-unavailable"
    }

    /// Add or update an item in the cache with LRU tracking.
    /// Must run on MainActor to prevent data races with KVO observers and prefetch tasks.
    /// Cache a resolved file URL with LRU eviction.
    /// Not MainActor-isolated — called from resolveAudioFile's background Task.
    @MainActor
    func cacheFileURL(_ url: URL, for trackId: String) {
        prefetchController.cacheFileURL(
            url,
            for: trackId,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
        cleanupStreamCacheFiles()
    }

    /// Get a cached file URL if available, updating LRU order.
    @MainActor
    func getCachedFileURL(for trackId: String) -> URL? {
        prefetchController.cachedFileURL(
            for: trackId,
            cache: resolvedFileCache
        )
    }

    /// Clear all cached file URLs.
    @MainActor
    func clearFileURLCache() {
        prefetchController.clearFileURLCache(
            cache: resolvedFileCache,
            clearTransport: { [transportCoordinator] in
                transportCoordinator.clear(removeDecisions: false)
            }
        )
        cleanupStreamCacheFiles()
        EnsembleLogger.debug("[Cache] Cleared file URL cache")
    }

    /// Evict cached file URLs for tracks NOT in the given set.
    /// Preserves resolved URLs that overlap with the new queue.
    @MainActor
    func evictPlayerItemsNotIn(_ keepTrackIds: Set<String>) {
        transportCoordinator.discardPreparedStreams(except: keepTrackIds)
        let evictedCount = prefetchController.evictPlayerItemsNotIn(
            keepTrackIds,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
        if evictedCount > 0 {
            cleanupStreamCacheFiles()
        }
        guard evictedCount > 0 else {
            EnsembleLogger.debug("[Cache] Fully overlaps new queue — nothing to evict")
            return
        }
        EnsembleLogger.debug("[Cache] Evicted \(evictedCount) cached URLs + decisions, kept \(resolvedFileCache.count)")
    }

    /// Remove temporary stream cache files created by downloadUniversalStreamToFile.
    /// Keeps only files for the current playback neighborhood (current, next 2, previous 1),
    /// plus files that are scheduled in the AudioEngine's gapless queue or actively downloading.
    func cleanupStreamCacheFiles() {
        prefetchController.cleanupStreamCacheFiles(
            using: resolvedFileCache.snapshot(
                queue: queue,
                currentQueueIndex: currentQueueIndex,
                scheduledTrackIDs: Array(audioEngine?.scheduledTrackIds ?? []),
                activeLoaderTrackIDs: Array(transportCoordinator.activeLoaderTrackIDs())
            )
        )
    }

    @MainActor
    func removeCachedPlayerItem(for trackID: String) {
        prefetchController.removeCachedPlayerItem(
            for: trackID,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )
    }

    @MainActor
    func playCurrentQueueItem(
        forcingFreshItem: Bool = false,
        seekTo startTime: TimeInterval? = nil,
        shouldStartPlayback: Bool = true,
        caller: String = #function
    ) async {
        #if os(iOS)
            appleMusicQueueMutationGeneration &+= 1
        #endif

        playbackPreparationCount += 1
        updateNetworkWorkPressure()
        defer {
            playbackPreparationCount -= 1
            updateNetworkWorkPressure()
        }

        // Bump generation so any in-flight playback request knows it's been superseded
        beginSession()
        let requestGeneration = sessionGeneration
        pausedStreamNeedsRefresh = false
        // A retry of the same item keeps its pending seek; another item drops it.
        if pendingSeek?.itemID != currentQueueItemID {
            pendingSeek = nil
        }
        playbackPreparationShouldStart = shouldStartPlayback
        // A start from the beginning is a new listen for reporting and scrobbling (D3).
        if (startTime ?? 0) == 0 {
            reportingController.resetForTrack()
        }

        // Keep the app alive during track transitions in background. A newer
        // request takes ownership of an existing task so stale requests cannot end it.
        beginTrackTransitionBackgroundTask(for: requestGeneration)

        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            stop()
            return
        }

        #if os(iOS)
            if #available(iOS 18, *), queue[currentQueueIndex].track.isAppleMusic {
                audioEngine?.stop()
                guard ensureAudioSessionConfigured(mixWithOthers: true) else {
                    playbackState = .failed("Audio output is unavailable. Try playback again.")
                    updateNowPlayingInfo()
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
                await playCurrentAppleMusicSegment(
                    startTime: startTime,
                    generation: requestGeneration
                )
                endTrackTransitionBackgroundTask(for: requestGeneration)
                return
            }
            if #available(iOS 18, *) {
                let wasAppleMusicActive = appleMusicPlaybackController?.activeQueueGeneration != nil
                appleMusicPlaybackController?.stop()
                EnsembleLogger.debug(
                    "[ProviderHandoff] ApplicationMusicPlayer stopped=\(wasAppleMusicActive)"
                        + " running=\(audioEngine?.isRunningForDiagnostics == true)"
                )
                if wasAppleMusicActive,
                   queue.indices.contains(currentQueueIndex) {
                    currentTrack = queue[currentQueueIndex].track
                    updatePlaybackTimes(rawTime: 0)
                    bufferedProgress = 0
                    waveformHeights = []
                    frequencyBands = []
                    playbackState = .loading
                    updateNowPlayingInfo()
                }
                guard ensureAudioSessionConfigured(
                    mixWithOthers: wasAppleMusicActive
                ) else {
                    audioEngine?.stop()
                    playbackState = .failed("Audio output is unavailable. Try playback again.")
                    updateNowPlayingInfo()
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
            } else {
                ensureAudioSessionConfigured()
            }
        #else
            ensureAudioSessionConfigured()
        #endif

        guard await MainActor.run(body: { self.prepareAudioEngineForPlaybackIfNeeded() }) else {
            endTrackTransitionBackgroundTask(for: requestGeneration)
            return
        }

        let queuedTrack = queue[currentQueueIndex].track
        let track = await resolveTrackForPlaybackIfNeeded(queuedTrack)
        guard Self.shouldContinuePlaybackRequest(
            generation: requestGeneration,
            currentGeneration: sessionGeneration,
            queuedTrack: queuedTrack,
            queue: queue,
            currentQueueIndex: currentQueueIndex
        ) else {
            endTrackTransitionBackgroundTask(for: requestGeneration)
            return
        }
        let trackIdentity = track.playbackIdentity
        let request = PlaybackSessionStateMachine.buildRequest(
            generation: requestGeneration,
            track: track,
            forcingFreshItem: forcingFreshItem,
            requestedSeekTime: startTime,
            effectiveTrackDuration: max(track.duration, duration)
        )

        let hasLocalFile = track.localFilePath != nil
        let quality = queue[currentQueueIndex].streamingQuality ?? "original"
        EnsembleLogger.playback("TRACK: '\(track.title)' by \(track.artistName ?? "Unknown") [caller: \(caller), idx: \(currentQueueIndex)/\(queue.count), local: \(hasLocalFile), quality: \(quality)]")
        PlaybackJourneyLogger.start(trackId: trackIdentity, title: track.title, caller: caller)

        // Update the exposed track first so state-transition logs and Now Playing
        // do not briefly point at the previous item during a skip.
        await MainActor.run {
            self.currentTrack = track
            self.updatePlaybackTimes(rawTime: request.recoverySeekTime ?? 0)
            self.bufferedProgress = 0
            self.waveformHeights = []
            audioEngine?.pause()
            audioAnalyzer.pauseUpdates()
            playbackState = .loading
            self.updateNowPlayingInfo()
        }

        // Reset cache for fresh playback attempts
        if forcingFreshItem {
            await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
        }

        // Generate waveform asynchronously
        generateWaveform(for: trackIdentity)

        // Retry loop for network errors
        var lastError: Error?
        let maxRetries = 2

        for attempt in 0 ..< maxRetries {
            do {
                try Task.checkCancellation()
                if attempt > 0 {
                    EnsembleLogger.debug("[playCurrentQueueItem] Retrying resolvePlaybackSource (attempt \(attempt + 1)/\(maxRetries))")
                    try await Task.sleep(nanoseconds: 500_000_000)
                }

                // Check for cached file first; remote sources resolve through transport.
                var source: PlaybackSource
                if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: trackIdentity) }),
                   !request.forcingFreshItem,
                   FileManager.default.fileExists(atPath: cachedURL.path)
                {
                    PlaybackJourneyLogger.mark("sourceDecisionStarted", trackId: trackIdentity, detail: "cachedFile")
                    source = .cachedFile(cachedURL, origin: .streamCache)
                    PlaybackJourneyLogger.mark("sourceDecisionCompleted", trackId: trackIdentity, detail: source.journeyDescription)
                } else {
                    PlaybackJourneyLogger.mark("sourceDecisionStarted", trackId: trackIdentity, detail: "transport")
                    source = try await resolvePlaybackSource(for: request.track, startTime: request.recoverySeekTime ?? 0)
                    PlaybackJourneyLogger.mark("sourceDecisionCompleted", trackId: trackIdentity, detail: source.journeyDescription)
                }

                // Validate cached file isn't truncated (interrupted download or stale cache).
                // A truncated file causes premature track completion and stale gapless state.
                let expectedDuration = request.track.duration
                if let fileURL = source.fileURL,
                   PlaybackLocalFilePolicy.shouldCheckForTruncation(expectedDuration: expectedDuration) {
                    let probeFile = try AVAudioFile(forReading: fileURL)
                    let fileDuration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
                    if PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: fileDuration, expectedDuration: expectedDuration) {
                        EnsembleLogger.debug("[playCurrentQueueItem] Truncated file for '\(request.track.title)': file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedDuration))s — re-downloading")
                        await evictTruncatedFile(fileURL: fileURL, track: request.track, fileDuration: fileDuration, expectedDuration: expectedDuration)
                        source = try await resolvePlaybackSource(for: request.track, startTime: request.recoverySeekTime ?? 0)
                    }
                }

                // Check if this playback request has been superseded
                guard !PlaybackSessionStateMachine.isSuperseded(
                    requestGeneration: request.generation,
                    currentGeneration: sessionGeneration
                ) else {
                    EnsembleLogger.debug("[playCurrentQueueItem] Discarding stale result for \(request.track.title)")
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }

                try Task.checkCancellation()
                try await launchCoordinator.completeLaunch(
                    for: request.track,
                    source: source,
                    recoverySeekTime: request.recoverySeekTime,
                    generation: requestGeneration,
                    shouldStartPlayback: shouldStartPlayback
                )
                return
            } catch {
                guard !Task.isCancelled, !PlaybackSessionStateMachine.isCancellation(error) else {
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
                guard !PlaybackSessionStateMachine.isSuperseded(
                    requestGeneration: request.generation,
                    currentGeneration: sessionGeneration
                ) else {
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
                lastError = error
                PlaybackJourneyLogger.mark("sourceDecisionFailed", trackId: trackIdentity, detail: error.localizedDescription)
                EnsembleLogger.debug("[playCurrentQueueItem] Failed (attempt \(attempt + 1)): \(error)")

                if !PlaybackSessionStateMachine.shouldRetryResolution(after: error, attempt: attempt) {
                    break
                }
                await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
                transportCoordinator.evict(trackId: trackIdentity, includeDecision: true, cancelTask: true)
                do {
                    try await syncCoordinator.refreshConnection()
                } catch {
                    guard !Task.isCancelled, !PlaybackSessionStateMachine.isCancellation(error) else {
                        endTrackTransitionBackgroundTask(for: requestGeneration)
                        return
                    }
                    lastError = error
                    break
                }
                guard requestGeneration == sessionGeneration else {
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
            }
        }

        guard !PlaybackSessionStateMachine.isSuperseded(
            requestGeneration: request.generation,
            currentGeneration: sessionGeneration
        ) else {
            endTrackTransitionBackgroundTask(for: requestGeneration)
            return
        }

        if shouldAutoRecoverLocalOpenFailure(
            lastError,
            track: request.track,
            forcingFreshItem: request.forcingFreshItem
        ) {
            endTrackTransitionBackgroundTask(for: requestGeneration)
            await MainActor.run {
                self.recreatePlayer()
            }
            guard requestGeneration == sessionGeneration else { return }
            await playCurrentQueueItem(
                forcingFreshItem: true,
                seekTo: request.recoverySeekTime,
                shouldStartPlayback: shouldStartPlayback,
                caller: "retryCurrentTrack(local-open-recovery)"
            )
            return
        }

        switch PlaybackSessionStateMachine.classifyTerminalFailure(lastError, track: request.track) {
        case .tls:
            await handleTLSPlaybackFailure(
                generation: requestGeneration,
                shouldStartPlayback: shouldStartPlayback,
                seekTo: request.recoverySeekTime
            )
            return
        case let .connection(sourceCompositeKey):
            // Refresh server health first, so a skip passes over that server's tracks.
            if let sourceCompositeKey {
                await syncCoordinator.triggerServerHealthCheck(sourceKey: sourceCompositeKey)
                guard requestGeneration == sessionGeneration else {
                    endTrackTransitionBackgroundTask(for: requestGeneration)
                    return
                }
            }
            await handleItemFailure(
                lastError?.localizedDescription ?? "Failed to load track",
                generation: requestGeneration
            )
        case let .generic(message):
            await handleItemFailure(message, generation: requestGeneration)
        }
    }

    func shouldAutoRecoverLocalOpenFailure(
        _ error: Error?,
        track: Track,
        forcingFreshItem: Bool
    ) -> Bool {
        guard !forcingFreshItem else { return false }
        guard track.localFilePath != nil else { return false }
        guard let nsError = error as NSError? else { return false }
        return nsError.domain == "com.apple.coreaudio.avfaudio" && nsError.code == 2_003_334_207
    }

    func retryCurrentTrack(forceConnectionRefresh: Bool, reason: String) async {
        guard let track = currentTrack else { return }

        let recoveryTime: TimeInterval?
        switch playbackState {
        case .playing, .buffering:
            recoveryTime = currentTime
        default:
            recoveryTime = nil
        }

        // Before retrying the stream, check if a local download now exists.
        // This handles tracks that finished downloading while queued/stalled.
        if track.localFilePath == nil {
            let resolved = await resolveTrackForPlaybackIfNeeded(track)
            if resolved.localFilePath != nil {
                EnsembleLogger.debug("💾 Download fallback: swapping to local file for '\(track.title)' (\(reason))")
                // Evict stale cached player item so it re-creates from local file
                await MainActor.run { removeCachedPlayerItem(for: track.playbackIdentity) }
                await playCurrentQueueItem(forcingFreshItem: true, seekTo: recoveryTime, caller: "retryCurrentTrack-downloadFallback(\(reason))")
                return
            }
        }

        if forceConnectionRefresh, track.localFilePath == nil {
            do {
                try await syncCoordinator.refreshConnection()
            } catch {
                EnsembleLogger.debug("⚠️ Failed to refresh connection before retry (\(reason)): \(error.localizedDescription)")
            }
        }

        await playCurrentQueueItem(forcingFreshItem: true, seekTo: recoveryTime, caller: "retryCurrentTrack(\(reason))")
    }

    /// Handle playback failure due to TLS errors.
    /// Forces a connection refresh to find a working endpoint, rebuilds queue, and retries.
    @MainActor
    func handleTLSPlaybackFailure(
        generation: UInt64,
        shouldStartPlayback: Bool,
        seekTo startTime: TimeInterval?
    ) async {
        guard generation == sessionGeneration else { return }
        defer { endTrackTransitionBackgroundTask(for: generation) }
        // The failed attempt's session ends here, so a late event from it is stale.
        let generation = beginSession()

        // A local file, or an item whose one refresh already failed, has failed.
        guard let track = currentTrack,
              track.localFilePath == nil,
              tlsRefreshedItemID != currentQueueItemID else {
            await handleItemFailure("Unable to establish secure connection to server", generation: generation)
            return
        }
        tlsRefreshedItemID = currentQueueItemID
        EnsembleLogger.debug("🔒 Handling TLS playback failure - refreshing connection and rebuilding queue")

        do {
            try await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled, generation == sessionGeneration else { return }

        // Force a connection refresh to find a working endpoint
        transportCoordinator.evict(trackId: track.playbackIdentity, includeDecision: true, cancelTask: true)
        do {
            try await syncCoordinator.refreshConnection()
        } catch {
            guard !Task.isCancelled, !PlaybackSessionStateMachine.isCancellation(error),
                  generation == sessionGeneration else { return }
            EnsembleLogger.debug("⚠️ Failed to refresh connection after TLS error: \(error.localizedDescription)")
            await handleItemFailure("TLS connection error - no working server found", generation: generation)
            return
        }
        guard !Task.isCancelled, generation == sessionGeneration else { return }

        // Rebuild upcoming queue items with fresh URLs
        await rebuildUpcomingQueueForNetworkTransition(shouldPrefetch: false)
        guard !Task.isCancelled, generation == sessionGeneration else { return }

        // Retry the current track with fresh connection
        EnsembleLogger.debug("🔄 Retrying current track with refreshed connection")
        await playCurrentQueueItem(
            forcingFreshItem: true,
            seekTo: startTime,
            shouldStartPlayback: shouldStartPlayback,
            caller: "handleTLSPlaybackFailure"
        )
    }

    /// Resolve a playable source for a track. File-backed sources are cached;
    /// remote sources stream incrementally through `AudioPlaybackEngine`.
    func resolvePlaybackSource(for track: Track, startTime: TimeInterval = 0) async throws -> PlaybackSource {
        let source = try await transportCoordinator.resolvePlaybackSource(for: track, startTime: startTime)
        if let fileURL = source.fileURL {
            await MainActor.run { cacheFileURL(fileURL, for: track.playbackIdentity) }
        }
        return source
    }

    func resolveAudioFile(
        for track: Track,
        shouldContinue: @Sendable () async -> Bool = { true }
    ) async throws -> URL {
        let fileURL = try await transportCoordinator.resolveAudioFile(for: track, shouldContinue: shouldContinue)
        guard await shouldContinue(), !Task.isCancelled else {
            // An adopted prefetch may finish after its queue generation changes.
            // Publish only the exact file still owned by current playback.
            await MainActor.run {
                if currentTrack?.playbackIdentity == track.playbackIdentity,
                   audioEngine?.currentPlaybackFileURL == fileURL {
                    cacheFileURL(fileURL, for: track.playbackIdentity)
                }
            }
            throw CancellationError()
        }
        await MainActor.run { cacheFileURL(fileURL, for: track.playbackIdentity) }
        return fileURL
    }

    nonisolated func shouldRetryStreamURLRequest(after error: Error) -> Bool {
        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .networkError, .noServerSelected:
                return true
            default:
                return false
            }
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    nonisolated func mapToPlaybackError(_ error: Error) -> PlaybackError {
        // Progressive stream errors (HTTP status, payload validation)
        if let streamError = error as? ProgressiveStreamError {
            switch streamError {
            case .httpError(503, _):
                return .serverUnavailable(message: "Server storage unavailable")
            case let .httpError(code, _):
                return .serverUnavailable(message: "Server returned HTTP \(code)")
            case .invalidPayload:
                return .corruptLocalFile
            }
        }

        if let plexError = error as? PlexAPIError {
            switch plexError {
            case .noServerSelected:
                return .serverUnavailable(message: nil)
            case .networkError:
                return .networkError(error)
            default:
                return .unknown(error)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return .networkError(error)
        }

        return .unknown(error)
    }

    public func currentPlaybackFileInfo() -> PlaybackFileInfo? {
        guard let currentTrack,
              let engine = audioEngine,
              engine.currentTrackId == currentTrack.playbackIdentity,
              let fileURL = engine.currentPlaybackFileURL else { return nil }
        let trackId = currentTrack.playbackIdentity
        let codec: String? = {
            switch fileURL.pathExtension.lowercased() {
            case "mp3": return "mp3"
            case "m4a", "aac": return "aac"
            case "flac": return "flac"
            case "wav": return "pcm"
            case "alac": return "alac"
            case "": return nil
            default: return fileURL.pathExtension.lowercased()
            }
        }()
        let standardizedURL = fileURL.standardizedFileURL
        let isDownloaded = standardizedURL.deletingLastPathComponent()
            == DownloadManager.downloadsDirectory.standardizedFileURL
        let fileSize = engine.currentPlaybackFileIsComplete
            ? (try? standardizedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            : nil
        let quality = isDownloaded
            ? currentTrack.downloadedQuality ?? AudioQualityPreference.fileQuality(at: standardizedURL)
            : queue.indices.contains(currentQueueIndex) && queue[currentQueueIndex].track.playbackIdentity == trackId
                ? queue[currentQueueIndex].streamingQuality ?? AudioQualityPreference.storedStreamingQuality()
                : AudioQualityPreference.storedStreamingQuality()

        return PlaybackFileInfo(
            codec: codec,
            fileSize: fileSize,
            isDownloaded: isDownloaded,
            quality: quality,
            sampleRate: engine.currentPlaybackSampleRate.map { Int($0.rounded()) }
        )
    }

    /// Evict a truncated audio file — clears stream cache and, if the file came from an
    /// offline download, marks the CDDownload as failed and deletes the file on disk.
    /// After calling this, `resolveAudioFile` will fall through to streaming.
    func evictTruncatedFile(fileURL: URL, track: Track, fileDuration: Double, expectedDuration: Double) async {
        // Always clear in-memory caches so resolveAudioFile doesn't return the same file
        let trackIdentity = track.playbackIdentity
        await MainActor.run { removeCachedPlayerItem(for: trackIdentity) }
        transportCoordinator.evict(trackId: trackIdentity, includeDecision: true, cancelTask: true)

        // Check if this is an offline download (vs a stream cache file)
        if track.localFilePath != nil {
            // Delete the truncated file so DownloadManager self-healing won't recover it
            try? FileManager.default.removeItem(at: fileURL)

            // Mark the CDDownload as failed so the Downloads view shows it correctly
            do {
                guard let sourceCompositeKey = track.sourceCompositeKey,
                      MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return }
                if let download = try await downloadManager.fetchDownload(
                    forTrackRatingKey: track.id,
                    sourceCompositeKey: sourceCompositeKey
                ) {
                    try await downloadManager.failDownload(
                        download.objectID,
                        error: PlaybackLocalFilePolicy.truncatedDownloadError(fileDuration: fileDuration, expectedDuration: expectedDuration)
                    )
                    EnsembleLogger.debug("[evictTruncatedFile] Marked offline download as failed for '\(track.title)'")
                }
            } catch {
                EnsembleLogger.debug("[evictTruncatedFile] Failed to mark download as failed for '\(track.title)': \(error.localizedDescription)")
            }
        }
    }

    func prefetchNextItem() async {
        scheduleUpcomingArtworkPrefetch()
        await prefetchUpcomingItems(depth: 2)
    }

    func scheduleUpcomingArtworkPrefetch() {
        Task { @MainActor [weak self] in
            guard let self,
                  let index = self.upcomingQueueIndices(depth: 1).first else { return }
            let track = self.queue[index].track
            let artworkLoader = self.artworkLoader

            self.artworkPrefetchTask?.cancel()
            self.artworkPrefetchTask = Task(priority: .utility) {
                let request = ArtworkRequest(
                    track: track,
                    tier: .hero,
                    priority: .low
                )
                guard case .resolved(let resolved) = await artworkLoader.resolve(request),
                      !Task.isCancelled else { return }
                _ = await artworkLoader.blurredImage(
                    for: resolved.image,
                    cacheKey: resolved.blurCacheKey,
                    requiresIdle: true
                )
            }
        }
    }

    func scheduleGaplessIfNeeded() {
        if isSmartMixEnabled, audioEngine?.isSmartMixTransitionActive == true {
            return
        }
        guard audioEngine?.scheduledTrackIds.isEmpty ?? true else { return }
        guard gaplessScheduleRequestTask == nil else { return }
        guard PlaybackPrefetchController.shouldScheduleGaplessNow(
            currentTime: currentTime,
            duration: duration,
            playbackState: playbackState
        ) else { return }

        gaplessScheduleRequestTask = Task { @MainActor [weak self] in
            await self?.prefetchNextItem()
            self?.gaplessScheduleRequestTask = nil
        }
    }

    func upcomingQueueIndices(depth: Int) -> [Int] {
        prefetchController.upcomingQueueIndices(
            queueCount: queue.count,
            currentQueueIndex: currentQueueIndex,
            repeatMode: repeatMode,
            depth: depth
        )
    }

    @MainActor
    func isPrefetchedTrackStillUpcoming(_ trackID: String, depth: Int) -> Bool {
        let currentTrackID = queue.indices.contains(currentQueueIndex)
            ? queue[currentQueueIndex].track.playbackIdentity
            : currentTrack?.playbackIdentity
        let nextUpcomingTrackID = upcomingQueueIndices(depth: depth).first.map {
            queue[$0].track.playbackIdentity
        }
        return PlaybackPrefetchController.shouldSchedulePrefetchedTrack(
            prefetchedTrackID: trackID,
            currentTrackID: currentTrackID,
            nextUpcomingTrackID: nextUpcomingTrackID
        )
    }

    @MainActor
    func schedulePrefetchedTrackIfStillUpcoming(
        _ trackID: String,
        depth: Int,
        engine: AudioPlaybackEngine,
        schedule: () throws -> Void
    ) rethrows -> Bool {
        guard isPrefetchedTrackStillUpcoming(trackID, depth: depth),
              !engine.isSmartMixTransitionActive,
              !engine.isTrackScheduled(trackID) else { return false }
        try schedule()
        return true
    }

    func prefetchUpcomingItems(depth: Int) async {
        while networkWorkDeferred {
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        guard let engine = audioEngine else { return }

        // Don't prefetch when playback has failed
        if case .failed = playbackState { return }
        let prefetchSnapshot: (track: Track?, shouldClearSchedule: Bool, shouldDefer: Bool) = await MainActor.run { [weak self] in
            guard let self else { return (track: nil, shouldClearSchedule: false, shouldDefer: false) }
            let removedDuplicates = !self.removeDuplicateFutureAutoplayItemsIfNeeded(
                shouldInvalidateGaplessSchedule: false
            ).isEmpty
            let shouldInvalidateScheduledTracks = removedDuplicates && self.prefetchController.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: engine.scheduledTrackIdsInOrder,
                queue: self.queue,
                currentQueueIndex: self.currentQueueIndex,
                repeatMode: self.repeatMode
            )
            let targetIndices = self.upcomingQueueIndices(depth: depth)
            guard let firstIndex = targetIndices.first else {
                self.transportCoordinator.discardPreparedStreams(
                    except: Set([self.currentTrack?.playbackIdentity].compactMap { $0 })
                )
                return (track: nil, shouldClearSchedule: shouldInvalidateScheduledTracks, shouldDefer: false)
            }
            let track = self.queue[firstIndex].track
            self.transportCoordinator.discardPreparedStreams(
                except: Set([track.playbackIdentity, self.currentTrack?.playbackIdentity].compactMap { $0 })
            )
            let shouldDefer = self.currentTrack.map {
                self.prefetchController.shouldDeferFailedPrefetch(
                    outgoingTrackID: $0.playbackIdentity,
                    incomingTrackID: track.playbackIdentity
                ) || self.prefetchController.shouldDeferSmartMixPrefetch(
                    outgoingTrackID: $0.playbackIdentity,
                    incomingTrackID: track.playbackIdentity,
                    currentTime: self.currentTime
                )
            } ?? false
            return (
                track: Optional(track),
                shouldClearSchedule: shouldInvalidateScheduledTracks,
                shouldDefer: shouldDefer
            )
        }

        if prefetchSnapshot.shouldClearSchedule {
            engine.clearScheduledFiles()
        }

        guard !prefetchSnapshot.shouldDefer else { return }

        guard let track = prefetchSnapshot.track else { return }
        guard !track.isAppleMusic else {
            if !engine.scheduledTrackIdsInOrder.isEmpty {
                engine.clearScheduledFiles()
            }
            return
        }
        let trackIdentity = track.playbackIdentity

        let prefetchGeneration = await MainActor.run { sessionGeneration }
        let shouldContinue: @Sendable () async -> Bool = { [weak self] in
            await MainActor.run {
                guard let self else { return false }
                return self.sessionGeneration == prefetchGeneration
                    && self.isPrefetchedTrackStillUpcoming(trackIdentity, depth: depth)
            }
        }

        // Don't schedule if already in the engine's gapless queue
        guard !engine.isTrackScheduled(trackIdentity) else { return }

        // Guard against TOCTOU race: two concurrent calls can both pass
        // isTrackScheduled before either reaches scheduleNext(). The in-flight
        // set closes this window so only the first caller proceeds.
        guard await MainActor.run(body: { resolvedFileCache.beginPrefetch(for: trackIdentity) }) else {
            EnsembleLogger.debug("[prefetch] Already in-flight for '\(track.title)' — skipping duplicate")
            return
        }
        defer {
            Task { @MainActor [resolvedFileCache] in
                resolvedFileCache.endPrefetch(for: trackIdentity)
            }
        }

        EnsembleLogger.debug("[prefetch] Upcoming '\(track.title)' source=\(track.sourceCompositeKey ?? "nil")")

        do {
            // Check cache first
            var fileURL: URL
            if let cachedURL = await MainActor.run(body: { getCachedFileURL(for: trackIdentity) }),
               FileManager.default.fileExists(atPath: cachedURL.path)
            {
                fileURL = cachedURL
            } else {
                fileURL = try await resolveAudioFile(for: track, shouldContinue: shouldContinue)
            }

            // Validate file duration against metadata to catch truncated cached files.
            // An interrupted download or aggressive cache cleanup can leave a partial file
            // on disk. Scheduling it for gapless causes a premature track advance.
            let expectedDuration = track.duration
            if PlaybackLocalFilePolicy.shouldCheckForTruncation(expectedDuration: expectedDuration) {
                let probeFile = try AVAudioFile(forReading: fileURL)
                let fileDuration = Double(probeFile.length) / probeFile.processingFormat.sampleRate
                if PlaybackLocalFilePolicy.shouldTreatAsTruncated(fileDuration: fileDuration, expectedDuration: expectedDuration) {
                    EnsembleLogger.debug("[prefetch] Truncated file for '\(track.title)': file=\(String(format: "%.1f", fileDuration))s expected=\(String(format: "%.1f", expectedDuration))s — evicting and re-downloading")
                    await evictTruncatedFile(fileURL: fileURL, track: track, fileDuration: fileDuration, expectedDuration: expectedDuration)
                    fileURL = try await resolveAudioFile(for: track, shouldContinue: shouldContinue)
                }
            }

            guard !Task.isCancelled, await shouldContinue() else {
                EnsembleLogger.debug("[prefetch] '\(track.title)' no longer matches the upcoming queue")
                return
            }

            await MainActor.run { prefetchController.clearPrefetchFailure(for: trackIdentity) }

            // Final guard: another caller may have scheduled while we were resolving
            guard !engine.isTrackScheduled(trackIdentity) else {
                EnsembleLogger.debug("[prefetch] '\(track.title)' was scheduled by another path — skipping")
                return
            }

            let smartMixContext = await MainActor.run { [weak self] in
                guard let self else {
                    return (
                        enabled: false,
                        currentTrack: Track?.none,
                        currentFileURL: URL?.none,
                        currentDuration: TimeInterval(0),
                        currentTime: TimeInterval(0),
                        incomingDuration: TimeInterval(0),
                        isDisabledForAlbums: false
                    )
                }

                let currentTrack = self.currentTrack
                let currentId = currentTrack?.playbackIdentity
                let currentURL = currentId.flatMap { self.getCachedFileURL(for: $0) }
                return (
                    enabled: self.isSmartMixEnabled,
                    currentTrack: currentTrack,
                    currentFileURL: currentURL,
                    currentDuration: self.duration,
                    currentTime: self.currentTime,
                    incomingDuration: track.duration,
                    isDisabledForAlbums: self.isSmartMixDisabledForAlbums
                )
            }

            if smartMixContext.enabled,
               let currentTrack = smartMixContext.currentTrack,
               let currentFileURL = smartMixContext.currentFileURL,
               PlaybackPrefetchController.shouldUseSmartMix(
                   outgoingTrack: currentTrack,
                   incomingTrack: track,
                   isDisabledForAlbums: smartMixContext.isDisabledForAlbums
               ),
               !engine.isSmartMixTransitionActive
            {
                let outgoingAnalysis = await smartMixAnalysisService.analysis(
                    for: currentTrack.playbackIdentity,
                    fileURL: currentFileURL
                )
                let incomingAnalysis = await smartMixAnalysisService.analysis(
                    for: trackIdentity,
                    fileURL: fileURL
                )
                guard await isPrefetchedTrackStillUpcoming(trackIdentity, depth: depth),
                      !engine.isTrackScheduled(trackIdentity) else {
                    EnsembleLogger.debug("[prefetch] '\(track.title)' changed while SmartMix analysis was running")
                    return
                }
                let tempoGate = Self.smartMixTempoMatchingGate()
                if let plan = SmartMixPlanner.plan(
                    outgoingDuration: smartMixContext.currentDuration,
                    incomingDuration: smartMixContext.incomingDuration,
                    outgoingAnalysis: outgoingAnalysis,
                    incomingAnalysis: incomingAnalysis,
                    tempoMatchingAllowed: tempoGate.allowed
                ) {
                    let tempoFallbackReason = Self.smartMixTempoFallbackReason(
                        plan: plan,
                        outgoingAnalysis: outgoingAnalysis,
                        incomingAnalysis: incomingAnalysis,
                        tempoGateReason: tempoGate.reason
                    )
                    EnsembleLogger.debug(
                        "[SmartMix] Tempo decision matched=\(plan.tempoMatched)"
                        + " outgoingBPM=\(String(format: "%.1f", outgoingAnalysis.outroTempo.estimatedBPM ?? 0))"
                        + " outgoingConfidence=\(String(format: "%.2f", outgoingAnalysis.outroTempo.confidence))"
                        + " incomingBPM=\(String(format: "%.1f", incomingAnalysis.introTempo.estimatedBPM ?? 0))"
                        + " incomingConfidence=\(String(format: "%.2f", incomingAnalysis.introTempo.confidence))"
                        + " rate=\(String(format: "%.3f", plan.incomingPlaybackRate))"
                        + " beatOffset=\(String(format: "%.3f", plan.incomingBeatOffset))"
                        + " fallback=\(tempoFallbackReason ?? "none")"
                    )
                    guard SmartMixPlanner.shouldStartTransition(
                        currentTime: smartMixContext.currentTime,
                        plan: plan
                    ) else {
                        await MainActor.run { [prefetchController] in
                            prefetchController.deferSmartMixPrefetch(
                                outgoingTrackID: currentTrack.playbackIdentity,
                                incomingTrackID: trackIdentity,
                                until: plan.outgoingStartTime - SmartMixPlanner.transitionStartTolerance
                            )
                        }
                        EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later SmartMix scheduling")
                        return
                    }
                    guard try await schedulePrefetchedTrackIfStillUpcoming(
                        trackIdentity,
                        depth: depth,
                        engine: engine,
                        schedule: {
                            try engine.scheduleSmartMixNext(fileURL: fileURL, trackId: trackIdentity, plan: plan)
                        }
                    ) else {
                        EnsembleLogger.debug("[prefetch] '\(track.title)' changed before SmartMix scheduling")
                        return
                    }
                } else if PlaybackPrefetchController.shouldScheduleGaplessNow(
                    currentTime: smartMixContext.currentTime,
                    duration: smartMixContext.currentDuration,
                    playbackState: playbackState
                ) {
                    guard try await schedulePrefetchedTrackIfStillUpcoming(
                        trackIdentity,
                        depth: depth,
                        engine: engine,
                        schedule: {
                            try engine.scheduleNext(fileURL: fileURL, trackId: trackIdentity)
                        }
                    ) else {
                        EnsembleLogger.debug("[prefetch] '\(track.title)' changed before gapless scheduling")
                        return
                    }
                } else {
                    EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later SmartMix scheduling")
                    return
                }
            } else {
                if smartMixContext.enabled,
                   let currentTrack = smartMixContext.currentTrack,
                   !PlaybackPrefetchController.shouldUseSmartMix(
                       outgoingTrack: currentTrack,
                       incomingTrack: track,
                       isDisabledForAlbums: smartMixContext.isDisabledForAlbums
                   )
                {
                    EnsembleLogger.debug("[SmartMix] Skipping same-album transition")
                }
                let shouldScheduleNow = await MainActor.run { [weak self] in
                    guard let self else { return false }
                    return PlaybackPrefetchController.shouldScheduleGaplessNow(
                        currentTime: self.currentTime,
                        duration: self.duration,
                        playbackState: self.playbackState
                    )
                }
                guard shouldScheduleNow else {
                    EnsembleLogger.debug("[prefetch] Cached '\(track.title)' for later gapless scheduling")
                    return
                }
                guard try await schedulePrefetchedTrackIfStillUpcoming(
                    trackIdentity,
                    depth: depth,
                    engine: engine,
                    schedule: {
                        try engine.scheduleNext(fileURL: fileURL, trackId: trackIdentity)
                    }
                ) else {
                    EnsembleLogger.debug("[prefetch] '\(track.title)' changed before gapless scheduling")
                    return
                }
            }

            if let plan = await MainActor.run(body: { [weak self] in
                self?.visualizerPlan(for: .scheduledPrefetch)
            }) {
                self.enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
        } catch {
            guard !Task.isCancelled, await shouldContinue(),
                  !PlaybackSessionStateMachine.isCancellation(error) else { return }
            EnsembleLogger.debug("[prefetch] Failed for '\(track.title)': \(error)")
            // Clean up all cached state for the failed track so the next real
            // playback attempt gets a fresh resolution instead of hitting the
            // stale failed loader (fixes cross-server prefetch cascade failures)
            await MainActor.run {
                guard sessionGeneration == prefetchGeneration,
                      isPrefetchedTrackStillUpcoming(trackIdentity, depth: depth) else { return }
                removeCachedPlayerItem(for: trackIdentity)
                if let currentTrack {
                    prefetchController.recordPrefetchFailure(
                        outgoingTrackID: currentTrack.playbackIdentity,
                        incomingTrackID: trackIdentity,
                        error: error
                    )
                }
                transportCoordinator.evict(trackId: trackIdentity, includeDecision: true, cancelTask: true)
            }
        }
    }

    @MainActor
    func loadAndPlaySource(
        _ source: PlaybackSource,
        track: Track,
        generation: UInt64,
        shouldStartPlayback: Bool
    ) async throws -> Bool {
        guard let engine = audioEngine else {
            EnsembleLogger.playback("ENGINE: loadAndPlaySource called with no engine")
            playbackState = .failed("Audio engine not initialized")
            endTrackTransitionBackgroundTask(for: generation)
            return false
        }
        guard generation == sessionGeneration else {
            endTrackTransitionBackgroundTask(for: generation)
            return false
        }
        EnsembleLogger.debug(
            "[ProviderHandoff] phase=nativeLoad generation=\(generation)"
                + " track=\(track.playbackIdentity)"
                + " running=\(engine.isRunningForDiagnostics)"
                + " route=\(currentAudioRouteDescription())"
        )
        let trackIdentity = track.playbackIdentity

        #if !os(macOS)
            let activated = await audioSessionCoordinator.activateForPlayback(
                shouldStartPlayback: shouldStartPlayback
            )
            guard generation == sessionGeneration else {
                endTrackTransitionBackgroundTask(for: generation)
                return false
            }
            guard activated else {
                engine.stop()
                playbackState = .failed("Audio output is unavailable. Try playback again.")
                endTrackTransitionBackgroundTask(for: generation)
                return false
            }
            #if os(iOS)
                if #available(iOS 18, *),
                   !ensureAudioSessionConfigured(mixWithOthers: false) {
                    await Task.yield()
                    guard generation == sessionGeneration else {
                        endTrackTransitionBackgroundTask(for: generation)
                        return false
                    }
                    guard ensureAudioSessionConfigured(mixWithOthers: false) else {
                        EnsembleLogger.error(
                            "[ProviderHandoff] Could not restore nonmixable audio session"
                        )
                        engine.stop()
                        playbackState = .failed("Audio output is unavailable. Try playback again.")
                        updateNowPlayingInfo()
                        endTrackTransitionBackgroundTask(for: generation)
                        return false
                    }
                }
            #endif
        #endif

        if let fileURL = source.fileURL {
            cacheFileURL(fileURL, for: trackIdentity)
        }

        // Clear any scheduled gapless files from the previous track
        engine.clearScheduledFiles()

        if source.fileURL != nil {
            audioAnalyzer.activateTimeline(for: trackIdentity)
        }

        bufferedProgress = source.initialBufferedProgress

        // CRITICAL: If the audio session is currently interrupted or a route change
        // is in progress, do NOT attempt to play yet.
        if shouldStartPlayback && handoffCoordinator.shouldSuppressAutomaticAdvance {
            EnsembleLogger.debug("[loadAndPlaySource] deferred: \(handoffStateSnapshot())")
            do {
                PlaybackJourneyLogger.mark("engineLoadStarted", trackId: trackIdentity, detail: source.journeyDescription)
                #if DEBUG
                    try await PlaybackAutomationFailure.check(stage: "startup", trackID: trackIdentity)
                #endif
                try Task.checkCancellation()
                guard generation == sessionGeneration else {
                    endTrackTransitionBackgroundTask(for: generation)
                    return false
                }
                                nativeEngineAdapter?.willLoad(trackID: trackIdentity)
                try await engine.load(
                    source: source,
                    trackId: trackIdentity,
                    playbackGeneration: generation,
                    preparedPipeline: transportCoordinator.takePreparedPipeline(for: source, trackID: trackIdentity)
                )
                guard generation == sessionGeneration else {
                    if engine.playbackRequestGeneration == generation { engine.stop() }
                    endTrackTransitionBackgroundTask(for: generation)
                    return false
                }
                PlaybackJourneyLogger.mark("engineLoadCompleted", trackId: trackIdentity, detail: source.journeyDescription)
            } catch {
                guard generation == sessionGeneration else {
                    if engine.playbackRequestGeneration == generation { engine.stop() }
                    endTrackTransitionBackgroundTask(for: generation)
                    return false
                }
                EnsembleLogger.playback("ENGINE: load failed -- \(error.localizedDescription)")
                PlaybackJourneyLogger.mark("engineLoadFailed", trackId: trackIdentity, detail: error.localizedDescription)
                removeCachedPlayerItem(for: trackIdentity)
                engine.stop()
                throw error
            }
            // An interruption or a lost route lets the load finish and then pauses
            // (G14); a settling new route stays buffering until its window ends.
            switch handoffCoordinator.state.pauseReason {
            case .interruption, .disconnect:
                playbackState = .paused
                updateNowPlayingInfo()
            case .user, .system, nil:
                playbackState = .buffering
            }
            return true
        }

        do {
            PlaybackJourneyLogger.mark("engineLoadStarted", trackId: trackIdentity, detail: source.journeyDescription)
            #if DEBUG
                try await PlaybackAutomationFailure.check(stage: "startup", trackID: trackIdentity)
            #endif
            try Task.checkCancellation()
            guard generation == sessionGeneration else {
                endTrackTransitionBackgroundTask(for: generation)
                return false
            }
                        nativeEngineAdapter?.willLoad(trackID: trackIdentity)
            try await engine.load(
                source: source,
                trackId: trackIdentity,
                playbackGeneration: generation,
                preparedPipeline: transportCoordinator.takePreparedPipeline(for: source, trackID: trackIdentity)
            )
            guard generation == sessionGeneration else {
                if engine.playbackRequestGeneration == generation { engine.stop() }
                endTrackTransitionBackgroundTask(for: generation)
                return false
            }
            PlaybackJourneyLogger.mark("engineLoadCompleted", trackId: trackIdentity, detail: source.journeyDescription)
            // A seek reload prepares the replacement source without briefly rendering
            // audio when the user had paused it. Explicit resume uses the loaded engine.
            if !shouldStartPlayback {
                updatePlaybackTimes(rawTime: engine.currentTime())
                playbackState = .paused
                applyPendingSeek()
                updateNowPlayingInfo()
                savePlaybackState()
                endTrackTransitionBackgroundTask(for: generation)
                return true
            }
            try engine.play()
            refreshPresentationLatencyEstimate()
            trackStartWallTime = CACurrentMediaTime()
            let isStreamingSource = source.fileURL == nil
            playbackState = isStreamingSource ? .buffering : .playing
            updateNowPlayingInfo()
            if !isStreamingSource {
                audioAnalyzer.resumeUpdates()

                // Release background task protection
                endTrackTransitionBackgroundTask(for: generation)

            }

            EnsembleLogger.playback("ENGINE: playing '\(track.title)'")
            return true
        } catch {
            guard generation == sessionGeneration else {
                if engine.playbackRequestGeneration == generation { engine.stop() }
                endTrackTransitionBackgroundTask(for: generation)
                return false
            }
            // Clear stale cached URL so retry/recovery gets a fresh download
            // instead of repeatedly hitting the same deleted or corrupt file
            removeCachedPlayerItem(for: trackIdentity)

            PlaybackJourneyLogger.mark("engineLoadFailed", trackId: trackIdentity, detail: error.localizedDescription)
            EnsembleLogger.playback("ENGINE: load/play failed -- \(error.localizedDescription)")
            engine.stop()
            throw error
        }
    }

    /// Pre-buffer the restored track: create player item, insert paused, seek to saved position.
    /// Called either immediately (local files) or after health check confirms server reachable.
    @MainActor
    func preBufferRestoredTrack() async {
        ensureAudioSessionConfigured()
        guard let savedTime = pendingPreBufferTime,
              playbackState == .paused,
              audioEngine?.currentTrackId == nil,
              let track = currentTrack
        else {
            pendingPreBufferTime = nil
            return
        }

        pendingPreBufferTime = nil
        let generation = sessionGeneration

        guard prepareAudioEngineForPlaybackIfNeeded() else {
            return
        }

        EnsembleLogger.debug("[preBuffer] Pre-buffering restored track: \(track.title)")

        do {
            let fileURL = try await resolveAudioFile(for: track)

            guard playbackState == .paused,
                  generation == sessionGeneration,
                  currentTrack?.playbackIdentity == track.playbackIdentity else { return }

            // Load into engine without playing
            nativeEngineAdapter?.willLoad(trackID: track.playbackIdentity)
            try audioEngine?.load(
                fileURL: fileURL,
                trackId: track.playbackIdentity,
                playbackGeneration: generation
            )
            let restoredTime = Self.restoredPausedSeekTime(
                savedTime: savedTime,
                duration: Self.effectiveDuration(
                    metadataDuration: track.duration,
                    itemDuration: audioEngine?.fileDuration
                )
            )

            // Seek to saved position
            if restoredTime > 0 {
                try audioEngine?.seek(to: restoredTime)
                updatePlaybackTimes(rawTime: restoredTime)
            }

            if let plan = visualizerPlan(for: .restoredPrebuffer) {
                enqueueVisualizerTimelineLoad(track: track, fileURL: fileURL, plan: plan)
            }
            audioAnalyzer.activateTimeline(for: track.playbackIdentity)

            EnsembleLogger.debug("[preBuffer] Complete for \(track.title)")
        } catch {
            EnsembleLogger.debug("[preBuffer] Failed (will retry on play): \(error)")
        }
    }
}
