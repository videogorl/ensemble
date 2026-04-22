import Foundation

/// Centralizes disconnect/interruption/remote-command policy for playback handoff.
/// The coordinator is decision-only: PlaybackService owns all side effects.
struct PlaybackHandoffCoordinator {
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
    }

    enum Action: Equatable, Sendable {
        case refreshPresentationLatency
        case setRouteChangeInProgress(Bool)
        case setInterrupted(Bool)
        case pausePlayback(PauseReason)
        case beginInterruption
        case scheduleSettleWindow(until: Date)
        case resumePlayback(CommandSource)
    }

    struct Outcome: Equatable, Sendable {
        var actions: [Action]
        var summary: String
        var state: State
    }

    private(set) var state = State()
    private let disconnectInterruptionWindow: TimeInterval = 1.0

    mutating func handlePauseRequest(
        source: CommandSource,
        playbackState: PlaybackState
    ) -> Outcome {
        let pauseReason: PauseReason = (source == .user) ? .user : .system
        state.pauseReason = pauseReason
        state.interruption = .none

        guard playbackState == .playing || playbackState == .buffering else {
            return makeOutcome(summary: "pause ignored", actions: [])
        }

        return makeOutcome(summary: "pause playback", actions: [.pausePlayback(pauseReason)])
    }

    mutating func handleResumeRequest(
        source: CommandSource,
        playbackState: PlaybackState
    ) -> Outcome {
        guard playbackState == .paused || playbackState == .buffering else {
            return makeOutcome(summary: "resume ignored", actions: [])
        }

        if case .began = state.interruption, source == .system {
            return makeOutcome(summary: "resume suppressed during active interruption", actions: [])
        }

        state.interruption = .none
        state.routeTransition = .idle
        state.pauseReason = nil

        return makeOutcome(
            summary: "resume playback",
            actions: [
                .setInterrupted(false),
                .setRouteChangeInProgress(false),
                .resumePlayback(source)
            ]
        )
    }

    mutating func handleRouteChange(
        reason: RouteEventReason,
        now: Date,
        settleUntil: Date?,
        playbackState: PlaybackState
    ) -> Outcome {
        switch reason {
        case .oldDeviceUnavailable:
            guard playbackState == .playing || playbackState == .buffering else {
                return makeOutcome(
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
                    summary: "new device without settle window",
                    actions: [
                        .refreshPresentationLatency,
                        .setRouteChangeInProgress(false)
                    ]
                )
            }
            state.routeTransition = .settlingNewDevice(until: settleUntil)
            return makeOutcome(
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
                summary: "non-handoff route change",
                actions: [
                    .refreshPresentationLatency,
                    .setRouteChangeInProgress(false)
                ]
            )
        }
    }

    mutating func handleSettleWindowFinished(
        now: Date,
        playbackState: PlaybackState
    ) -> Outcome {
        guard case .settlingNewDevice(let until) = state.routeTransition else {
            return makeOutcome(summary: "settle window ignored", actions: [])
        }
        guard now >= until else {
            return makeOutcome(summary: "settle window not due", actions: [])
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

        return makeOutcome(summary: "settle window finished", actions: actions)
    }

    mutating func handleInterruptionBegan(
        now: Date,
        playbackState: PlaybackState
    ) -> Outcome {
        if case .disconnecting(let startedAt) = state.routeTransition,
           now.timeIntervalSince(startedAt) < disconnectInterruptionWindow {
            return makeOutcome(summary: "interruption suppressed as disconnect duplicate", actions: [])
        }

        state.interruption = .began
        state.pauseReason = .interruption

        var actions: [Action] = [.setInterrupted(true)]
        if playbackState == .playing || playbackState == .buffering {
            actions.append(.pausePlayback(.interruption))
        }
        return makeOutcome(summary: "interruption began", actions: actions)
    }

    mutating func handleInterruptionEnded(
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
                return makeOutcome(summary: "interruption ended with resume", actions: actions)
            }

            // If the system says "do not resume", buffering should not remain visible.
            // Move to a stable paused state so the user can intentionally resume.
            state.interruption = .none
            if playbackState == .buffering {
                actions.append(.pausePlayback(.interruption))
                return makeOutcome(summary: "interruption ended without resume (pause)", actions: actions)
            }
            return makeOutcome(summary: "interruption ended without resume", actions: actions)
        }

        if !shouldResume {
            state.interruption = .none
        }

        return makeOutcome(summary: "interruption ended", actions: actions)
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

    private func makeOutcome(summary: String, actions: [Action]) -> Outcome {
        Outcome(actions: actions, summary: summary, state: state)
    }
}
