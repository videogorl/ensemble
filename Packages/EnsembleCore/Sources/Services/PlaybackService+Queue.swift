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

// What plays next, queue navigation and edits, shuffle and repeat, and autoplay.
extension PlaybackService {
    struct QueueSourcePruneResult: Equatable {
        let queue: [QueueItem]
        let originalQueue: [QueueItem]
        let playbackHistory: [QueueItem]
        let nextCurrentQueueIndex: Int
        let removedCurrentQueueItem: Bool
        let removedQueueItemCount: Int
    }

    nonisolated static func isTrackSourceAvailable(
        _ track: Track,
        configuration: SourceConfigurationSnapshot
    ) -> Bool {
        configuration.shouldPreserveSourceKey(track.sourceCompositeKey)
    }

    nonisolated static func isQueueTrackPlayable(
        _ track: Track,
        serverPossiblyAvailable: Bool,
        plexStreamingAllowed: Bool = true
    ) -> Bool {
        track.isAppleMusic || track.isDownloaded || (plexStreamingAllowed && serverPossiblyAvailable)
    }

    public func setTrackPlayability(_ isPlayable: @escaping (Track) -> Bool) {
        trackPlayability = isPlayable
    }

    func isTrackPlayableNow(_ track: Track, plexStreamingAllowed: Bool) -> Bool {
        if let trackPlayability { return trackPlayability(track) }
        return Self.isQueueTrackPlayable(
            track,
            serverPossiblyAvailable: syncCoordinator.isServerPossiblyAvailable(sourceKey: track.sourceCompositeKey),
            plexStreamingAllowed: plexStreamingAllowed
        )
    }

    nonisolated static func futureQueueIndex(
        matching playbackIdentity: String,
        in queue: [QueueItem],
        after currentQueueIndex: Int
    ) -> Int? {
        queue.indices.first {
            $0 > currentQueueIndex && queue[$0].track.playbackIdentity == playbackIdentity
        }
    }

    nonisolated static func queueIndexForAdvance(
        matching playbackIdentity: String,
        in queue: [QueueItem],
        after currentQueueIndex: Int,
        repeatCurrent: Bool = false
    ) -> Int? {
        if repeatCurrent, queue.indices.contains(currentQueueIndex),
           queue[currentQueueIndex].track.playbackIdentity == playbackIdentity {
            return currentQueueIndex
        }
        return futureQueueIndex(
            matching: playbackIdentity,
            in: queue,
            after: currentQueueIndex
        ) ?? queue.firstIndex { $0.track.playbackIdentity == playbackIdentity }
    }

    nonisolated static func smartMixPromotionQueueIndex(
        matching playbackIdentity: String,
        currentTrackIdentity: String?,
        in queue: [QueueItem],
        after currentQueueIndex: Int
    ) -> Int? {
        guard currentTrackIdentity != playbackIdentity else { return nil }
        return queueIndexForAdvance(
            matching: playbackIdentity,
            in: queue,
            after: currentQueueIndex
        )
    }

    nonisolated static func pruneQueueForSourceConfiguration(
        queue: [QueueItem],
        originalQueue: [QueueItem],
        playbackHistory: [QueueItem],
        currentQueueIndex: Int,
        configuration: SourceConfigurationSnapshot
    ) -> QueueSourcePruneResult {
        let filteredQueue = queue.filter {
            isTrackSourceAvailable($0.track, configuration: configuration)
        }
        let filteredOriginalQueue = originalQueue.filter {
            isTrackSourceAvailable($0.track, configuration: configuration)
        }
        let filteredHistory = playbackHistory.filter {
            isTrackSourceAvailable($0.track, configuration: configuration)
        }

        let removedQueueItemCount = max(0, queue.count - filteredQueue.count)
        let currentItemID: String?
        if queue.indices.contains(currentQueueIndex) {
            currentItemID = queue[currentQueueIndex].id
        } else {
            currentItemID = nil
        }

        guard !filteredQueue.isEmpty else {
            return QueueSourcePruneResult(
                queue: filteredQueue,
                originalQueue: filteredOriginalQueue,
                playbackHistory: filteredHistory,
                nextCurrentQueueIndex: -1,
                removedCurrentQueueItem: currentItemID != nil,
                removedQueueItemCount: removedQueueItemCount
            )
        }

        if let currentItemID,
           let preservedIndex = filteredQueue.firstIndex(where: { $0.id == currentItemID })
        {
            return QueueSourcePruneResult(
                queue: filteredQueue,
                originalQueue: filteredOriginalQueue,
                playbackHistory: filteredHistory,
                nextCurrentQueueIndex: preservedIndex,
                removedCurrentQueueItem: false,
                removedQueueItemCount: removedQueueItemCount
            )
        }

        let fallbackItemID = preferredFallbackQueueItemID(
            afterRemovingCurrentAt: currentQueueIndex,
            from: queue,
            configuration: configuration
        )
        let fallbackIndex: Int
        if let fallbackItemID,
           let index = filteredQueue.firstIndex(where: { $0.id == fallbackItemID })
        {
            fallbackIndex = index
        } else {
            fallbackIndex = min(max(currentQueueIndex, 0), filteredQueue.count - 1)
        }

        return QueueSourcePruneResult(
            queue: filteredQueue,
            originalQueue: filteredOriginalQueue,
            playbackHistory: filteredHistory,
            nextCurrentQueueIndex: fallbackIndex,
            removedCurrentQueueItem: true,
            removedQueueItemCount: removedQueueItemCount
        )
    }

    nonisolated static func preferredFallbackQueueItemID(
        afterRemovingCurrentAt currentQueueIndex: Int,
        from queue: [QueueItem],
        configuration: SourceConfigurationSnapshot
    ) -> String? {
        guard !queue.isEmpty else { return nil }

        if queue.indices.contains(currentQueueIndex) {
            let nextStart = currentQueueIndex + 1
            if nextStart < queue.count {
                for item in queue[nextStart...] where
                    isTrackSourceAvailable(
                        item.track,
                        configuration: configuration
                    )
                {
                    return item.id
                }
            }

            if currentQueueIndex > 0 {
                for item in queue[..<currentQueueIndex] where
                    isTrackSourceAvailable(
                        item.track,
                        configuration: configuration
                    )
                {
                    return item.id
                }
            }
        }

        return queue.first(where: {
            isTrackSourceAvailable(
                $0.track,
                configuration: configuration
            )
        })?.id
    }

    /// Index of the last non-autoplay item in the queue (for autoplay seed selection)
    var lastRealTrackIndex: Int? {
        for i in stride(from: queue.count - 1, through: 0, by: -1) {
            if queue[i].source != .autoplay {
                return i
            }
        }
        return nil
    }

    /// Records the currently playing item to history before advancing
    func recordToHistory(_ item: QueueItem) {
        queueController.recordToHistory(item, playbackHistory: &playbackHistory)
    }

    /// What follows the current item, decided by the one shared queue rule.
    @MainActor
    func queueAdvance(
        _ trigger: EnsembleQueueAdvanceTrigger,
        after index: Int? = nil
    ) -> EnsembleQueueAdvance {
        let plexStreamingAllowed = isPlexStreamingAllowedOnCurrentNetwork()
        return EnsembleQueuePolicy.advance(
            after: index ?? currentQueueIndex,
            count: queue.count,
            trigger: trigger,
            repeatMode: repeatMode.queueRepeat,
            isAutoplayEnabled: isAutoplayEnabled
        ) { index in
            let track = queue[index].track
            return isTrackPlayableNow(track, plexStreamingAllowed: plexStreamingAllowed)
        }
    }

    /// Carries out a queue advance while playing. Every playing advance path
    /// (natural end, Next, SmartMix Next, Apple Music boundary) ends here.
    @MainActor
    func performQueueAdvance(_ advance: EnsembleQueueAdvance, caller: String) async {
        switch advance {
        case .repeatCurrent:
            await playCurrentQueueItem(caller: "\(caller)-repeatOne")
            savePlaybackState()
        case let .item(index, wrapped):
            guard !Task.isCancelled, queue.indices.contains(index) else { return }
            currentQueueIndex = index
            currentTrack = queue[index].track
            updatePlaybackTimes(rawTime: 0)
            updateNowPlayingInfo()
            await playCurrentQueueItem(caller: wrapped ? "\(caller)-wrap" : caller)
            guard !Task.isCancelled else { return }
            savePlaybackState()
            await checkAndRefreshAutoplayQueue()
        case .continuation:
            guard !(await continueWithAutoplay(caller: "\(caller)-autoplay")),
                  !Task.isCancelled else { return }
            settleAtEndOfQueue(caller: caller)
        case .unavailable:
            if !reportUnavailableNextTrackIfNeeded(after: currentQueueIndex) {
                settleAtEndOfQueue(caller: caller)
            }
        case .endOfQueue:
            settleAtEndOfQueue(caller: caller)
        }
    }

    /// Plays the next autoplay item, or hands an Apple Music seed to a station.
    /// Returns false when autoplay has nothing to play.
    @MainActor
    func continueWithAutoplay(caller: String) async -> Bool {
        if let seed = currentTrack,
           await startAppleMusicAutoplayStationIfPossible(seed: seed) {
            return true
        }
        let previousCount = queue.count
        await refreshAutoplayQueue()
        guard !Task.isCancelled else { return true }
        let nextIndex = currentQueueIndex + 1
        guard queue.count > previousCount, queue.indices.contains(nextIndex) else {
            EnsembleLogger.debug("⏹️ Queue ended with no autoplay recommendations")
            return false
        }
        await performQueueAdvance(.item(index: nextIndex, wrapped: false), caller: caller)
        return true
    }

    /// End of queue: stay on the last item, paused at the start, and keep the queue.
    @MainActor
    func settleAtEndOfQueue(caller: String) {
        guard queue.indices.contains(currentQueueIndex) else {
            stop()
            return
        }
        if let track = currentTrack {
            reportingController.reportState(track: track, state: "stopped", time: currentTime)
        }
        selectQueueItemWhilePaused(at: currentQueueIndex, caller: "\(caller)-endOfQueue")
    }

    /// Handles a natural end on either engine.
    @MainActor
    func handleQueueExhausted() async {
        EnsembleLogger.playback("QUEUE_EXHAUSTED: idx=\(currentQueueIndex)/\(queue.count), state=\(playbackState)")

        if shouldSuppressAutomaticAdvanceDuringHandoff {
            EnsembleLogger.playback("QUEUE_EXHAUSTED: ignored — handoff active")
            if playbackState == .buffering, let pauseReason = currentPauseReason {
                applyPauseForHandoff(reason: pauseReason)
            }
            return
        }

        guard !isHandlingQueueExhaustion else {
            EnsembleLogger.debug("⏭️ Queue exhaustion handling already in progress - ignoring duplicate event")
            return
        }
        isHandlingQueueExhaustion = true
        defer { isHandlingQueueExhaustion = false }

        // Rate-limit: if called >3 times within 2 seconds, stop playback to prevent cascade
        let now = Date()
        queueExhaustedTimestamps.append(now)
        queueExhaustedTimestamps = queueExhaustedTimestamps.filter { now.timeIntervalSince($0) < 2.0 }
        if queueExhaustedTimestamps.count > 3 {
            // A cascade of ends halts paused on the current item; only sign-out,
            // server removal and clearing stop playback (G20).
            EnsembleLogger.playback("RAPID_ADVANCE: handleQueueExhausted called \(queueExhaustedTimestamps.count)x in 2s — pausing")
            queueExhaustedTimestamps.removeAll()
            if queue.indices.contains(currentQueueIndex) {
                selectQueueItemWhilePaused(at: currentQueueIndex, caller: "rapidAdvance")
            } else {
                stop()
            }
            return
        }


        guard !queue.isEmpty else {
            stop()
            return
        }

        // If the track failed (not natural end-of-track), do NOT advance to the next song.
        // The user tapped *this* track — they want to see the error, not a different song.
        // They can manually retry, skip, or pick a new track.
        if case .failed = playbackState {
            EnsembleLogger.debug("⏭️ Track is in failed state — staying on current track (no auto-advance)")
            return
        }

        // Cancel any pending stall retry. End-of-queue is not a recoverable stall.
        stallRecoveryTask?.cancel()
        stallRecoveryTask = nil

        applyPendingShuffleReorder()
        let advance = queueAdvance(.naturalEnd)
        // At an Apple Music item with autoplay on, a station replaces the
        // continuation and any fetched autoplay items (Q1).
        if isAutoplayEnabled,
           let seed = currentTrack,
           seed.isAppleMusic,
           Self.appleMusicStationReplacesAdvance(advance, in: queue) {
            if case let .item(index, _) = advance { queue.removeSubrange(index...) }
            if !(await startAppleMusicAutoplayStationIfPossible(seed: seed)) {
                settleAtEndOfQueue(caller: "handleQueueExhausted")
            }
            return
        }

        if queue.indices.contains(currentQueueIndex) {
            recordToHistory(queue[currentQueueIndex])
        }
        if case .item = advance {
            // The incoming item shows as loading at once, on either engine (G16).
            playbackState = .loading
        }
        await performQueueAdvance(advance, caller: "handleQueueExhausted")
    }

    /// Returns the streaming quality to stamp on a new queue item, if it will stream.
    func currentQueueQuality(for track: Track) -> String? {
        let streamingQuality = AudioQualityPreference.storedStreamingQuality()
        if let path = track.localFilePath, FileManager.default.fileExists(atPath: path) {
            let downloadQuality = track.downloadedQuality
                ?? AudioQualityPreference.fileQuality(at: URL(fileURLWithPath: path))
                ?? AudioQualityPreference.storedDownloadQuality()
            return AudioQualityPreference.prefersStreaming(
                streamingQuality,
                overDownloadQuality: downloadQuality
            ) ? streamingQuality : nil
        }
        return streamingQuality
    }

    /// Creates a QueueItem stamped with the current streaming quality
    func makeQueueItem(track: Track, source: QueueItemSource) -> QueueItem {
        QueueItem(track: track, source: source, streamingQuality: currentQueueQuality(for: track))
    }

    @MainActor
    public func next() {
        guard !queue.isEmpty else { return }

        let currentTrackTitle = currentTrack?.title ?? "nil"
        let currentState = playbackState
        EnsembleLogger.debug("[next] called — track='\(currentTrackTitle)', state=\(currentState), idx=\(currentQueueIndex)/\(queue.count)")
        resetHandoffForUserPlaybackIntent()
        if audioEngine?.isSmartMixTransitionActive != true {
            applyPendingShuffleReorder()
        }

        if handleSmartMixNextIfNeeded() {
            return
        }

        #if os(iOS)
            if #available(iOS 18, *),
               currentTrack?.isAppleMusic == true,
               appleMusicPlaybackController?.isStationActive == true {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let generation = self.sessionGeneration
                    do {
                        try await self.appleMusicPlaybackController?.skipToNextEntry()
                        guard generation == self.sessionGeneration,
                              self.currentTrack?.isAppleMusic == true,
                              self.appleMusicPlaybackController?.isStationActive == true,
                              self.appleMusicPlaybackController?.activeQueueGeneration != nil
                        else { return }
                    } catch {
                        guard generation == self.sessionGeneration,
                              self.currentTrack?.isAppleMusic == true else { return }
                        self.playbackState = .failed(error.localizedDescription)
                    }
                }
                return
            }
        #endif

        if playbackState == .paused {
            Task { @MainActor in
                self.navigateToNextQueueItemWhilePaused()
            }
            return
        }

        // Cancel any in-progress skip transition
        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        // Stop old audio immediately and clear scheduled gapless files
        beginSession()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        EnsembleLogger.playback("SKIP: next() — idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")

        // Record current track to history before advancing
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performQueueAdvance(self.queueAdvance(.next), caller: "next()")
        }
    }

    @MainActor
    @discardableResult
    func handleSmartMixNextIfNeeded() -> Bool {
        guard let engine = audioEngine,
              engine.isSmartMixTransitionActive,
              let incomingTrackId = engine.smartMixIncomingTrackId,
              let incomingIndex = Self.queueIndexForAdvance(
                  matching: incomingTrackId,
                  in: queue,
                  after: currentQueueIndex
              )
        else {
            return false
        }

        let elapsed = engine.smartMixTransitionElapsed
        if elapsed < engine.smartMixSkipThreshold {
            engine.acceptSmartMixIncomingTrack()
            commitEngineItemChange(trackID: incomingTrackId, via: .crossfade, engine: .native)
            playbackState = .playing
            updateNowPlayingInfo()
            savePlaybackState()
            EnsembleLogger.playback("SMARTMIX_NEXT: accepted incoming track at \(String(format: "%.1f", elapsed))s")
            return true
        }

        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        beginSession()
        engine.cancelSmartMixTransition()
        playbackState = .loading

        if currentQueueIndex >= 0, currentQueueIndex < queue.count, currentQueueIndex != incomingIndex {
            recordToHistory(queue[currentQueueIndex])
        }

        currentQueueIndex = incomingIndex
        currentTrack = queue[incomingIndex].track
        recordToHistory(queue[incomingIndex])

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performQueueAdvance(
                self.queueAdvance(.next, after: incomingIndex),
                caller: "smartMix-next"
            )
        }

        EnsembleLogger.playback("SMARTMIX_NEXT: skipped incoming track at \(String(format: "%.1f", elapsed))s")
        return true
    }

    @MainActor
    public func previous() {
        applyPendingShuffleReorder()
        let target = queueController.previousNavigationTarget(
            currentTime: currentTime,
            currentQueueIndex: currentQueueIndex,
            playbackHistoryCount: playbackHistory.count,
            restartThreshold: Self.previousRestartThreshold
        )

        if playbackState == .paused {
            Task { @MainActor in
                self.navigateToPreviousItemWhilePaused(target)
            }
            return
        }

        switch target {
        case .seekToZero:
            seek(to: 0)
        case let .queueIndex(index):
            navigateToPreviousQueueItemWhilePlaying(at: index)
        case let .historyIndex(index):
            navigateToPreviousHistoryItemWhilePlaying(at: index)
        }
    }

    @MainActor
    func navigateToPreviousQueueItemWhilePlaying(at index: Int) {
        guard queue.indices.contains(index), index < currentQueueIndex else { return }
        resetHandoffForUserPlaybackIntent()

        // Cancel any in-progress skip transition
        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        // Stop old audio immediately and clear scheduled gapless files
        beginSession()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        EnsembleLogger.playback("SKIP: previous() — idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")

        // Remove the last item from history since we're navigating back to it
        if !playbackHistory.isEmpty {
            playbackHistory.removeLast()
        }

        currentQueueIndex = index

        // Push previous track info to lock screen with rate=1.0
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            currentTrack = queue[currentQueueIndex].track
            updatePlaybackTimes(rawTime: 0)
            updateNowPlayingInfo()
        }

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.playCurrentQueueItem(caller: "previous()")
            guard !Task.isCancelled else { return }
            self.savePlaybackState()
            await self.checkAndRefreshAutoplayQueue()
        }
    }

    @MainActor
    func navigateToPreviousHistoryItemWhilePlaying(at historyIndex: Int) {
        guard playbackHistory.indices.contains(historyIndex) else {
            seek(to: 0)
            return
        }
        resetHandoffForUserPlaybackIntent()

        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        beginSession()
        audioEngine?.clearScheduledFiles()
        audioEngine?.pause()
        playbackState = .loading

        guard let targetIndex = queueController.restorePreviousHistoryItem(
            at: historyIndex,
            queue: &queue,
            playbackHistory: &playbackHistory,
            currentQueueIndex: currentQueueIndex
        ) else { return }
        currentQueueIndex = targetIndex
        currentTrack = queue[currentQueueIndex].track
        updatePlaybackTimes(rawTime: 0)
        updateNowPlayingInfo()

        skipTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            await self.playCurrentQueueItem(caller: "previous-history")
            guard !Task.isCancelled else { return }
            self.savePlaybackState()
            await self.checkAndRefreshAutoplayQueue()
        }
    }

    @MainActor
    func navigateToNextQueueItemWhilePaused() {
        switch queueAdvance(.next) {
        case let .item(index, wrapped):
            recordCurrentAndSkippedTracksBeforeJump(to: index)
            selectQueueItemWhilePaused(at: index, caller: wrapped ? "next-paused-wrap" : "next-paused")
        case .unavailable:
            _ = reportUnavailableNextTrackIfNeeded(after: currentQueueIndex)
        case .repeatCurrent, .continuation, .endOfQueue:
            settleAtEndOfQueue(caller: "next-paused")
        }
    }

    @MainActor
    func navigateToPreviousItemWhilePaused(_ target: PlaybackPreviousNavigationTarget) {
        switch target {
        case .seekToZero:
            seek(to: 0)
        case let .queueIndex(index):
            navigateToPreviousQueueItemWhilePaused(at: index)
        case let .historyIndex(index):
            navigateToPreviousHistoryItemWhilePaused(at: index)
        }
    }

    @MainActor
    func navigateToPreviousQueueItemWhilePaused(at index: Int) {
        guard queue.indices.contains(index), index < currentQueueIndex else { return }
        resetHandoffForUserPlaybackIntent()
        if !playbackHistory.isEmpty {
            playbackHistory.removeLast()
        }
        selectQueueItemWhilePaused(at: index, caller: "previous-paused")
    }

    @MainActor
    func navigateToPreviousHistoryItemWhilePaused(at historyIndex: Int) {
        guard playbackHistory.indices.contains(historyIndex) else {
            seek(to: 0)
            return
        }
        resetHandoffForUserPlaybackIntent()

        guard let targetIndex = queueController.restorePreviousHistoryItem(
            at: historyIndex,
            queue: &queue,
            playbackHistory: &playbackHistory,
            currentQueueIndex: currentQueueIndex
        ) else { return }

        selectQueueItemWhilePaused(at: targetIndex, caller: "previous-history-paused")
    }

    @MainActor
    func recordCurrentAndSkippedTracksBeforeJump(to targetIndex: Int) {
        queueController.recordCurrentAndSkippedItems(
            before: targetIndex,
            queue: queue,
            currentQueueIndex: currentQueueIndex,
            playbackHistory: &playbackHistory
        )
    }

    @MainActor
    func selectQueueItemWhilePaused(at index: Int, caller: String) {
        guard queue.indices.contains(index) else { return }

        beginSession()
        skipTransitionTask?.cancel()
        skipTransitionTask = nil
        #if os(iOS)
            if #available(iOS 18, *) {
                appleMusicPlaybackController?.stop()
            }
        #endif
        audioEngine?.clearScheduledFiles()
        audioEngine?.stop()
        endTrackTransitionBackgroundTask()
        audioAnalyzer.pauseUpdates()

        currentQueueIndex = index
        currentTrack = queue[index].track
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        playbackState = .paused
        updateNowPlayingInfo()
        savePlaybackState()

        EnsembleLogger.playback("QUEUE_NAVIGATE_PAUSED: \(caller) - idx=\(currentQueueIndex)/\(queue.count), track='\(currentTrack?.title ?? "nil")'")
        Task { await checkAndRefreshAutoplayQueue() }
    }

    /// Add a track to end of queue (before autoplay). Alias for playLast.
    public func addToQueue(_ track: Track) {
        playLast(track)
    }

    /// Add tracks to end of queue (before autoplay). Alias for playLast.
    public func addToQueue(_ tracks: [Track]) {
        playLast(tracks)
    }

    /// Add a track after the existing Up Next items, ahead of the original queue.
    public func playNext(_ track: Track) {
        playNext([track])
    }

    /// Add tracks after the existing Up Next items, preserving action and track order.
    public func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard startPlaybackIfNoCurrentItem(tracks) == false else { return }
        let items = tracks.map { makeQueueItem(track: $0, source: .upNext) }
        queueController.insertUpNext(
            items,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: currentQueueIndex,
            shuffleEnabled: isShuffleEnabled
        )
        setQueueProtection(true, reason: "playNext")
        commitQueueMutation()
    }

    /// Play Next or Play Last with nothing to add to starts playback (G10); with a
    /// queue, even a paused one, they only edit it.
    func startPlaybackIfNoCurrentItem(_ tracks: [Track]) -> Bool {
        guard !queue.indices.contains(currentQueueIndex) else { return false }
        Task { await play(tracks: tracks, startingAt: 0) }
        return true
    }

    /// Add a track to end of the "real" queue (before autoplay tracks)
    public func playLast(_ track: Track) {
        playLast([track])
    }

    /// Add tracks to end of the "real" queue (before autoplay tracks)
    public func playLast(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        guard startPlaybackIfNoCurrentItem(tracks) == false else { return }
        let items = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        queueController.insertAtEndOfManualQueue(
            items,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: currentQueueIndex,
            shuffleEnabled: isShuffleEnabled
        )
        setQueueProtection(true, reason: "playLast")
        commitQueueMutation()
    }

    @MainActor
    public func removeFromQueue(at index: Int) {
        var didUpdateAppleMusicStationQueue = false
        #if os(iOS)
            if #available(iOS 18, *),
               queue.indices.contains(index),
               queue[index].source == .autoplay,
               let catalogID = queue[index].track.appleMusicCatalogID,
               appleMusicPlaybackController?.isStationActive == true {
                guard appleMusicPlaybackController?.removeFirstUpcomingEntry(catalogID: catalogID) == true else {
                    return
                }
                didUpdateAppleMusicStationQueue = true
            }
        #endif
        guard queueController.removeItem(
            at: index,
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: &currentQueueIndex,
            shuffleEnabled: isShuffleEnabled
        ) != nil else { return }

        setQueueProtection(true, reason: "remove")
        commitQueueMutation(synchronizeAppleMusicQueue: !didUpdateAppleMusicStationQueue)
    }

    public func clearQueue() {
        queueController.clearUpcoming(
            queue: &queue,
            originalQueue: &originalQueue,
            currentQueueIndex: &currentQueueIndex
        )
        setQueueProtection(false, reason: "clear")
        commitQueueMutation()
    }

    /// Move a queue item by ID from source position to destination position.
    /// This is the primary method for drag-to-reorder (more robust than index-based).
    /// Both indices are absolute queue positions (not filtered/relative).
    public func moveQueueItem(byId sourceId: String, from sourceIndex: Int, to destinationIndex: Int, destinationSource: QueueItemSource? = nil) {
        guard let result = queueController.moveItem(
            byId: sourceId,
            from: sourceIndex,
            to: destinationIndex,
            destinationSource: destinationSource,
            queue: &queue,
            currentQueueIndex: &currentQueueIndex
        ) else { return }

        EnsembleLogger.debug("🔄 Moved queue item '\(result.item.track.title)' (ID: \(sourceId)) from \(sourceIndex) to \(result.destinationIndex)")

        if isShuffleEnabled {
            originalQueue = queueController.unshuffledOrder(originalQueue, carryingMove: result.item, in: queue)
        }

        // Force @Published update by reassigning the queue array
        // (Required because in-place mutations don't trigger Combine notifications)
        queue = queue

        setQueueProtection(true, reason: "reorder")
        commitQueueMutation(refreshAutoplay: false)
    }

    /// Only active playback protects a manually edited queue from direct app UI starts.
    public func shouldConfirmQueueReplacement() -> Bool {
        Self.shouldConfirmQueueReplacement(
            playbackState: playbackState,
            hasUserQueueEdits: hasUserQueueEdits,
            isQueueEmpty: queue.isEmpty
        )
    }

    nonisolated static func shouldConfirmQueueReplacement(
        playbackState: PlaybackState,
        hasUserQueueEdits: Bool,
        isQueueEmpty: Bool
    ) -> Bool {
        playbackState == .playing && hasUserQueueEdits && !isQueueEmpty
    }

    func setQueueProtection(_ isProtected: Bool, reason: String) {
        guard hasUserQueueEdits != isProtected else { return }
        hasUserQueueEdits = isProtected
        UserJourneyLogger.log(
            context: "playback",
            event: "queueProtectionChanged",
            details: [
                "protected": "\(isProtected)",
                "queueCount": "\(queue.count)",
                "reason": reason
            ]
        )
    }

    func commitQueueMutation(
        refreshAutoplay: Bool = true,
        synchronizeAppleMusicQueue: Bool = true
    ) {
        savePlaybackState()
        if synchronizeAppleMusicQueue {
            synchronizeAppleMusicQueueAfterMutation()
        }
        invalidateGaplessSchedule(thenRefreshAutoplay: refreshAutoplay)
    }

    /// Clear the AudioEngine's gapless schedule and re-prefetch based on new queue order.
    /// Call after any queue mutation that changes what the "next" track should be.
    /// Without this, the engine's playerNode FIFO retains stale tracks from before the
    /// mutation, causing wrong songs to play on gapless transitions.
    func invalidateGaplessSchedule(thenRefreshAutoplay: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.audioEngine?.isSmartMixTransitionActive == true {
                self.audioEngine?.cancelSmartMixTransition(
                    continueIncoming: self.audioEngine?.hasPromotedSmartMixTransition == true
                )
            }

            let scheduledTrackIDs = self.audioEngine?.scheduledTrackIdsInOrder ?? []
            let shouldInvalidate = self.prefetchController.shouldInvalidateScheduledTracks(
                scheduledTrackIDs: scheduledTrackIDs,
                queue: self.queue,
                currentQueueIndex: self.currentQueueIndex,
                repeatMode: self.repeatMode
            )

            if shouldInvalidate {
                self.audioEngine?.clearScheduledFiles()
                await self.prefetchNextItem()
            } else if scheduledTrackIDs.isEmpty {
                await self.prefetchNextItem()
            } else {
                EnsembleLogger.debug("[prefetch] Keeping gapless schedule; next track unchanged")
            }

            if thenRefreshAutoplay {
                await self.checkAndRefreshAutoplayQueue()
            }
        }
    }

    public func toggleShuffle() {
        isShuffleEnabled.toggle()
        UserDefaults.standard.set(isShuffleEnabled, forKey: PlaybackPreferenceKey.shuffleEnabled)

        // During an Apple Music item or a SmartMix overlap the reorder waits for
        // the item to finish; toggling back before then cancels it (G7).
        if isQueueReorderDeferred {
            hasPendingShuffleReorder.toggle()
            updateNowPlayingInfo()
            return
        }
        applyShuffleReorder(synchronizeAppleMusicQueue: true)
    }

    /// Reordering now would restart the current Apple Music item or cut a SmartMix overlap.
    var isQueueReorderDeferred: Bool {
        currentTrack?.isAppleMusic == true || audioEngine?.isSmartMixTransitionActive == true
    }

    /// Applies a deferred shuffle at an item boundary, before the next item is chosen.
    func applyPendingShuffleReorder() {
        guard hasPendingShuffleReorder else { return }
        hasPendingShuffleReorder = false
        applyShuffleReorder(synchronizeAppleMusicQueue: false)
    }

    func applyShuffleReorder(synchronizeAppleMusicQueue: Bool) {
        if isShuffleEnabled {
            queueController.enableShuffle(
                queue: &queue,
                originalQueue: &originalQueue,
                currentQueueIndex: &currentQueueIndex,
                playbackHistory: playbackHistory
            )
        } else {
            queueController.disableShuffle(
                queue: &queue,
                originalQueue: originalQueue,
                currentQueueIndex: &currentQueueIndex
            )
        }

        commitQueueMutation(synchronizeAppleMusicQueue: synchronizeAppleMusicQueue)
        updateNowPlayingInfo()
    }

    public func cycleRepeatMode() {
        let nextRawValue = EnsembleQueuePolicy.nextRepeatRawValue(
            current: repeatMode.rawValue,
            caseCount: RepeatMode.allCases.count
        )
        setRepeatMode(RepeatMode(rawValue: nextRawValue) ?? .off)
    }

    public func setShuffleEnabled(_ enabled: Bool) {
        guard isShuffleEnabled != enabled else {
            updateNowPlayingInfo()
            return
        }

        toggleShuffle()
    }

    public func setRepeatMode(_ mode: RepeatMode) {
        repeatMode = mode
        UserDefaults.standard.set(repeatMode.rawValue, forKey: PlaybackPreferenceKey.repeatMode)
        #if os(iOS)
            if #available(iOS 18, *) {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.repeatMode == mode,
                          self.currentTrack?.isAppleMusic == true,
                          self.appleMusicPlaybackController?.activeQueueGeneration != nil else { return }
                    self.appleMusicPlaybackController?.setRepeatOneEnabled(mode == .one)
                }
            }
        #endif
        invalidateGaplessSchedule()
        updateNowPlayingInfo()
    }

    public func toggleAutoplay() {
        isAutoplayEnabled.toggle()
        UserDefaults.standard.set(isAutoplayEnabled, forKey: PlaybackPreferenceKey.autoplayEnabled)

        if isAutoplayEnabled {
            // Immediately fetch autoplay tracks when enabled
            Task {
                await refreshAutoplayQueue()
            }
        } else {
            // Remove all autoplay items from queue and clear state
            queue.removeAll { $0.source == .autoplay }
            originalQueue.removeAll { $0.source == .autoplay }
            autoplayTracks = []
            queueController.clearAutoGeneratedTrackIds()
            radioMode = .off
            commitQueueMutation(refreshAutoplay: false)
        }
    }

    public func toggleSmartMix() {
        setSmartMixEnabled(!isSmartMixEnabled)
    }

    public func setSmartMixEnabled(_ enabled: Bool) {
        guard isSmartMixEnabled != enabled else { return }
        isSmartMixEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: PlaybackPreferenceKey.smartMixEnabled)

        if enabled {
            Task { await prefetchNextItem() }
        } else {
            audioEngine?.cancelSmartMixTransition(continueIncoming: audioEngine?.hasPromotedSmartMixTransition == true)
            audioEngine?.clearScheduledFiles()
            Task { await prefetchNextItem() }
        }

        EnsembleLogger.playback("SMARTMIX: \(enabled ? "enabled" : "disabled")")
    }

    public func setSmartMixDisabledForAlbums(_ disabled: Bool) {
        guard isSmartMixDisabledForAlbums != disabled else { return }
        isSmartMixDisabledForAlbums = disabled
        UserDefaults.standard.set(disabled, forKey: PlaybackPreferenceKey.smartMixDisabledForAlbums)
        EnsembleLogger.playback("SMARTMIX_ALBUMS: \(disabled ? "disabled" : "enabled")")
    }

    @discardableResult
    func removeDuplicateFutureAutoplayItemsIfNeeded(
        shouldInvalidateGaplessSchedule: Bool
    ) -> Set<String> {
        let queuePruneResult = PlaybackQueueController.pruneDuplicateFutureAutoplayItems(
            queue: queue,
            currentQueueIndex: currentQueueIndex
        )
        let originalQueuePruneResult = PlaybackQueueController.pruneDuplicateFutureAutoplayItems(
            queue: originalQueue,
            currentQueueIndex: currentQueueIndex
        )

        guard queuePruneResult.removedItemCount > 0 || originalQueuePruneResult.removedItemCount > 0 else {
            return []
        }

        if queuePruneResult.removedItemCount > 0 {
            queue = queuePruneResult.queue
            for trackId in queuePruneResult.removedTrackIds {
                queueController.removeAutoGeneratedTrack(id: trackId)
            }
            EnsembleLogger.debug(
                "🧹 Removed \(queuePruneResult.removedItemCount) duplicate future autoplay track(s)"
            )
        }

        if originalQueuePruneResult.removedItemCount > 0 {
            originalQueue = originalQueuePruneResult.queue
        }

        savePlaybackState()

        if shouldInvalidateGaplessSchedule {
            invalidateGaplessSchedule()
        }

        return queuePruneResult.removedTrackIds
    }

    /// Checks if queue is running low and refreshes if needed
    func checkAndRefreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }

        let remainingTracksInQueue = queue.count - currentQueueIndex - 1
        if remainingTracksInQueue < 5 {
            EnsembleLogger.debug("🎙️ Running low on queued tracks (\(max(0, remainingTracksInQueue)) remaining), refreshing...")
            await refreshAutoplayQueue()
        }
    }

    func schedulePostPlaybackAutoplayRefresh() {
        postPlaybackAutoplayRefreshTask?.cancel()
        postPlaybackAutoplayRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.checkAndRefreshAutoplayQueue()
            await MainActor.run { [weak self] in
                self?.postPlaybackAutoplayRefreshTask = nil
            }
        }
    }

    /// Trims auto-generated tracks from queue if it exceeds maxQueueLookahead
    /// Removes excess tracks from the end to maintain the limit
    func trimAutoplayQueue() {
        let indicesToRemove = queueController.excessFutureAutoplayIndices(
            queue: queue,
            currentQueueIndex: currentQueueIndex,
            maximumCount: maxQueueLookahead
        )
        guard !indicesToRemove.isEmpty else { return }

        EnsembleLogger.debug("🔪 Trimming \(indicesToRemove.count) excess autoplay tracks from queue")

        for index in indicesToRemove.reversed() {
            let removedTrack = queue[index].track
            if queueController.removeAutoGeneratedTrack(id: removedTrack.playbackIdentity) {
                EnsembleLogger.debug("   Removing: \(removedTrack.title)")
            }
            queue.remove(at: index)
        }

        EnsembleLogger.debug("✅ Queue trimmed to \(queue.count) total tracks")
        invalidateGaplessSchedule()
    }

    public func refreshAutoplayQueue() async {
        guard isAutoplayEnabled else { return }

        removeDuplicateFutureAutoplayItemsIfNeeded(shouldInvalidateGaplessSchedule: true)
        trimAutoplayQueue()

        let futureTracksCount = max(0, queue.count - currentQueueIndex - 1)
        guard futureTracksCount < maxQueueLookahead else { return }

        let seedTrack: Track
        let seedQueueItemID: String?
        if let lastRealIdx = lastRealTrackIndex {
            seedTrack = queue[lastRealIdx].track
            seedQueueItemID = queue[lastRealIdx].id
        } else if let currentTrack = currentTrack {
            seedTrack = currentTrack
            seedQueueItemID = nil
        } else {
            return
        }

        guard let sourceKey = seedTrack.sourceCompositeKey else { return }
        guard let provider = await MainActor.run(body: {
            syncCoordinator.makeRadioProvider(for: sourceKey)
        }) else { return }

        let recommendations = await provider.getRecommendedTracks(basedOn: seedTrack, limit: 10)
        guard !Task.isCancelled, isAutoplayEnabled else { return }
        if let seedQueueItemID {
            guard lastRealTrackIndex.map({ queue[$0].id }) == seedQueueItemID else {
                EnsembleLogger.debug("Discarding Track Radio response after queue boundary changed")
                return
            }
        } else {
            guard currentTrack?.playbackIdentity == seedTrack.playbackIdentity else {
                EnsembleLogger.debug("Discarding Track Radio response after current track changed")
                return
            }
        }
        guard let tracks = recommendations else {
            autoplayTracks = []
            recommendationsExhausted = true
            return
        }
        guard max(0, queue.count - currentQueueIndex - 1) < maxQueueLookahead else { return }

        let newTracks = PlaybackQueueController.autoplayTracksToAppend(
            from: tracks,
            queue: queue,
            currentQueueIndex: currentQueueIndex,
            maximumFutureCount: maxQueueLookahead
        )

        autoplayTracks = tracks
        recommendationsExhausted = newTracks.isEmpty
        for track in newTracks {
            queue.append(makeQueueItem(track: track, source: .autoplay))
            queueController.markAutoGeneratedTrack(id: track.playbackIdentity)
        }
    }

    public func enableRadio(tracks: [Track]) async {
        EnsembleLogger.debug("🎙️ PlaybackService.enableRadio() called")
        EnsembleLogger.debug("  - Input tracks: \(tracks.count)")

        guard !tracks.isEmpty else {
            EnsembleLogger.debug("❌ No tracks to queue for radio")
            return
        }

        // Create queue items as continuePlaying and shuffle
        EnsembleLogger.debug("🔄 Creating and shuffling queue...")
        var items = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        items.shuffle()
        EnsembleLogger.debug("✅ Queue shuffled")

        // Set queue and start from beginning
        queue = items
        originalQueue = items
        hasPendingShuffleReorder = false
        currentQueueIndex = 0
        setQueueProtection(false, reason: "radio")

        // Track all manually-queued tracks so auto-generation doesn't suggest them
        queueController.replaceAutoGeneratedTrackIds(with: Set(items.map(\.track.playbackIdentity)))
        playbackHistory.removeAll()
        let newTrackIds = Set(items.map(\.track.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        // Enable radio mode for continuous playback
        EnsembleLogger.debug("🔄 Enabling radio mode (autoplay with sonically similar)")
        isAutoplayEnabled = true
        radioMode = .trackRadio // Will use sonically similar tracks
        UserDefaults.standard.set(true, forKey: PlaybackPreferenceKey.autoplayEnabled)

        // Start playing first track
        EnsembleLogger.debug("🔄 Starting playback...")
        await playCurrentQueueItem(caller: "beginRadio")
        savePlaybackState()

        // Populate autoplay queue with sonically similar tracks
        EnsembleLogger.debug("🔄 Refreshing autoplay queue for continuous playback...")
        await refreshAutoplayQueue()

        EnsembleLogger.debug("✅ Radio enabled: \(tracks.count) tracks shuffled, autoplay starting")
    }

    public func isTrackAutoGenerated(trackId: String) -> Bool {
        queueController.isTrackAutoGenerated(id: trackId, queue: queue)
    }

    /// Returns an appropriate error message when no tracks are playable.
    /// Distinguishes between device-offline and server-offline scenarios.
    nonisolated static func noPlayableTracksMessage(
        isDeviceOffline: Bool,
        isCellularStreamingDisabled: Bool = false
    ) -> String {
        if isDeviceOffline {
            return "No downloaded tracks available offline"
        }
        if isCellularStreamingDisabled {
            return "No downloaded tracks available while cellular streaming is disabled"
        }
        return "No playable tracks available — server is unreachable"
    }

    /// Surfaces a manual next action that can only reach known-unavailable items.
    @MainActor
    func reportUnavailableNextTrackIfNeeded(after startIndex: Int) -> Bool {
        let nextIndex = startIndex + 1
        guard nextIndex < queue.count else { return false }

        let hasKnownUnavailableNextTrack = queue[nextIndex...].contains { item in
            !isTrackPlayableNow(item.track, plexStreamingAllowed: isPlexStreamingAllowedOnCurrentNetwork())
        }
        guard hasKnownUnavailableNextTrack else { return false }

        let isDeviceOffline = !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
        let isCellularStreamingDisabled = !isDeviceOffline && !isPlexStreamingAllowedOnCurrentNetwork()
        let message = isDeviceOffline
            ? "Next item is not available offline"
            : Self.noPlayableTracksMessage(
                isDeviceOffline: false,
                isCellularStreamingDisabled: isCellularStreamingDisabled
            )
        playbackState = .failed(message)

        EnsembleLogger.playback(
            "QUEUE_NEXT_BLOCKED: offline=\(isDeviceOffline), idx=\(currentQueueIndex)/\(queue.count), message='\(message)'"
        )
        UserJourneyLogger.log(
            context: "playback",
            event: "nextBlocked",
            details: [
                "offline": "\(isDeviceOffline)",
                "queueIndex": "\(currentQueueIndex)",
                "queueCount": "\(queue.count)",
                "reason": "knownUnavailableTrack"
            ]
        )
        return true
    }

    @MainActor
    func handleAccountSourcesChanged(configuration: SourceConfigurationSnapshot) async {
        let currentTrackStillAvailable = currentTrack.map {
            Self.isTrackSourceAvailable($0, configuration: configuration)
        } ?? true

        let pruneResult = Self.pruneQueueForSourceConfiguration(
            queue: queue,
            originalQueue: originalQueue,
            playbackHistory: playbackHistory,
            currentQueueIndex: currentQueueIndex,
            configuration: configuration
        )

        let hasQueueChanges = pruneResult.removedQueueItemCount > 0
            || pruneResult.queue.count != queue.count
            || pruneResult.originalQueue.count != originalQueue.count
            || pruneResult.playbackHistory.count != playbackHistory.count

        guard hasQueueChanges || !currentTrackStillAvailable else { return }

        let previousPlaybackState = playbackState

        queue = pruneResult.queue
        originalQueue = pruneResult.originalQueue
        playbackHistory = pruneResult.playbackHistory
        currentQueueIndex = pruneResult.nextCurrentQueueIndex
        queueController.syncAutoGeneratedTrackIds(from: queue)

        guard currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            clearPlaybackAfterSourcePrune()
            return
        }

        let didReplaceCurrentTrack = pruneResult.removedCurrentQueueItem || !currentTrackStillAvailable

        if didReplaceCurrentTrack {
            switch previousPlaybackState {
            case .playing, .loading, .buffering:
                await playCurrentQueueItem(forcingFreshItem: true, caller: "sourcePrune-playing")
            case .paused:
                await playCurrentQueueItem(forcingFreshItem: true, caller: "sourcePrune-paused")
                applyPauseForHandoff(reason: currentPauseReason ?? .system)
            case .stopped, .failed:
                currentTrack = queue[currentQueueIndex].track
                updatePlaybackTimes(rawTime: 0)
                bufferedProgress = 0
                waveformHeights = [] // Clear old waveform immediately
                playbackState = .stopped
                updateNowPlayingInfo()
                await prefetchNextItem()
            }
        } else {
            await prefetchNextItem()
        }

        savePlaybackState()
    }

    @MainActor
    func clearPlaybackAfterSourcePrune() {
        beginSession()
        endTrackTransitionBackgroundTask()
        #if os(iOS)
            if #available(iOS 18, *) {
                appleMusicPlaybackController?.stop()
            }
        #endif
        audioEngine?.pause()
        audioEngine?.stop()
        clearFileURLCache()
        cancelNowPlayingArtworkLoad(clearArtwork: true)

        queue = []
        originalQueue = []
        hasPendingShuffleReorder = false
        currentQueueIndex = -1
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        reportingController.resetForTrack()
        queueController.clearAutoGeneratedTrackIds()

        nowPlayingBridge.clearNowPlayingInfo()
        savePlaybackState()
    }
}
