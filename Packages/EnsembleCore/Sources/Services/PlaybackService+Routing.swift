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

// Audio session, interruptions, route changes, and network transitions.
extension PlaybackService {
    enum PresentationRouteKind: Equatable {
        case builtInOrWired
        case bluetooth
        case airPlay
    }

    struct NetworkTransitionDecision: Equatable {
        let shouldAutoHealQueue: Bool
        let shouldHandleReconnect: Bool
        let shouldHandleDisconnect: Bool
        let isInterfaceSwitch: Bool
    }

    nonisolated static func inferPresentationRouteKind(
        hasAirPlay: Bool,
        hasBluetooth: Bool,
        isScreenMirroringActive: Bool = false
    ) -> PresentationRouteKind {
        if hasAirPlay {
            // During screen mirroring, AVAudioSession reports .airPlay because
            // audio routes through the mirroring stream. But the mirroring
            // protocol syncs audio and video together — no separate audio
            // pipeline delay exists. Suppress AirPlay latency compensation
            // so lyrics stay in sync on the TV.
            if isScreenMirroringActive { return .builtInOrWired }
            return .airPlay
        }
        if hasBluetooth { return .bluetooth }
        return .builtInOrWired
    }

    /// Estimates how far audible output trails transport time for presentation-only UI.
    /// Uses reported latency when available and applies route-specific floors only when
    /// the platform reports implausibly small values for delayed external routes.
    nonisolated static func estimatedPresentationLatency(
        routeKind: PresentationRouteKind,
        reportedOutputLatency: TimeInterval,
        ioBufferDuration: TimeInterval
    ) -> TimeInterval {
        let sanitizedOutputLatency = max(0, reportedOutputLatency)
        let sanitizedIOBufferDuration = max(0, ioBufferDuration)
        let measuredLatency = sanitizedOutputLatency + sanitizedIOBufferDuration

        switch routeKind {
        case .builtInOrWired:
            return 0
        case .bluetooth:
            let fallbackBluetoothLatency: TimeInterval = 0.22
            let compensatedLatency = measuredLatency >= 0.08 ? measuredLatency : fallbackBluetoothLatency
            return min(max(0, compensatedLatency), 0.75)
        case .airPlay:
            let fallbackAirPlayLatency: TimeInterval = 1.75
            let compensatedLatency = measuredLatency >= 0.35 ? measuredLatency : fallbackAirPlayLatency
            return min(max(0, compensatedLatency), 2.5)
        }
    }

    nonisolated static func resolvedPresentationTime(
        rawTime: TimeInterval,
        playbackState: PlaybackState,
        effectiveLatency: TimeInterval
    ) -> TimeInterval {
        let clampedRawTime = max(0, rawTime)
        guard playbackState == .playing else { return clampedRawTime }
        return max(0, clampedRawTime - max(0, effectiveLatency))
    }

    nonisolated static func evaluateNetworkTransition(from previous: NetworkState?, to current: NetworkState) -> NetworkTransitionDecision {
        let previousIsConnected = previous?.isConnected ?? false
        let currentIsConnected = current.isConnected
        let didReconnect = !previousIsConnected && currentIsConnected
        let didDisconnect = previousIsConnected && !currentIsConnected

        let previousNetworkType: NetworkType?
        if case let .online(type) = previous {
            previousNetworkType = type
        } else {
            previousNetworkType = nil
        }

        let currentNetworkType: NetworkType?
        if case let .online(type) = current {
            currentNetworkType = type
        } else {
            currentNetworkType = nil
        }

        let isInterfaceSwitch = previousNetworkType != nil
            && currentNetworkType != nil
            && previousNetworkType != currentNetworkType
        let shouldRefreshConnection = didReconnect || isInterfaceSwitch

        return NetworkTransitionDecision(
            shouldAutoHealQueue: shouldRefreshConnection,
            shouldHandleReconnect: didReconnect,
            shouldHandleDisconnect: didDisconnect,
            isInterfaceSwitch: isInterfaceSwitch
        )
    }

    /// Resolve the latest reachability value on the main actor for transport work
    /// that executes behind a Sendable async dependency surface.
    @MainActor
    func currentTransportNetworkState() -> NetworkState {
        networkMonitor.networkState
    }

    @MainActor
    func isTransportNetworkConstrained() -> Bool {
        networkMonitor.isConstrained
    }

    @MainActor
    func isPlexStreamingAllowedOnCurrentNetwork() -> Bool {
        if case .online(.cellular) = networkMonitor.networkState {
            return AudioQualityPreference.storedAllowStreamingOnCellular()
        }
        return networkMonitor.networkState != .offline && networkMonitor.networkState != .limited
    }

    /// Whether the audio session category has been configured.
    func setupAudioSession() {
        #if !os(macOS)
            audioSessionCoordinator.startObserving(
                onInterruption: { [weak self] notification in
                    self?.handleAudioSessionInterruption(notification)
                },
                onRouteChange: { [weak self] notification in
                    self?.handleAudioSessionRouteChange(notification)
                }
            )
        #endif
    }

    /// Configure the audio session category. Called lazily before first playback.
    /// AVPlayer activates the session automatically when playback starts, so
    /// we only need to set the category/mode/options here.
    /// Safe to call multiple times — reconfigures only when the mixing mode changes.
    ///
    /// Returns `true` if the category was successfully configured (or was already
    /// configured from a prior call). Returns `false` if `setCategory` failed
    /// (e.g. Code=-50 on iOS 26 when the audio system isn't ready yet).
    /// Callers that need the category set (like the Siri flow) can retry.
    @discardableResult
    public func ensureAudioSessionConfigured(mixWithOthers: Bool = false) -> Bool {
        #if !os(macOS)
            return audioSessionCoordinator.ensureConfigured(mixWithOthers: mixWithOthers) { [weak self] in
                self?.refreshPresentationLatencyEstimate()
            }
        #else
            return true
        #endif
    }

    /// Ask the system to prepare route selection before Siri/HomePod playback.
    public func preparePlaybackRouteSelection() async -> Bool {
        #if !os(macOS)
            return await audioSessionCoordinator.prepareRouteSelectionForPlayback()
        #else
            return true
        #endif
    }

    /// Activate the playback session after route selection completes.
    public func activatePlaybackAudioSession(shouldStartPlayback: Bool) async {
        #if !os(macOS)
            await audioSessionCoordinator.activateForPlayback(shouldStartPlayback: shouldStartPlayback)
            refreshPresentationLatencyEstimate()
        #endif
    }

    /// Current route description for Siri flow logging and startup diagnostics.
    public func currentAudioRouteDescription() -> String {
        #if !os(macOS)
            return audioSessionCoordinator.currentRouteDescription()
        #else
            return ""
        #endif
    }

    var currentPresentationRouteKindDescription: String {
        String(describing: presentationRouteKind)
    }

    var isAudioSessionConfiguredForDiagnostics: Bool {
        audioSessionCoordinator.isConfiguredForDiagnostics
    }

    var currentPauseReason: PlaybackHandoffCoordinator.PauseReason? {
        handoffCoordinator.state.pauseReason
    }

    var shouldSuppressAutomaticAdvanceDuringHandoff: Bool {
        handoffCoordinator.shouldSuppressAutomaticAdvance
    }

    func syncHandoffStateWithPlaybackState() {
        switch playbackState {
        case .playing:
            _ = handoffCoordinator.handle(.playbackStarted, playbackState: playbackState)
        case .stopped, .failed:
            _ = handoffCoordinator.handle(.playbackStopped, playbackState: playbackState)
        default:
            break
        }
    }

    func handoffStateSnapshot() -> String {
        let pauseReason = currentPauseReason?.rawValue ?? "none"
        let interruption = handoffCoordinator.state.interruption.logValue
        let routeTransition = handoffCoordinator.state.routeTransition.logValue
        let trackID = currentTrack?.id ?? "nil"
        let trackTitle = currentTrack?.title ?? "nil"
        return "pauseReason=\(pauseReason) interruption=\(interruption) routeTransition=\(routeTransition) playbackState=\(playbackState) trackId=\(trackID) track='\(trackTitle)' time=\(String(format: "%.1f", currentTime)) routeKind=\(presentationRouteKind)"
    }

    #if os(iOS) || os(tvOS) || os(watchOS)
        func routeChangeReasonDescription(_ reason: AVAudioSession.RouteChangeReason) -> String {
            switch reason {
            case .unknown:
                return "unknown"
            case .newDeviceAvailable:
                return "newDeviceAvailable"
            case .oldDeviceUnavailable:
                return "oldDeviceUnavailable"
            case .categoryChange:
                return "categoryChange"
            case .override:
                return "override"
            case .wakeFromSleep:
                return "wakeFromSleep"
            case .noSuitableRouteForCategory:
                return "noSuitableRouteForCategory"
            case .routeConfigurationChange:
                return "routeConfigurationChange"
            @unknown default:
                return "unknown(\(reason.rawValue))"
            }
        }

        func handoffRouteEventReason(
            from reason: AVAudioSession.RouteChangeReason
        ) -> PlaybackHandoffCoordinator.RouteEventReason {
            switch reason {
            case .oldDeviceUnavailable:
                return .oldDeviceUnavailable
            case .newDeviceAvailable:
                return .newDeviceAvailable
            default:
                return .other
            }
        }
    #endif

    func logHandoff(event: String, outcome: PlaybackHandoffCoordinator.Outcome) {
        let actionSummary = outcome.actions.map { "\($0)" }.joined(separator: ",")
        EnsembleLogger.debug(
            "[Handoff] category=\(outcome.category.rawValue) "
                + "event=\(event) summary=\(outcome.summary) actions=[\(actionSummary)] "
                + "\(handoffStateSnapshot())"
        )
    }

    @MainActor
    func applyHandoffOutcome(
        _ outcome: PlaybackHandoffCoordinator.Outcome,
        event: String
    ) {
        logHandoff(event: event, outcome: outcome)

        for action in outcome.actions {
            switch action {
            case .refreshPresentationLatency:
                refreshPresentationLatencyEstimate()

            case let .pausePlayback(reason):
                applyPauseForHandoff(reason: reason)

            case let .scheduleSettleWindow(until):
                handoffSettleTask?.cancel()
                handoffSettleTask = Task { @MainActor [weak self] in
                    let duration = max(0, until.timeIntervalSinceNow)
                    if duration > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    }
                    guard let self, !Task.isCancelled else { return }
                    let settleOutcome = self.handoffCoordinator.handle(
                        .settleWindowFinished(now: Date()),
                        playbackState: self.playbackState
                    )
                    self.applyHandoffOutcome(settleOutcome, event: "settleWindowFinished")
                    EnsembleLogger.debug("🎧 Route handover settle window finished; pause counters reset")
                }

            case let .resumePlayback(source):
                applyResumeForHandoff(source: source)
            }
        }
    }

    @MainActor
    func applyPauseForHandoff(reason: PlaybackHandoffCoordinator.PauseReason) {
        let wasActive = playbackState == .playing || playbackState == .buffering
        guard wasActive || reason == .user || reason == .system else { return }
        // Pausing a load cancels it; pausing playback keeps the session.
        if playbackState == .loading || playbackState == .buffering {
            beginSession()
        }
        skipTransitionTask?.cancel()
        skipTransitionTask = nil

        #if os(iOS)
            if #available(iOS 18, *), currentTrack?.isAppleMusic == true {
                appleMusicPlaybackController?.pause()
            } else {
                audioEngine?.pause()
            }
        #else
            audioEngine?.pause()
        #endif
        if let engine = audioEngine, currentTrack?.isAppleMusic != true,
           engine.currentTrackId == currentTrack?.playbackIdentity {
            updatePlaybackTimes(rawTime: engine.currentTimeSubject.value.time)
        }
        playbackState = .paused
        updateNowPlayingInfo()

        Task { @MainActor in
            audioAnalyzer.pauseUpdates()
        }

        if let track = currentTrack {
            reportingController.reportState(track: track, state: "paused", time: currentTime)
        }

        if reason == .user || reason == .system {
            Task {
                await checkAndRefreshAutoplayQueue()
            }
        }
        endTrackTransitionBackgroundTask()
    }

    @MainActor
    func applyResumeForHandoff(source: PlaybackHandoffCoordinator.CommandSource) {
        EnsembleLogger.debug("[Handoff] executing resume for source=\(source.rawValue)")
        resumeCore()
    }

    func shouldAcceptRemoteSkipCommand() -> Bool {
        let now = CACurrentMediaTime()
        guard handoffCoordinator.remoteSkipCommandsEnabled(playbackState: playbackState) else {
            EnsembleLogger.debug(
                "[Handoff] remote skip ignored — playbackState=\(playbackState), pauseReason=\(currentPauseReason?.rawValue ?? "none"), interruption=\(handoffCoordinator.state.interruption.logValue), routeTransition=\(handoffCoordinator.state.routeTransition.logValue)"
            )
            return false
        }

        if now - lastRemoteSkipTime < 0.3 {
            return false
        }

        lastRemoteSkipTime = now
        return true
    }

    @MainActor
    func handleAudioSessionInterruption(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard let userInfo = notification.userInfo,
                  let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else {
                return
            }

            #if os(iOS)
                if #available(iOS 18, *) {
                    appleMusicPlaybackController?.setInterruptionActive(type == .began)
                    if currentTrack?.isAppleMusic == true {
                        EnsembleLogger.debug(
                            "[Playback] MusicKit owns interruption type=\(type.rawValue)"
                                + " route=\(currentAudioRouteDescription())"
                        )
                        return
                    }
                }
            #endif

            switch type {
            case .began:
                let outcome = handoffCoordinator.handle(
                    .interruptionBegan(now: Date()),
                    playbackState: playbackState
                )
                applyHandoffOutcome(outcome, event: "interruptionBegan")

            case .ended:
                guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                let outcome = handoffCoordinator.handle(
                    .interruptionEnded(shouldResume: options.contains(.shouldResume)),
                    playbackState: playbackState
                )
                applyHandoffOutcome(outcome, event: "interruptionEnded")

            @unknown default:
                break
            }
        #endif
    }

    @MainActor
    func handleAudioSessionRouteChange(_ notification: Notification) {
        #if os(iOS) || os(tvOS) || os(watchOS)
            guard let userInfo = notification.userInfo,
                  let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
            else {
                return
            }

            #if os(iOS)
                if #available(iOS 18, *),
                   currentTrack?.isAppleMusic == true,
                   appleMusicPlaybackController?.activeQueueGeneration != nil
                {
                    refreshPresentationLatencyEstimate()
                    EnsembleLogger.debug(
                        "[Playback] MusicKit owns route change \(routeChangeReasonDescription(reason))"
                            + " queueGeneration=\(appleMusicPlaybackController?.activeQueueGeneration ?? 0)"
                            + " route=\(currentAudioRouteDescription())"
                    )
                    return
                }
            #endif

            audioEngine?.prepareForRouteChange()

            let now = Date()
            let settleUntil: Date?
            if reason == .newDeviceAvailable {
                let newOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let isAirPlay = newOutputs.contains { $0.portType == .airPlay }
                let settleDuration: TimeInterval = isAirPlay ? 4 : 2
                settleUntil = now.addingTimeInterval(settleDuration)
            } else {
                settleUntil = nil
            }

            let outcome = handoffCoordinator.handle(
                .routeChanged(
                    reason: handoffRouteEventReason(from: reason),
                    now: now,
                    settleUntil: settleUntil
                ),
                playbackState: playbackState
            )
            applyHandoffOutcome(outcome, event: "routeChange(\(routeChangeReasonDescription(reason)))")
        #endif
    }

    /// Nudges the player to commit its audio to the current audio session route.
    /// Used by the Siri HomePod path when an AirPlay route appears after playback
    /// has already started on the local device. Unlike `resume()`, this works even
    /// when `playbackState == .playing` — it resets the pause loop counters and
    /// re-invokes `player.play()` so AVQueuePlayer re-negotiates its output to the
    /// new route without interrupting the user-visible state.
    @MainActor
    public func nudgeForAirPlayRoute() {
        guard currentTrack != nil, audioEngine?.currentTrackId != nil else {
            EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: no active track, skipping")
            return
        }
        // Reset pause loop counters for the new route
        EnsembleLogger.debug("🎧 nudgeForAirPlayRoute: state=\(playbackState) — re-asserting playback on new route")
        // AudioPlaybackEngine handles route changes via AVAudioEngineConfigurationChange
        // notification internally. For paused state, resume normally.
        if playbackState == .paused || playbackState == .buffering {
            resumeInternally(source: .system)
        }
    }

    /// The Mac treats sleep as an interruption that does not resume on its own (G22).
    func setupSystemSleepObservation() {
        #if os(macOS)
            let center = NSWorkspace.shared.notificationCenter
            systemSleepObservers = [
                center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleSystemSleep(isWaking: false) }
                },
                center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.handleSystemSleep(isWaking: true) }
                }
            ]
        #endif
    }

    #if os(macOS)
        @MainActor
        func handleSystemSleep(isWaking: Bool) {
            let signal: PlaybackHandoffCoordinator.Signal = isWaking
                ? .interruptionEnded(shouldResume: false)
                : .interruptionBegan(now: Date())
            let outcome = handoffCoordinator.handle(signal, playbackState: playbackState)
            applyHandoffOutcome(outcome, event: isWaking ? "systemDidWake" : "systemWillSleep")
        }
    #endif

    /// Handles network transitions so queued stream endpoints are refreshed after handoffs.
    @MainActor
    func handleNetworkStateTransition(from previous: NetworkState?, to current: NetworkState) async {
        let decision = Self.evaluateNetworkTransition(from: previous, to: current)
        if playbackState == .paused,
           audioEngine?.isStreamingSourceActive == true,
           decision.isInterfaceSwitch || decision.shouldHandleDisconnect || decision.shouldHandleReconnect {
            pausedStreamNeedsRefresh = true
        }

        EnsembleLogger.debug("🌐 Playback network transition: \(previous?.description ?? "nil") -> \(current.description)")
        if decision.isInterfaceSwitch {
            EnsembleLogger.debug("🌐 Detected interface switch while online")
        }

        // Note: Connection refresh is handled by SyncCoordinator's health checks which
        // also observe network transitions. This avoids duplicate refresh calls.
        // The queue rebuild below will use fresh URLs after health checks complete.

        if decision.shouldAutoHealQueue {
            await rebuildUpcomingQueueForNetworkTransition()
        }

        if decision.shouldHandleReconnect {
            EnsembleLogger.debug("✅ Network reconnected")

            if case .failed = playbackState {
                EnsembleLogger.debug("ℹ️ Skipping reconnect retry — audio engine is already playing from local files")
                return
            } else if playbackState == .buffering {
                EnsembleLogger.debug("🔄 Network back - attempting to resume buffering")
                audioEngine?.adoptPlaybackGeneration(sessionGeneration)
                try? audioEngine?.resume()
            }
        } else if decision.shouldHandleDisconnect {
            EnsembleLogger.debug("⚠️ Network disconnected during playback")
            if currentTrack != nil,
               playbackState == .playing || playbackState == .buffering
            {
                EnsembleLogger.debug("ℹ️ No failure transition needed — audio engine continues from local files")
            }
        }
    }

    /// Rebuilds only upcoming queue items so prefetched entries don't keep stale endpoint URLs.
    /// Already-downloaded gapless files are left alone — the audio engine plays from local files,
    /// so a network transition doesn't invalidate them. Only tracks still being downloaded
    /// (or not yet started) need their URLs evicted and re-resolved.
    ///
    /// Stream decisions in PlaybackTransportCoordinator are intentionally preserved — they're
    /// endpoint-independent (codec, quality, session params) and survive network transitions.
    /// When `prefetchUpcomingItems()` re-resolves, it finds the cached decision and skips
    /// the `/decision` network call, assembling a fresh URL from the updated endpoint.
    @MainActor
    func rebuildUpcomingQueueForNetworkTransition(shouldPrefetch: Bool = true) async {
        let upcomingTrackIDs: [String] = upcomingQueueIndices(depth: 2).map { queue[$0].track.playbackIdentity }

        // Skip tracks already scheduled in the engine — their audio is downloaded and loaded
        let alreadyScheduled = Array(audioEngine?.scheduledTrackIds ?? [])
        let staleTrackIDs = prefetchController.evictUpcomingStaleTrackURLs(
            upcomingTrackIDs: upcomingTrackIDs,
            alreadyScheduledTrackIDs: alreadyScheduled,
            cache: resolvedFileCache,
            evictTransportTrack: { [transportCoordinator] trackId, includeDecision, cancelTask in
                transportCoordinator.evict(
                    trackId: trackId,
                    includeDecision: includeDecision,
                    cancelTask: cancelTask
                )
            }
        )

        if staleTrackIDs.isEmpty {
            EnsembleLogger.debug("[rebuildQueue] Network transition — all upcoming tracks already scheduled, nothing to rebuild")
        } else {
            EnsembleLogger.debug("[rebuildQueue] Evicted \(staleTrackIDs.count) stale URLs, kept \(alreadyScheduled.count) scheduled + \(transportCoordinator.cachedDecisionCount()) decisions")
            if shouldPrefetch {
                await prefetchUpcomingItems(depth: 2)
            }
        }
    }
}
