import Foundation

enum PlaybackRecoveryPolicy {
    struct BufferingProfile: Equatable {
        let waitsToMinimizeStalling: Bool
        let preferredForwardBufferDuration: TimeInterval
        let prefetchDepth: Int
        let stallRecoveryTimeout: TimeInterval
        let label: String

        static let wifiOrWired = BufferingProfile(
            waitsToMinimizeStalling: false,
            preferredForwardBufferDuration: 8,
            prefetchDepth: 1,
            stallRecoveryTimeout: 8,
            label: "wifi/wired"
        )

        static let cellularOrOther = BufferingProfile(
            waitsToMinimizeStalling: true,
            preferredForwardBufferDuration: 18,
            prefetchDepth: 1,
            stallRecoveryTimeout: 12,
            label: "cellular/other"
        )

        static let conservative = BufferingProfile(
            waitsToMinimizeStalling: true,
            preferredForwardBufferDuration: 20,
            prefetchDepth: 1,
            stallRecoveryTimeout: 15,
            label: "conservative"
        )
    }

    struct AdaptiveState {
        var stallTimestamps: [Date] = []
        var conservativeModeUntil: Date?
        var lastRecoveryAttemptAt: Date?
        var conservativeWaitCycles: Int = 0
    }

    static let stallEscalationThreshold = 2
    static let stallEscalationWindow: TimeInterval = 30
    static let conservativeModeDuration: TimeInterval = 120
    static let recoveryCooldown: TimeInterval = 6
    static let prefetchThrottleDuration: TimeInterval = 90
    static let minUnexpectedPauseInterval: TimeInterval = 0.8

    static func baseBufferingProfile(for networkState: NetworkState) -> BufferingProfile {
        switch networkState {
        case .online(.wifi), .online(.wired):
            return .wifiOrWired
        case .online(.cellular), .online(.other), .unknown, .limited, .offline:
            return .cellularOrOther
        }
    }

    static func trimmedStallTimestamps(
        _ timestamps: [Date],
        now: Date,
        window: TimeInterval = stallEscalationWindow
    ) -> [Date] {
        timestamps.filter { now.timeIntervalSince($0) <= window }
    }

    static func shouldEnterConservativeMode(
        stallTimestamps: [Date],
        now: Date,
        threshold: Int = stallEscalationThreshold,
        window: TimeInterval = stallEscalationWindow
    ) -> Bool {
        trimmedStallTimestamps(stallTimestamps, now: now, window: window).count >= threshold
    }

    static func resolvedBufferingProfile(
        for networkState: NetworkState,
        conservativeModeUntil: Date?,
        now: Date
    ) -> BufferingProfile {
        if let conservativeModeUntil, conservativeModeUntil > now {
            return .conservative
        }
        return baseBufferingProfile(for: networkState)
    }

    static func throttledPrefetchProfileIfNeeded(
        _ profile: BufferingProfile,
        throttleActive: Bool
    ) -> BufferingProfile {
        guard throttleActive, profile.prefetchDepth > 1 else { return profile }
        // During transport error throttle, reduce prefetch to 1 (not 0) so
        // AVQueuePlayer always has a next item for gapless transitions.
        return BufferingProfile(
            waitsToMinimizeStalling: profile.waitsToMinimizeStalling,
            preferredForwardBufferDuration: profile.preferredForwardBufferDuration,
            prefetchDepth: 1,
            stallRecoveryTimeout: profile.stallRecoveryTimeout,
            label: "\(profile.label)-prefetch-throttled"
        )
    }

    static func shouldRecordWaitingStallEvent(
        playbackState: PlaybackState,
        isPlaybackBufferEmpty: Bool,
        hasActiveSeek: Bool
    ) -> Bool {
        guard playbackState == .playing else { return false }
        guard !hasActiveSeek else { return false }
        return isPlaybackBufferEmpty
    }

    static func unexpectedPauseRecoveryAction(
        playbackState: PlaybackState,
        isPlaybackLikelyToKeepUp: Bool,
        isPlaybackBufferFull: Bool,
        isPlaybackBufferEmpty: Bool,
        hasActiveSeek: Bool
    ) -> (resumeImmediately: Bool, recordStallEvent: Bool)? {
        switch playbackState {
        case .playing, .buffering, .loading:
            if isPlaybackLikelyToKeepUp || isPlaybackBufferFull {
                return (true, false)
            }
            let shouldRecordStallEvent = !hasActiveSeek && isPlaybackBufferEmpty
            return (false, shouldRecordStallEvent)
        default:
            return nil
        }
    }
}
