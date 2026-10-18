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

// Playback commands, engine events, item failure, and the transition background task.
extension PlaybackService {
    nonisolated static func shouldPrepareEndTransitionLease(
        playbackState: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval,
        hasContinuousProviderSuccessor: Bool,
        isFinalEntryReset: Bool = false,
        leadTime: TimeInterval = 4
    ) -> Bool {
        guard playbackState == .playing,
              !hasContinuousProviderSuccessor else { return false }
        if isFinalEntryReset { return true }
        guard currentTime.isFinite,
              duration.isFinite,
              duration > 0,
              leadTime > 0 else { return false }
        return currentTime >= max(0, duration - leadTime)
    }

    nonisolated static func shouldContinuePlaybackRequest(
        generation: UInt64,
        currentGeneration: UInt64,
        queuedTrack: Track,
        queue: [QueueItem],
        currentQueueIndex: Int
    ) -> Bool {
        generation == currentGeneration &&
            queue.indices.contains(currentQueueIndex) &&
            queue[currentQueueIndex].track.playbackIdentity == queuedTrack.playbackIdentity
    }

    enum AudioEnginePreparation: Equatable {
        case reuseExisting
        case createMissing
        case recreateFailed
    }

    /// Decides whether a playback request can reuse the current engine or must
    /// rebuild it first. This keeps "play after stop()" on the normal launch path
    /// instead of falling through to a nil-engine failure after transport resolves.
    nonisolated static func audioEnginePreparation(
        hasAudioEngine: Bool,
        playbackState: PlaybackState
    ) -> AudioEnginePreparation {
        guard hasAudioEngine else {
            return .createMissing
        }
        if case .failed = playbackState {
            return .recreateFailed
        }
        return .reuseExisting
    }

    @MainActor
    func recoverCurrentStream(after error: Error) {
        guard stallRecoveryTask == nil, let trackId = currentTrack?.playbackIdentity else { return }

        EnsembleLogger.playback("ENGINE: stream interrupted -- retrying from \(String(format: "%.1f", currentTime))s (\(error.localizedDescription))")
        audioEngine?.pause()
        playbackState = .buffering
        updateNowPlayingInfo()

        stallRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.stallRecoveryTask = nil }
            guard self.currentTrack?.playbackIdentity == trackId else { return }
            await self.retryCurrentTrack(forceConnectionRefresh: false, reason: "stream-interrupted")
        }
    }

    /// Destroys the current audio engine and creates a fresh instance.
    @MainActor
    func recreatePlayer() {
        EnsembleLogger.playback("RECREATE_ENGINE: destroying audio engine and creating fresh instance")
        cleanup()
        setupPlayer()
    }

    /// Ensures a playable AudioPlaybackEngine exists before a new launch request
    /// starts mutating state or waiting on network/file resolution.
    @MainActor
    func prepareAudioEngineForPlaybackIfNeeded() -> Bool {
        switch Self.audioEnginePreparation(
            hasAudioEngine: audioEngine != nil,
            playbackState: playbackState
        ) {
        case .reuseExisting:
            return true
        case .createMissing:
            EnsembleLogger.playback("ENGINE: creating missing audio engine before playback")
            setupPlayer()
        case .recreateFailed:
            recreatePlayer()
        }

        guard audioEngine != nil else {
            EnsembleLogger.playback("ENGINE: failed to prepare audio engine before playback")
            playbackState = .failed("Audio engine not initialized")
            return false
        }

        return true
    }

    /// The session engine events must carry to be acted on.
    var activeEngineSession: PlaybackSessionID {
        PlaybackSessionID(rawValue: sessionGeneration)
    }

    /// Starts a new session: every load request, a stop, a paused load, and a
    /// change of the loaded item. Events and async work from older sessions are stale.
    @discardableResult
    func beginSession() -> UInt64 {
        sessionGeneration &+= 1
        return sessionGeneration
    }

    /// Which playback states each event is acted on in, for both engines.
    /// Apple Music reports its end while paused at the last frame; the native
    /// engine never ends while paused, so a late native end after a pause is dropped.
    nonisolated static func acceptsEngineEvent(
        _ event: PlaybackEngineEvent,
        from engine: PlaybackEngineKind,
        playbackState: PlaybackState
    ) -> Bool {
        let isActive = switch playbackState {
        case .loading, .buffering, .playing: true
        case .paused, .stopped, .failed: false
        }
        switch event {
        case .progress, .itemChanged, .metadataChanged, .upcomingChanged, .externalPrevious:
            return isActive
        case .ended:
            return isActive || (playbackState == .paused && engine == .appleMusic)
        case .externallyPaused:
            return playbackState == .playing || playbackState == .buffering
        case .externallyResumed:
            return playbackState == .paused
        case .started, .buffered, .stalled, .transitionActive, .failed:
            return true
        }
    }

    /// The single entry for engine events. Staleness is decided here, once.
    @MainActor
    func handleEngineEvent(_ envelope: PlaybackEngineEventEnvelope) {
        guard envelope.session == activeEngineSession else {
            if case .progress = envelope.event { return }
            EnsembleLogger.debug(
                "[EngineEvent] dropped \(envelope.engine) event from session \(envelope.session)"
                    + " active=\(activeEngineSession)"
            )
            return
        }
        guard Self.acceptsEngineEvent(envelope.event, from: envelope.engine, playbackState: playbackState) else {
            return
        }

        switch envelope.event {
        case let .started(trackID):
            handleEngineStarted(trackID: trackID, session: envelope.session)
        case let .progress(trackID, position):
            handleEngineProgress(trackID: trackID, position: position, engine: envelope.engine)
        case let .buffered(trackID, fraction):
            guard currentTrack?.playbackIdentity == trackID else { return }
            let bounded = min(max(fraction, 0), 1)
            guard bounded >= bufferedProgress, abs(bufferedProgress - bounded) > 0.002 else { return }
            bufferedProgress = bounded
        case let .stalled(isStalled):
            guard playbackState == .playing || playbackState == .buffering else { return }
            playbackState = isStalled ? .buffering : .playing
        case let .itemChanged(trackID, kind):
            commitEngineItemChange(trackID: trackID, via: kind, engine: envelope.engine)
        case let .transitionActive(isActive):
            guard isSmartMixTransitionActive != isActive else { return }
            isSmartMixTransitionActive = isActive
            if !isActive { applyPendingShuffleReorder() }
        case .ended:
            handleEngineEnded(session: envelope.session)
        case .externallyPaused:
            applyPauseForHandoff(reason: .system)
        case .externallyResumed:
            EnsembleLogger.info("[EngineEvent] reconciled externally resumed playback")
            playbackState = .playing
            updateNowPlayingInfo()
        case .externalPrevious:
            previous()
        case let .metadataChanged(track):
            guard let currentTrack,
                  currentTrack.playbackIdentity == track.playbackIdentity,
                  currentTrack != track else { return }
            self.currentTrack = track
            updateNowPlayingInfo()
        case let .upcomingChanged(tracks):
            handleStationUpcomingChanged(tracks)
        case let .failed(error):
            handleEngineFailure(error, session: envelope.session)
        }
    }

    @MainActor
    func handleEngineStarted(trackID: String, session: PlaybackSessionID) {
        guard let track = currentTrack, track.playbackIdentity == trackID else { return }
        // A fresh start reports "playing", as a resume already does (D4).
        reportingController.reportState(track: track, state: "playing", time: currentTime)
        clearItemFailureMarkers()
        applyPendingSeek()
        guard playbackState == .loading || playbackState == .buffering else { return }
        playbackState = .playing
        updateNowPlayingInfo()
        audioAnalyzer.resumeUpdates()
        endTrackTransitionBackgroundTask(for: session.rawValue)
    }

    /// Position updates from either engine.
    @MainActor
    func handleEngineProgress(trackID: String?, position: TimeInterval, engine: PlaybackEngineKind) {
        guard position.isFinite, position >= 0 else { return }
        if let trackID, trackID != currentTrack?.playbackIdentity { return }
        let previousTime = currentTime
        let hasContinuousSuccessor = engineHasContinuousSuccessor(engine)
        let isFinalEntryReset = AppleMusicPlaybackEndPolicy.shouldReportFinalEntryReset(
            playbackTime: position,
            lastPlayingTime: previousTime,
            duration: duration,
            isFinalEntry: !hasContinuousSuccessor,
            wasPlaying: playbackState == .playing
        )
        updatePlaybackTimes(rawTime: position)
        if position < previousTime { updateNowPlayingInfo() }
        // Only the native engine schedules successors; MusicKit queues its own.
        if engine == .native { scheduleGaplessIfNeeded() }
        updateEndTransitionLease(shouldHold: Self.shouldPrepareEndTransitionLease(
            playbackState: playbackState,
            currentTime: position,
            duration: duration,
            hasContinuousProviderSuccessor: hasContinuousSuccessor,
            isFinalEntryReset: isFinalEntryReset
        ))
        persistPlaybackSnapshotIfNeeded(forObservedTime: position)
        audioAnalyzer.updatePlaybackPosition(presentationTime)
        reportingController.observePlayingProgress(
            track: currentTrack,
            time: position,
            duration: duration,
            isNetworkConnected: lastObservedNetworkState?.isConnected == true
        )
    }

    @MainActor
    func engineHasContinuousSuccessor(_ engine: PlaybackEngineKind) -> Bool {
        switch engine {
        case .native:
            guard let audioEngine else { return false }
            return !audioEngine.scheduledTrackIdsInOrder.isEmpty || audioEngine.isSmartMixTransitionActive
        case .appleMusic:
            #if os(iOS)
                if #available(iOS 18, *) {
                    return appleMusicEngineAdapter?.hasContinuousSuccessor == true
                }
            #endif
            return false
        }
    }

    /// The current item changed inside an engine: a gapless boundary, a SmartMix
    /// midpoint, a MusicKit-owned advance, or a station pick. One bookkeeping path
    /// for all of them (Q4).
    @MainActor
    func commitEngineItemChange(
        trackID: String,
        via kind: PlaybackEngineAdvanceKind,
        engine: PlaybackEngineKind
    ) {
        var index: Int?
        var newTrack: Track?
        switch kind {
        case .gapless:
            // A manual skip or an interruption owns the transition; it loads the right item.
            guard !shouldSuppressAutomaticAdvanceDuringHandoff else {
                EnsembleLogger.playback("GAPLESS_ADVANCE: ignored for trackId \(trackID) (handoff active)")
                return
            }
            index = Self.queueIndexForAdvance(
                matching: trackID,
                in: queue,
                after: currentQueueIndex,
                repeatCurrent: repeatMode == .one
            )
            if index == currentQueueIndex, repeatMode != .one { return }
        case .crossfade:
            index = Self.smartMixPromotionQueueIndex(
                matching: trackID,
                currentTrackIdentity: currentTrack?.playbackIdentity,
                in: queue,
                after: currentQueueIndex
            )
            if index == currentQueueIndex { return }
        case .engineOwned:
            guard currentTrack?.playbackIdentity != trackID else { return }
            index = Self.queueIndexForAdvance(matching: trackID, in: queue, after: currentQueueIndex)
            if index == currentQueueIndex { return }
        case let .station(track):
            guard isAppleMusicStationActive else { return }
            if queue.indices.contains(currentQueueIndex),
               queue[currentQueueIndex].source == .autoplay,
               currentTrack?.playbackIdentity == track.playbackIdentity {
                currentTrack = track
                updateNowPlayingInfo()
                return
            }
            // A station Previous returns to an item already in the queue (D5).
            index = Self.futureQueueIndex(matching: trackID, in: queue, after: currentQueueIndex)
                ?? queue.firstIndex { $0.track.playbackIdentity == trackID }
            if index == nil {
                queue.append(makeQueueItem(track: track, source: .autoplay))
                index = queue.count - 1
                queueController.markAutoGeneratedTrack(id: trackID)
            }
            newTrack = track
        }
        guard let index, queue.indices.contains(index) else {
            EnsembleLogger.debug("[EngineEvent] item change to \(trackID) not found in queue")
            return
        }

        EnsembleLogger.playback(
            "ITEM_CHANGED: '\(currentTrack?.title ?? "nil")' (idx \(currentQueueIndex))"
                + " → '\(queue[index].track.title)' (idx \(index)) via \(kind)"
        )
        if queue.indices.contains(currentQueueIndex) {
            recordToHistory(queue[currentQueueIndex])
        }
        currentQueueIndex = index
        currentTrack = newTrack ?? queue[index].track
        let position = kind == .crossfade ? (audioEngine?.currentTime() ?? 0) : 0
        resetForNewItem(at: position, isFullyBuffered: engine == .native)
        if playbackState != .playing {
            playbackState = .playing
        }
        updateEndTransitionLease(shouldHold: false)
        if kind != .crossfade { applyPendingShuffleReorder() }
        updateNowPlayingInfo()
        savePlaybackState()
        if engine == .native {
            Task { await prefetchNextItem() }
        }
        if !isAppleMusicStationActive {
            Task { await checkAndRefreshAutoplayQueue() }
        }
    }

    /// Per-item state that every new item resets, whichever engine plays it (Q4, D3).
    @MainActor
    func resetForNewItem(at position: TimeInterval, isFullyBuffered: Bool) {
        trackStartWallTime = CACurrentMediaTime()
        updatePlaybackTimes(rawTime: position)
        if isFullyBuffered { bufferedProgress = 1.0 }
        waveformHeights = []
        reportingController.resetForTrack()
        guard let track = currentTrack else { return }
        audioAnalyzer.activateTimeline(for: track.playbackIdentity, at: position)
        audioAnalyzer.resumeUpdates()
        generateWaveform(for: track.playbackIdentity)
    }

    /// An item finished with nothing scheduled after it.
    @MainActor
    func handleEngineEnded(session: PlaybackSessionID) {
        #if canImport(UIKit)
            endTransitionLeaseGeneration = nil
        #endif
        let generation = session.rawValue
        beginTrackTransitionBackgroundTask(for: generation)
        Task { @MainActor [self] in
            defer { self.endTrackTransitionBackgroundTask(for: generation) }
            guard session == self.activeEngineSession else { return }
            await self.handleQueueExhausted()
        }
    }

    @MainActor
    func handleEngineFailure(_ error: Error, session: PlaybackSessionID) {
        if audioEngine?.isStreamingSourceActive == true, playbackState == .paused {
            EnsembleLogger.playback("ENGINE: paused stream failed -- refreshing on Play (\(error.localizedDescription))")
            pausedStreamNeedsRefresh = true
            return
        }
        if audioEngine?.isStreamingSourceActive == true,
           playbackState == .playing || playbackState == .buffering || playbackState == .loading {
            recoverCurrentStream(after: error)
            return
        }
        EnsembleLogger.playback("ENGINE: error -- \(error.localizedDescription)")
        guard playbackState == .playing || playbackState == .loading else { return }
        Task { @MainActor in
            await self.handleItemFailure(error.localizedDescription, generation: session.rawValue)
        }
    }

    enum ItemFailureResponse: Equatable {
        case skipToNext
        case halt
    }

    /// G11 and G12: a failed item is skipped once while the intent is to play.
    /// If the item reached by that skip fails too, or the intent was to stay
    /// paused, playback halts on the error and offers Retry. No counter.
    nonisolated static func itemFailureResponse(intendsToPlay: Bool, reachedBySkippingFailure: Bool) -> ItemFailureResponse {
        intendsToPlay && !reachedBySkippingFailure ? .skipToNext : .halt
    }

    @MainActor
    var currentQueueItemID: String? {
        queue.indices.contains(currentQueueIndex) ? queue[currentQueueIndex].id : nil
    }

    @MainActor
    func applyPendingSeek() {
        guard let pending = pendingSeek else { return }
        pendingSeek = nil
        guard pending.itemID == currentQueueItemID else { return }
        seek(to: pending.time)
    }

    @MainActor
    func clearItemFailureMarkers() {
        failureSkipItemID = nil
        tlsRefreshedItemID = nil
    }

    /// The one path for an item that could not play, whichever engine or stage failed.
    @MainActor
    func handleItemFailure(_ message: String, generation: UInt64) async {
        audioEngine?.pause()
        endTrackTransitionBackgroundTask(for: generation)

        let response = Self.itemFailureResponse(
            intendsToPlay: playbackPreparationShouldStart,
            reachedBySkippingFailure: failureSkipItemID != nil && failureSkipItemID == currentQueueItemID
        )
        if response == .skipToNext, case let .item(index, _) = queueAdvance(.next) {
            EnsembleLogger.playback(
                "ITEM_FAILED: '\(currentTrack?.title ?? "nil")' (\(message)) — skipping to idx \(index)"
            )
            failureSkipItemID = queue[index].id
            tlsRefreshedItemID = nil
            await performQueueAdvance(.item(index: index, wrapped: false), caller: "itemFailed-skip")
            return
        }

        EnsembleLogger.playback("ITEM_FAILED: '\(currentTrack?.title ?? "nil")' (\(message)) — halting")
        clearItemFailureMarkers()
        playbackState = .failed(message)
        updateNowPlayingInfo()
    }

    /// Begins a background task to keep the app alive during track transitions.
    /// Without this, iOS may suspend the app between tracks (when no audio is
    /// actively playing), preventing the next track from loading and starting.
    func beginTrackTransitionBackgroundTask(for generation: UInt64) {
        #if canImport(UIKit)
            if endTransitionLeaseGeneration != generation {
                endTransitionLeaseGeneration = nil
            }
            guard trackTransitionBackgroundTaskOwnership.begin(for: generation) else { return }
            let identifier = UIApplication.shared.beginBackgroundTask(
                withName: "TrackTransition"
            ) { [weak self] in
                self?.expireTrackTransitionBackgroundTask()
            }
            guard identifier != .invalid else {
                _ = trackTransitionBackgroundTaskOwnership.end(for: generation)
                EnsembleLogger.error(
                    "Background task denied for track transition"
                        + " appState=\(UIApplication.shared.applicationState.rawValue)"
                        + " remaining=\(UIApplication.shared.backgroundTimeRemaining)"
                )
                return
            }
            trackTransitionBackgroundTask = identifier
            EnsembleLogger.debug("🔒 Background task started for track transition")
        #endif
    }

    /// Holds a finite task only while playback is close enough to an
    /// unscheduled provider boundary to need one.
    func updateEndTransitionLease(shouldHold: Bool) {
        #if canImport(UIKit)
            guard shouldHold else {
                releaseEndTransitionLease()
                return
            }

            let generation = sessionGeneration
            if let leaseGeneration = endTransitionLeaseGeneration {
                guard leaseGeneration != generation else { return }
                releaseEndTransitionLease()
            }
            guard trackTransitionBackgroundTaskOwnership.generation == nil else { return }
            endTransitionLeaseGeneration = generation
            beginTrackTransitionBackgroundTask(for: generation)
        #endif
    }

    func releaseEndTransitionLease() {
        #if canImport(UIKit)
            guard let generation = endTransitionLeaseGeneration else { return }
            endTransitionLeaseGeneration = nil
            endTrackTransitionBackgroundTask(for: generation)
        #endif
    }

    /// Ends the background task only for the request that currently owns it.
    func endTrackTransitionBackgroundTask(for generation: UInt64) {
        #if canImport(UIKit)
            if endTransitionLeaseGeneration == generation {
                endTransitionLeaseGeneration = nil
            }
            guard trackTransitionBackgroundTaskOwnership.end(for: generation) else { return }
            endTrackTransitionBackgroundTaskToken()
        #endif
    }

    /// Ends whichever transition owns the task during stop, pause, or expiration.
    func endTrackTransitionBackgroundTask() {
        #if canImport(UIKit)
            endTransitionLeaseGeneration = nil
            guard trackTransitionBackgroundTaskOwnership.forceEnd() else { return }
            endTrackTransitionBackgroundTaskToken()
        #endif
    }

    /// Prevents an expired near-end lease from immediately chaining another
    /// UIKit task for the same playback generation.
    func expireTrackTransitionBackgroundTask() {
        #if canImport(UIKit)
            let endGeneration = endTransitionLeaseGeneration
            endTrackTransitionBackgroundTask()
            endTransitionLeaseGeneration = endGeneration
        #endif
    }

    func endTrackTransitionBackgroundTaskToken() {
        #if canImport(UIKit)
            guard trackTransitionBackgroundTask != .invalid else { return }
            EnsembleLogger.debug("🔓 Background task ended for track transition")
            UIApplication.shared.endBackgroundTask(trackTransitionBackgroundTask)
            trackTransitionBackgroundTask = .invalid
        #endif
    }

    func resetHandoffForUserPlaybackIntent() {
        startupCoordinator.recordMutation()
        _ = handoffCoordinator.handle(.explicitPlaybackStart, playbackState: playbackState)
    }

    public func play(track: Track, context: PlaybackStartContext) async {
        let resolvedContext = context.reference == nil
            ? PlaybackStartContext(origin: context.origin, source: .track, reference: Self.systemMediaReference(for: track, kind: .track))
            : context
        await play(tracks: [track], startingAt: 0, context: resolvedContext)
    }

    public func play(tracks: [Track], startingAt index: Int) async {
        await play(tracks: tracks, startingAt: index, context: .userInitiated)
    }

    @MainActor
    public func play(tracks: [Track], startingAt index: Int, context: PlaybackStartContext) async {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }
        playbackPreparationCount += 1
        updateNetworkWorkPressure()
        defer {
            playbackPreparationCount -= 1
            updateNetworkWorkPressure()
        }

        let startedAt = Date()
        let markedAudioCritical = await beginAudioCriticalInteractionIfNeeded(for: context)
        defer {
            if markedAudioCritical {
                scheduleAudioCriticalInteractionEnd()
            }
        }
        UserJourneyLogger.log(
            context: "playback",
            event: "startRequested",
            details: [
                "mode": "play",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "count": "\(tracks.count)",
                "startIndex": "\(index)"
            ]
        )

        resetHandoffForUserPlaybackIntent()

        // Queue injection resets instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: index) else {
            // Stop any currently playing audio before showing error state
            await stop()
            queue = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
            originalQueue = queue
            currentQueueIndex = index
            currentTrack = tracks[index]
            let isDeviceOffline = await MainActor.run {
                !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
            }
            let isCellularStreamingDisabled = await MainActor.run {
                !isDeviceOffline && !isPlexStreamingAllowedOnCurrentNetwork()
            }
            playbackState = .failed(Self.noPlayableTracksMessage(
                isDeviceOffline: isDeviceOffline,
                isCellularStreamingDisabled: isCellularStreamingDisabled
            ))
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UserJourneyLogger.log(
                context: "playback",
                event: "startFailed",
                details: [
                    "mode": "play",
                    "origin": context.origin.rawValue,
                    "source": context.source.rawValue,
                    "elapsedMs": "\(elapsedMs)",
                    "reason": "noPlayableTracks",
                    "offline": "\(isDeviceOffline)"
                ]
            )
            return
        }
        let queueTracks = playableQueue.tracks

        // Disable shuffle on regular play
        if isShuffleEnabled {
            isShuffleEnabled = false
            UserDefaults.standard.set(false, forKey: PlaybackPreferenceKey.shuffleEnabled)
        }

        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline queue filter applied: requested=\(tracks.count), playable=\(queueTracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }

        queue = queueTracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        originalQueue = queue
        hasPendingShuffleReorder = false
        currentQueueIndex = playableQueue.startIndex
        setQueueProtection(false, reason: "play")

        // Clear history for fresh session, but preserve cached player items
        // for tracks that appear in the new queue (e.g. tapping the next track
        // from AlbumDetailView shouldn't discard its prefetched player item).
        playbackHistory.removeAll()
        queueController.clearAutoGeneratedTrackIds()
        let newTrackIds = Set(queueTracks.map(\.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        await playCurrentQueueItem(caller: "play(tracks:)")
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        UserJourneyLogger.log(
            context: "playback",
            event: "startPrepared",
            details: [
                "mode": "play",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "elapsedMs": "\(elapsedMs)",
                "queueCount": "\(queueTracks.count)",
                "startIndex": "\(playableQueue.startIndex)"
            ]
        )
        savePlaybackState()
        await donatePlaybackStartIfNeeded(
            context: context,
            fallbackTrack: queueTracks[playableQueue.startIndex],
            shuffle: false
        )

        schedulePostPlaybackAutoplayRefresh()
    }

    func beginAudioCriticalInteractionIfNeeded(for context: PlaybackStartContext) async -> Bool {
        guard Self.shouldMarkAudioCritical(for: context),
              let foregroundWorkScheduler else {
            return false
        }

        await foregroundWorkScheduler.beginInteraction(.audioCritical)
        return true
    }

    func scheduleAudioCriticalInteractionEnd() {
        guard let foregroundWorkScheduler else { return }
        audioCriticalInteractionEndTask?.cancel()
        audioCriticalInteractionEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.audioCriticalInteractionHoldNs)
            guard !Task.isCancelled else { return }
            foregroundWorkScheduler.endInteraction(.audioCritical)
            self?.audioCriticalInteractionEndTask = nil
        }
    }

    nonisolated static func shouldMarkAudioCritical(for context: PlaybackStartContext) -> Bool {
        switch context.origin {
        case .appUI, .siri, .appShortcut, .remoteCommand:
            return true
        case .autoplay, .gaplessAdvance, .queueRestoration, .backgroundRecovery:
            return false
        }
    }

    public func shufflePlay(tracks: [Track]) async {
        await shufflePlay(tracks: tracks, context: .userInitiated)
    }

    public func shufflePlay(tracks: [Track], context: PlaybackStartContext) async {
        guard !tracks.isEmpty else { return }

        let startedAt = Date()
        let markedAudioCritical = await beginAudioCriticalInteractionIfNeeded(for: context)
        defer {
            if markedAudioCritical {
                scheduleAudioCriticalInteractionEnd()
            }
        }
        UserJourneyLogger.log(
            context: "playback",
            event: "startRequested",
            details: [
                "mode": "shuffle",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "count": "\(tracks.count)",
                "startIndex": "0"
            ]
        )

        resetHandoffForUserPlaybackIntent()

        // Queue injection resets instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        guard let playableQueue = await resolvePlayableQueue(tracks: tracks, preferredStartIndex: 0) else {
            await stop()
            queue = tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
            originalQueue = queue
            currentQueueIndex = 0
            currentTrack = tracks[0]
            let isDeviceOffline = await MainActor.run {
                !networkMonitor.networkState.isConnected || syncCoordinator.isOffline
            }
            let isCellularStreamingDisabled = await MainActor.run {
                !isDeviceOffline && !isPlexStreamingAllowedOnCurrentNetwork()
            }
            playbackState = .failed(Self.noPlayableTracksMessage(
                isDeviceOffline: isDeviceOffline,
                isCellularStreamingDisabled: isCellularStreamingDisabled
            ))
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UserJourneyLogger.log(
                context: "playback",
                event: "startFailed",
                details: [
                    "mode": "shuffle",
                    "origin": context.origin.rawValue,
                    "source": context.source.rawValue,
                    "elapsedMs": "\(elapsedMs)",
                    "reason": "noPlayableTracks",
                    "offline": "\(isDeviceOffline)"
                ]
            )
            return
        }

        // Enable shuffle
        if !isShuffleEnabled {
            isShuffleEnabled = true
            UserDefaults.standard.set(true, forKey: PlaybackPreferenceKey.shuffleEnabled)
        }

        if playableQueue.skippedCount > 0 {
            EnsembleLogger.debug(
                "🎵 Offline shuffle filter applied: requested=\(tracks.count), playable=\(playableQueue.tracks.count), skipped=\(playableQueue.skippedCount)"
            )
        }

        let items = playableQueue.tracks.map { makeQueueItem(track: $0, source: .continuePlaying) }
        originalQueue = items
        hasPendingShuffleReorder = false

        var shuffled = items
        shuffled.shuffle()

        queue = shuffled
        currentQueueIndex = 0
        setQueueProtection(false, reason: "shufflePlay")

        // Clear history for fresh session, preserve overlapping cache entries
        playbackHistory.removeAll()
        queueController.clearAutoGeneratedTrackIds()
        let newTrackIds = Set(playableQueue.tracks.map(\.playbackIdentity))
        await MainActor.run { evictPlayerItemsNotIn(newTrackIds) }

        await playCurrentQueueItem(caller: "shufflePlay")
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        UserJourneyLogger.log(
            context: "playback",
            event: "startPrepared",
            details: [
                "mode": "shuffle",
                "origin": context.origin.rawValue,
                "source": context.source.rawValue,
                "elapsedMs": "\(elapsedMs)",
                "queueCount": "\(queue.count)",
                "startIndex": "0"
            ]
        )
        savePlaybackState()
        await donatePlaybackStartIfNeeded(
            context: context,
            fallbackTrack: queue.first?.track,
            shuffle: true
        )

        schedulePostPlaybackAutoplayRefresh()
    }

    func resolvePlayableQueue(
        tracks: [Track],
        preferredStartIndex: Int
    ) async -> (tracks: [Track], startIndex: Int, skippedCount: Int)? {
        guard !tracks.isEmpty else { return nil }
        let clampedStartIndex = min(max(preferredStartIndex, 0), tracks.count - 1)
        let (isDeviceOffline, plexStreamingAllowed) = await MainActor.run {
            (
                !networkMonitor.networkState.isConnected || syncCoordinator.isOffline,
                isPlexStreamingAllowedOnCurrentNetwork()
            )
        }
        let requiresDownloadedPlexTrack = isDeviceOffline || !plexStreamingAllowed

        // Check per-server availability for the tracks in the queue.
        // Even when the device has network, individual servers may be offline.
        let hasUnavailableTracks: Bool
        if requiresDownloadedPlexTrack {
            hasUnavailableTracks = false
        } else {
            hasUnavailableTracks = await MainActor.run {
                tracks.contains { track in
                    !isTrackPlayableNow(track, plexStreamingAllowed: plexStreamingAllowed)
                }
            }
        }

        // When all servers are available and device is online, keep queue unchanged.
        guard requiresDownloadedPlexTrack || hasUnavailableTracks else {
            return (tracks: tracks, startIndex: clampedStartIndex, skippedCount: 0)
        }

        var playableTracks: [Track] = []
        var originalPlayableIndices: [Int] = []
        playableTracks.reserveCapacity(tracks.count)
        originalPlayableIndices.reserveCapacity(tracks.count)

        for (index, track) in tracks.enumerated() {
            if track.isAppleMusic {
                playableTracks.append(track)
                originalPlayableIndices.append(index)
            } else if requiresDownloadedPlexTrack {
                // Plex streaming is unavailable under the current network policy.
                if let offlineTrack = await resolveOfflinePlayableTrack(track) {
                    playableTracks.append(offlineTrack)
                    originalPlayableIndices.append(index)
                }
            } else if track.isDownloaded {
                // Downloaded tracks are always playable
                playableTracks.append(track)
                originalPlayableIndices.append(index)
            } else if await MainActor.run(body: {
                isTrackPlayableNow(track, plexStreamingAllowed: plexStreamingAllowed)
            }) {
                // Track's server is online — can stream
                playableTracks.append(track)
                originalPlayableIndices.append(index)
            } else if let cachedTrack = await resolveOfflinePlayableTrack(track) {
                playableTracks.append(cachedTrack)
                originalPlayableIndices.append(index)
            }
            // else: server offline and not downloaded — skip
        }

        guard !playableTracks.isEmpty else { return nil }

        let resolvedStartIndex: Int
        if let indexAtOrAfterSelection = originalPlayableIndices.firstIndex(where: { $0 >= clampedStartIndex }) {
            resolvedStartIndex = indexAtOrAfterSelection
        } else if let indexBeforeSelection = originalPlayableIndices.lastIndex(where: { $0 <= clampedStartIndex }) {
            resolvedStartIndex = indexBeforeSelection
        } else {
            resolvedStartIndex = 0
        }

        return (
            tracks: playableTracks,
            startIndex: resolvedStartIndex,
            skippedCount: tracks.count - playableTracks.count
        )
    }

    func resolveOfflinePlayableTrack(_ track: Track) async -> Track? {
        // track.localFilePath is resolved to a current absolute path by the model mapper.
        if let localFilePath = track.localFilePath,
           FileManager.default.fileExists(atPath: localFilePath)
        {
            return track
        }

        let quality = StreamingQuality(
            rawValue: AudioQualityPreference.storedStreamingQuality()
        ) ?? .high
        if let cachedURL = artifactCache.completedArtifact(
            trackIdentity: track.playbackIdentity,
            sourceFingerprint: PlaybackArtifactKey.sourceFingerprint(for: track),
            requestedQuality: quality.rawValue,
            requireDirect: quality == .original
        ) {
            return track.withLocalFilePath(cachedURL.path)
        }

        guard let sourceCompositeKey = track.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceCompositeKey) != nil else { return nil }
        do {
            if let persistedPath = try await downloadManager.getLocalFilePath(
                forTrackRatingKey: track.id,
                sourceCompositeKey: sourceCompositeKey
            ),
                FileManager.default.fileExists(atPath: persistedPath)
            {
                if persistedPath == track.localFilePath {
                    return track
                }
                return track.withLocalFilePath(persistedPath)
            }
        } catch {
            EnsembleLogger.debug(
                "⚠️ Failed resolving offline playable track \(track.id): \(error.localizedDescription)"
            )
        }

        return nil
    }

    public func playQueueIndex(_ index: Int) async {
        guard index >= 0, index < queue.count else { return }

        // Block playback of tracks from offline servers
        let track = queue[index].track
        let isUnavailable = await MainActor.run {
            !isTrackPlayableNow(track, plexStreamingAllowed: isPlexStreamingAllowedOnCurrentNetwork())
        }
        if isUnavailable { return }

        // Clear scheduled gapless files for the track change
        audioEngine?.clearScheduledFiles()


        // Record current track to history before jumping
        if currentQueueIndex >= 0, currentQueueIndex < queue.count {
            recordToHistory(queue[currentQueueIndex])
        }

        // When jumping forward, record all skipped tracks to history
        // This way tapping "previous" goes back to the skipped tracks, not before the jump
        if index > currentQueueIndex {
            for i in (currentQueueIndex + 1) ..< index {
                if i >= 0, i < queue.count {
                    recordToHistory(queue[i])
                }
            }
        }

        currentQueueIndex = index

        // Don't reset auto-generated tracking - preserve it when jumping within queue
        await playCurrentQueueItem(caller: "jumpToQueueIndex(\(index))")
        savePlaybackState()

        // Check queue after jumping
        await checkAndRefreshAutoplayQueue()
    }

    public func playFromHistory(at historyIndex: Int) async {
        guard historyIndex >= 0, historyIndex < playbackHistory.count else { return }

        let historyItem = playbackHistory[historyIndex]
        let trackId = historyItem.track.playbackIdentity

        EnsembleLogger.debug("🔙 Playing from history: \(historyItem.track.title)")

        // Check if this track already exists in the queue
        if let existingIndex = queue.firstIndex(where: { $0.track.playbackIdentity == trackId }) {
            // Track exists in queue - just navigate to it
            EnsembleLogger.debug("   Found in queue at index \(existingIndex)")

            // Remove tapped item and everything after from history
            playbackHistory.removeSubrange(historyIndex...)
            currentQueueIndex = existingIndex

            await playCurrentQueueItem(caller: "playFromHistory-existing")
            savePlaybackState()
        } else {
            // Track not in queue - insert it at current position
            EnsembleLogger.debug("   Not in queue, inserting at current position")

            // Remove from history
            playbackHistory.remove(at: historyIndex)

            // Insert at current position
            let insertPosition = max(0, currentQueueIndex)
            queue.insert(historyItem, at: insertPosition)
            currentQueueIndex = insertPosition

            await playCurrentQueueItem(caller: "playFromHistory-inserted")
            savePlaybackState()
        }

        await checkAndRefreshAutoplayQueue()
    }

    public func pause() {
        Task { @MainActor [weak self] in
            self?.pauseInternally(source: .user)
        }
    }

    @MainActor
    func pauseInternally(source: PlaybackHandoffCoordinator.CommandSource) {
        let outcome = handoffCoordinator.handle(
            .pauseRequested(source),
            playbackState: playbackState
        )
        applyHandoffOutcome(outcome, event: "pauseRequest(\(source.rawValue))")
    }

    public func resume() {
        Task { @MainActor [weak self] in
            self?.resumeInternally(source: .user)
        }
    }

    @MainActor
    func resumeInternally(source: PlaybackHandoffCoordinator.CommandSource) {
        let outcome = handoffCoordinator.handle(
            .resumeRequested(source),
            playbackState: playbackState
        )
        applyHandoffOutcome(outcome, event: "resumeRequest(\(source.rawValue))")
    }

    @MainActor
    func resumeCore() {
        guard playbackState == .paused || playbackState == .buffering else { return }

        #if os(iOS)
            if #available(iOS 18, *), currentTrack?.isAppleMusic == true {
                let shouldRebuildQueue = pendingPreBufferTime != nil
                    || appleMusicPlaybackController?.activeQueueGeneration == nil
                pendingPreBufferTime = nil
                playbackState = .buffering
                updateNowPlayingInfo()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if shouldRebuildQueue {
                        await playCurrentQueueItem(
                            seekTo: currentTime,
                            caller: "resumeAppleMusic-rebuild"
                        )
                        return
                    }
                    let generation = sessionGeneration
                    do {
                        guard ensureAudioSessionConfigured(mixWithOthers: true) else {
                            throw AppleMusicSourceError.musicKitPlaybackRequired
                        }
                        try await appleMusicPlaybackController?.resume()
                        guard generation == sessionGeneration,
                              currentTrack?.isAppleMusic == true else { return }
                        playbackState = .playing
                        updateNowPlayingInfo()
                    } catch {
                        guard generation == sessionGeneration,
                              currentTrack?.isAppleMusic == true else { return }
                        await playCurrentQueueItem(
                            seekTo: currentTime,
                            caller: "resumeAppleMusic-recovery"
                        )
                    }
                }
                return
            }
        #endif

        // Clear pre-buffer flag — user is taking action now
        pendingPreBufferTime = nil

        // If no track is loaded in the engine (e.g., after state restoration where
        // pre-buffer hasn't completed yet), check if a pre-buffer is in progress.
        if let currentTrack, audioEngine?.currentTrackId != currentTrack.playbackIdentity {
            if let task = preBufferTask {
                // Pre-buffer is downloading — await it instead of starting a duplicate
                playbackState = .buffering
                let generation = sessionGeneration
                Task { @MainActor [weak self] in
                    await task.value
                    guard let self, generation == self.sessionGeneration,
                          self.playbackState == .buffering else { return }
                    self.preBufferTask = nil
                    if self.audioEngine?.currentTrackId == self.currentTrack?.playbackIdentity {
                        do {
                            self.audioEngine?.adoptPlaybackGeneration(self.sessionGeneration)
                            try self.audioEngine?.resume()
                            self.refreshPresentationLatencyEstimate()
                            self.playbackState = .playing
                            self.updateNowPlayingInfo()
                            self.audioAnalyzer.resumeUpdates()
                            Task { await self.prefetchNextItem() }
                            Task { await self.checkAndRefreshAutoplayQueue() }
                            if let track = self.currentTrack {
                                self.reportingController.reportState(
                                    track: track,
                                    state: "playing",
                                    time: self.currentTime
                                )
                            }
                        } catch {
                            EnsembleLogger.playback("ENGINE: resume after pre-buffer failed -- \(error.localizedDescription)")
                            await self.playCurrentQueueItem(seekTo: self.currentTime, caller: "resume-after-prebuffer-fail")
                        }
                    } else {
                        await self.playCurrentQueueItem(seekTo: self.currentTime, caller: "resume-after-prebuffer-fail")
                    }
                }
                return
            }

            // No pre-buffer in progress — start fresh
            Task { @MainActor in
                await playCurrentQueueItem(seekTo: currentTime, caller: "restorePlaybackState")
            }
            return
        }

        #if !os(macOS)
            // Ensure session is active before resuming
            try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif

        // A stale paused stream restarts at the same position instead of resuming
        // into a dead connection; a failure there follows the item-failure rule (G18).
        if pausedStreamNeedsRefresh, audioEngine?.isStreamingSourceActive == true {
            pausedStreamNeedsRefresh = false
            EnsembleLogger.playback("ENGINE: refreshing paused stream at \(String(format: "%.1f", currentTime))s")
            playbackState = .buffering
            let resumeTime = currentTime
            Task { @MainActor in
                await playCurrentQueueItem(seekTo: resumeTime, caller: "resume-refreshStream")
            }
            return
        }

        do {
            guard let audioEngine else {
                playbackState = .failed("Audio engine not initialized")
                updateNowPlayingInfo()
                endTrackTransitionBackgroundTask()
                return
            }
            audioEngine.adoptPlaybackGeneration(sessionGeneration)
            try audioEngine.resume()
            updatePlaybackTimes(rawTime: audioEngine.currentTimeSubject.value.time)
        } catch {
            EnsembleLogger.playback("ENGINE: resume failed -- \(error.localizedDescription)")
            audioEngine?.stop()
            playbackState = .failed(error.localizedDescription)
            updateNowPlayingInfo()
            endTrackTransitionBackgroundTask()
            return
        }
        endTrackTransitionBackgroundTask()
        audioAnalyzer.resumeUpdates()
        refreshPresentationLatencyEstimate()
        playbackState = .playing
        updateNowPlayingInfo()


        // Check queue population on resume
        Task {
            await checkAndRefreshAutoplayQueue()
        }

        // Prefetch upcoming tracks for gapless playback
        Task { await prefetchNextItem() }

        // Report playing state to Plex
        if let track = currentTrack {
            reportingController.reportState(track: track, state: "playing", time: currentTime)
        }
    }

    @MainActor
    public func stop() {
        beginSession()

        // Report stopped state to Plex before cleaning up
        if let track = currentTrack {
            reportingController.reportState(track: track, state: "stopped", time: currentTime)
        }

        // Reset instrumental mode (sync both UI flag and engine state)
        if isInstrumentalModeActive {
            setInstrumentalMode(false)
        }

        #if os(iOS)
            if #available(iOS 18, *) {
                appleMusicPlaybackController?.stop()
            }
        #endif

        // Cancel any in-flight transport work
        transportCoordinator.clear(removeDecisions: false)

        endTrackTransitionBackgroundTask()
        cleanup()
        cancelNowPlayingArtworkLoad(clearArtwork: true)
        currentTrack = nil
        playbackState = .stopped
        updatePlaybackTimes(rawTime: 0)
        bufferedProgress = 0
        queueExhaustedTimestamps.removeAll()
        _ = resolvedFileCache.clear()
        nowPlayingBridge.clearNowPlayingInfo()
    }

    /// Remove deleted tracks from the active queue, original queue, and history.
    /// If the currently playing track was deleted, playback is stopped first so the
    /// audio engine does not hold onto a stale local file.
    @MainActor
    public func removeDeletedTracks(_ trackIdentities: Set<String>) {
        guard !trackIdentities.isEmpty else { return }

        let currentTrackWasDeleted = currentTrack.map { trackIdentities.contains($0.playbackIdentity) } ?? false
        if currentTrackWasDeleted {
            stop()
        }

        queue.removeAll { trackIdentities.contains($0.track.playbackIdentity) }
        originalQueue.removeAll { trackIdentities.contains($0.track.playbackIdentity) }
        playbackHistory.removeAll { trackIdentities.contains($0.track.playbackIdentity) }

        if queue.isEmpty {
            currentQueueIndex = -1
        } else {
            currentQueueIndex = min(currentQueueIndex, queue.count - 1)
        }

        if let currentTrack, trackIdentities.contains(currentTrack.playbackIdentity) {
            self.currentTrack = nil
        }

        commitQueueMutation(refreshAutoplay: false)
    }

    /// Retry playing the current track (useful after network errors)
    public func retryCurrentTrack() async {
        await MainActor.run { clearItemFailureMarkers() }
        await retryCurrentTrack(forceConnectionRefresh: true, reason: "manual")
    }

    @MainActor
    public func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        audioEngine?.cancelSmartMixTransition(continueIncoming: audioEngine?.hasPromotedSmartMixTransition == true)
        let effectiveDur = duration
        let clampedTime = effectiveDur > 0 ? max(0, min(time, effectiveDur)) : max(0, time)
        #if os(iOS)
            if #available(iOS 18, *), currentTrack?.isAppleMusic == true {
                appleMusicEngineAdapter?.noteSeek(to: clampedTime)
                appleMusicPlaybackController?.seek(to: clampedTime)
                updatePlaybackTimes(rawTime: clampedTime)
                updateNowPlayingInfo()
                savePlaybackState()
                return
            }
        #endif
        // A seek during a load applies once the item starts (G5).
        if playbackState == .loading, let itemID = currentQueueItemID {
            pendingSeek = (itemID, clampedTime)
            updatePlaybackTimes(rawTime: clampedTime)
            updateNowPlayingInfo()
            return
        }
        // Seeking to the exact end while paused finishes the item, keeping the pause (G5).
        if playbackState == .paused, effectiveDur > 0, clampedTime >= effectiveDur {
            finishCurrentItemWhilePaused()
            return
        }
        if let trackId = currentTrack?.playbackIdentity {
            PlaybackJourneyLogger.mark("seekRequested", trackId: trackId, detail: "time=\(String(format: "%.2f", clampedTime))")
        }
        do {
            try audioEngine?.seek(to: clampedTime)
            updatePlaybackTimes(rawTime: clampedTime)
            if let trackId = currentTrack?.playbackIdentity {
                PlaybackJourneyLogger.mark("seekCompleted", trackId: trackId, detail: "time=\(String(format: "%.2f", clampedTime))")
            }
            updateNowPlayingInfo()
            savePlaybackState()
        } catch {
            if (error as? AudioPlaybackEngineError) == .streamingSeekUnavailable {
                EnsembleLogger.playback("ENGINE: seek requires stream restart at \(String(format: "%.2f", clampedTime))s")
                let shouldStartPlayback = playbackState == .loading
                    ? playbackPreparationShouldStart : playbackState != .paused
                let generation = sessionGeneration
                Task { @MainActor [weak self] in
                    guard let self, generation == self.sessionGeneration else { return }
                    await self.playCurrentQueueItem(
                        forcingFreshItem: false,
                        seekTo: clampedTime,
                        shouldStartPlayback: shouldStartPlayback,
                        caller: "seek(stream-restart)"
                    )
                }
                return
            }
            EnsembleLogger.playback("ENGINE: seek failed -- \(error.localizedDescription)")
        }
    }

    /// The end-of-track rule, applied without starting playback.
    @MainActor
    func finishCurrentItemWhilePaused() {
        switch queueAdvance(.naturalEnd) {
        case .repeatCurrent:
            selectQueueItemWhilePaused(at: currentQueueIndex, caller: "seekToEnd-repeatOne")
        case let .item(index, _):
            recordCurrentAndSkippedTracksBeforeJump(to: index)
            selectQueueItemWhilePaused(at: index, caller: "seekToEnd")
        case .continuation, .endOfQueue, .unavailable:
            settleAtEndOfQueue(caller: "seekToEnd")
        }
    }
}
