import Foundation

/// Centralizes disconnect/interruption/remote-command policy for playback handoff.
/// The coordinator is decision-only: PlaybackService owns all side effects.
struct PlaybackHandoffCoordinator {
    /// Apple exposes playback coordination as separate signal families rather than
    /// one unified state machine. The coordinator normalizes those inputs into a
    /// smaller reducer so PlaybackService doesn't branch on dictation, AirPlay,
    /// Bluetooth, or lock-screen scenarios individually.
    enum SignalCategory: String, Equatable, Sendable {
        case transportCommand
        case audioSessionInterruption
        case audioSessionRouteChange
        case playbackLifecycle
    }

    enum PauseReason: String, Equatable, Sendable {
        case user
        case disconnect
        case interruption
        case system
    }

    enum CommandSource: String, Sendable {
        case user
        case system
    }

    enum RouteEventReason: Equatable, Sendable {
        case oldDeviceUnavailable
        case newDeviceAvailable
        case other
    }

    enum Signal: Equatable, Sendable {
        case pauseRequested(CommandSource)
        case resumeRequested(CommandSource)
        case interruptionBegan(now: Date)
        case interruptionEnded(shouldResume: Bool)
        case routeChanged(reason: RouteEventReason, now: Date, settleUntil: Date?)
        case settleWindowFinished(now: Date)
        case playbackStarted
        case playbackStopped
        case explicitPlaybackStart

        var category: SignalCategory {
            switch self {
            case .pauseRequested, .resumeRequested:
                return .transportCommand
            case .interruptionBegan, .interruptionEnded:
                return .audioSessionInterruption
            case .routeChanged, .settleWindowFinished:
                return .audioSessionRouteChange
            case .playbackStarted, .playbackStopped, .explicitPlaybackStart:
                return .playbackLifecycle
            }
        }
    }

    enum RouteTransitionState: Equatable, Sendable {
        case idle
        case disconnecting(startedAt: Date)
        case settlingNewDevice(until: Date)

        var logValue: String {
            switch self {
            case .idle:
                return "idle"
            case .disconnecting:
                return "disconnecting"
            case .settlingNewDevice:
                return "settlingNewDevice"
            }
        }
    }

    enum InterruptionState: Equatable, Sendable {
        case none
        case began
        case ended(shouldResume: Bool)

        var logValue: String {
            switch self {
            case .none:
                return "none"
            case .began:
                return "began"
            case .ended(let shouldResume):
                return "ended(shouldResume=\(shouldResume))"
            }
        }
    }

    struct State: Equatable, Sendable {
        var pauseReason: PauseReason?
        var routeTransition: RouteTransitionState = .idle
        var interruption: InterruptionState = .none

        var hasActiveInterruptionSignal: Bool {
            switch interruption {
            case .none:
                return false
            case .began, .ended:
                return true
            }
        }

        var hasActiveRouteTransitionSignal: Bool {
            switch routeTransition {
            case .idle:
                return false
            case .disconnecting, .settlingNewDevice:
                return true
            }
        }

        var hasSystemManagedPause: Bool {
            pauseReason == .disconnect || pauseReason == .interruption
        }
    }

    enum Action: Equatable, Sendable {
        case refreshPresentationLatency
        case setRouteChangeInProgress(Bool)
        case setInterrupted(Bool)
        case pausePlayback(PauseReason)
        case scheduleSettleWindow(until: Date)
        case resumePlayback(CommandSource)
    }

    struct Outcome: Equatable, Sendable {
        var category: SignalCategory
        var actions: [Action]
        var summary: String
        var state: State
    }

    private(set) var state = State()
    private let disconnectInterruptionWindow: TimeInterval = 1.0

    mutating func handle(_ signal: Signal, playbackState: PlaybackState) -> Outcome {
        switch signal {
        case .pauseRequested(let source):
            return handlePauseRequest(source: source, playbackState: playbackState)
        case .resumeRequested(let source):
            return handleResumeRequest(source: source, playbackState: playbackState)
        case .interruptionBegan(let now):
            return handleInterruptionBegan(now: now, playbackState: playbackState)
        case .interruptionEnded(let shouldResume):
            return handleInterruptionEnded(shouldResume: shouldResume, playbackState: playbackState)
        case .routeChanged(let reason, let now, let settleUntil):
            return handleRouteChange(
                reason: reason,
                now: now,
                settleUntil: settleUntil,
                playbackState: playbackState
            )
        case .settleWindowFinished(let now):
            return handleSettleWindowFinished(now: now, playbackState: playbackState)
        case .playbackStarted:
            handlePlaybackStarted()
            return makeOutcome(category: signal.category, summary: "playback started", actions: [])
        case .playbackStopped:
            handlePlaybackStopped()
            return makeOutcome(category: signal.category, summary: "playback stopped", actions: [])
        case .explicitPlaybackStart:
            resetForExplicitPlaybackStart()
            return makeOutcome(category: signal.category, summary: "explicit playback start", actions: [])
        }
    }

    func shouldSuppressAutomaticAdvance(
        isInterrupted: Bool,
        isRouteChangeInProgress: Bool
    ) -> Bool {
        if isInterrupted || isRouteChangeInProgress {
            return true
        }

        return state.hasActiveInterruptionSignal
            || state.hasActiveRouteTransitionSignal
            || state.hasSystemManagedPause
    }

    func remoteSkipCommandsEnabled(
        playbackState: PlaybackState,
        isInterrupted: Bool,
        isRouteChangeInProgress: Bool
    ) -> Bool {
        guard playbackState != .loading, playbackState != .buffering else {
            return false
        }

        return !shouldSuppressAutomaticAdvance(
            isInterrupted: isInterrupted,
            isRouteChangeInProgress: isRouteChangeInProgress
        )
    }

    private mutating func handlePauseRequest(
        source: CommandSource,
        playbackState: PlaybackState
    ) -> Outcome {
        let pauseReason: PauseReason = (source == .user) ? .user : .system
        state.pauseReason = pauseReason
        state.interruption = .none

        guard playbackState == .playing || playbackState == .buffering else {
            return makeOutcome(category: .transportCommand, summary: "pause ignored", actions: [])
        }

        return makeOutcome(
            category: .transportCommand,
            summary: "pause playback",
            actions: [.pausePlayback(pauseReason)]
        )
    }

    private mutating func handleResumeRequest(
        source: CommandSource,
        playbackState: PlaybackState
    ) -> Outcome {
        guard playbackState == .paused || playbackState == .buffering else {
            return makeOutcome(category: .transportCommand, summary: "resume ignored", actions: [])
        }

        // Interruption-end notifications can arrive late or not at all for some
        // system-driven spoken-audio flows. If the system is already sending a play
        // command, treat that as authoritative resume intent instead of deadlocking
        // playback behind a stale `.began` interruption state.
        state.interruption = .none
        state.routeTransition = .idle
        state.pauseReason = nil

        return makeOutcome(
            category: .transportCommand,
            summary: "resume playback",
            actions: [
                .setInterrupted(false),
                .setRouteChangeInProgress(false),
                .resumePlayback(source)
            ]
        )
    }

    private mutating func handleRouteChange(
        reason: RouteEventReason,
        now: Date,
        settleUntil: Date?,
        playbackState: PlaybackState
    ) -> Outcome {
        switch reason {
        case .oldDeviceUnavailable:
            guard playbackState == .playing || playbackState == .buffering else {
                return makeOutcome(
                    category: .audioSessionRouteChange,
                    summary: "disconnect route change while already paused",
                    actions: [
                        .refreshPresentationLatency,
                        .setRouteChangeInProgress(false)
                    ]
                )
            }
            state.routeTransition = .disconnecting(startedAt: now)
            state.pauseReason = .disconnect
            state.interruption = .none
            return makeOutcome(
                category: .audioSessionRouteChange,
                summary: "disconnect route change",
                actions: [
                    .refreshPresentationLatency,
                    .setRouteChangeInProgress(false),
                    .pausePlayback(.disconnect)
                ]
            )

        case .newDeviceAvailable:
            guard let settleUntil else {
                state.routeTransition = .idle
                return makeOutcome(
                    category: .audioSessionRouteChange,
                    summary: "new device without settle window",
                    actions: [
                        .refreshPresentationLatency,
                        .setRouteChangeInProgress(false)
                    ]
                )
            }
            state.routeTransition = .settlingNewDevice(until: settleUntil)
            return makeOutcome(
                category: .audioSessionRouteChange,
                summary: "new device settle window",
                actions: [
                    .refreshPresentationLatency,
                    .setRouteChangeInProgress(true),
                    .scheduleSettleWindow(until: settleUntil)
                ]
            )

        default:
            state.routeTransition = .idle
            return makeOutcome(
                category: .audioSessionRouteChange,
                summary: "non-handoff route change",
                actions: [
                    .refreshPresentationLatency,
                    .setRouteChangeInProgress(false)
                ]
            )
        }
    }

    private mutating func handleSettleWindowFinished(
        now: Date,
        playbackState: PlaybackState
    ) -> Outcome {
        guard case .settlingNewDevice(let until) = state.routeTransition else {
            return makeOutcome(
                category: .audioSessionRouteChange,
                summary: "settle window ignored",
                actions: []
            )
        }
        guard now >= until else {
            return makeOutcome(
                category: .audioSessionRouteChange,
                summary: "settle window not due",
                actions: []
            )
        }

        state.routeTransition = .idle
        var actions: [Action] = [
            .refreshPresentationLatency,
            .setRouteChangeInProgress(false)
        ]

        // Route handoff can leave AVPlayer stalled in buffering even though the
        // interruption/route transition state is clear. Re-assert playback once
        // the settle window expires so users don't need to tap play manually.
        if playbackState == .buffering,
           (state.pauseReason == nil || state.pauseReason == .disconnect),
           state.interruption == .none {
            state.pauseReason = nil
            actions.append(.resumePlayback(.system))
        }

        return makeOutcome(
            category: .audioSessionRouteChange,
            summary: "settle window finished",
            actions: actions
        )
    }

    private mutating func handleInterruptionBegan(
        now: Date,
        playbackState: PlaybackState
    ) -> Outcome {
        if case .disconnecting(let startedAt) = state.routeTransition,
           now.timeIntervalSince(startedAt) < disconnectInterruptionWindow {
            return makeOutcome(
                category: .audioSessionInterruption,
                summary: "interruption suppressed as disconnect duplicate",
                actions: []
            )
        }

        state.interruption = .began
        state.pauseReason = .interruption

        var actions: [Action] = [.setInterrupted(true)]
        if playbackState == .playing || playbackState == .buffering {
            actions.append(.pausePlayback(.interruption))
        }
        return makeOutcome(
            category: .audioSessionInterruption,
            summary: "interruption began",
            actions: actions
        )
    }

    private mutating func handleInterruptionEnded(
        shouldResume: Bool,
        playbackState: PlaybackState
    ) -> Outcome {
        state.interruption = .ended(shouldResume: shouldResume)

        var actions: [Action] = [.setInterrupted(false)]
        if state.pauseReason == .interruption,
           playbackState == .buffering || playbackState == .paused {
            if shouldResume {
                state.pauseReason = nil
                state.interruption = .none
                actions.append(.resumePlayback(.system))
                return makeOutcome(
                    category: .audioSessionInterruption,
                    summary: "interruption ended with resume",
                    actions: actions
                )
            }

            // If the system says "do not resume", buffering should not remain visible.
            // Move to a stable paused state so the user can intentionally resume.
            state.interruption = .none
            if playbackState == .buffering {
                actions.append(.pausePlayback(.interruption))
                return makeOutcome(
                    category: .audioSessionInterruption,
                    summary: "interruption ended without resume (pause)",
                    actions: actions
                )
            }
            return makeOutcome(
                category: .audioSessionInterruption,
                summary: "interruption ended without resume",
                actions: actions
            )
        }

        if !shouldResume {
            state.interruption = .none
        }

        return makeOutcome(
            category: .audioSessionInterruption,
            summary: "interruption ended",
            actions: actions
        )
    }

    mutating func handlePlaybackStarted() {
        state.pauseReason = nil
        state.interruption = .none
        if case .disconnecting = state.routeTransition {
            state.routeTransition = .idle
        }
    }

    mutating func handlePlaybackStopped() {
        state.pauseReason = nil
        state.interruption = .none
        state.routeTransition = .idle
    }

    mutating func resetForExplicitPlaybackStart() {
        state.pauseReason = nil
        state.interruption = .none
        state.routeTransition = .idle
    }

    private func makeOutcome(
        category: SignalCategory,
        summary: String,
        actions: [Action]
    ) -> Outcome {
        Outcome(category: category, actions: actions, summary: summary, state: state)
    }
}
