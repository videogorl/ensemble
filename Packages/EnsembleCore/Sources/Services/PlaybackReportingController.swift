import Foundation

/// Owns playback timeline reporting and scrobble gating outside PlaybackService.
final class PlaybackReportingController {
    typealias TimelineReporter = (Track, String, TimeInterval) async throws -> Void
    typealias TrackScrobbler = (Track) async -> Void

    private let defaults: UserDefaults
    private let reportTimelineThrowing: TimelineReporter
    private let fallbackScrobbler: TrackScrobbler
    private var mutationCoordinator: MutationCoordinator?
    private var lastTimelineReportTime: TimeInterval = 0
    private var consecutiveTimelineFailures = 0
    private var hasScrobbled = false

    init(syncCoordinator: SyncCoordinator, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.reportTimelineThrowing = { track, state, time in
            try await syncCoordinator.reportTimelineThrowing(track: track, state: state, time: time)
        }
        self.fallbackScrobbler = { track in
            await syncCoordinator.scrobbleTrack(track)
        }
    }

    init(
        defaults: UserDefaults = .standard,
        reportTimelineThrowing: @escaping TimelineReporter,
        fallbackScrobbler: @escaping TrackScrobbler
    ) {
        self.defaults = defaults
        self.reportTimelineThrowing = reportTimelineThrowing
        self.fallbackScrobbler = fallbackScrobbler
    }

    func setMutationCoordinator(_ coordinator: MutationCoordinator) {
        mutationCoordinator = coordinator
    }

    func resetForTrack() {
        lastTimelineReportTime = 0
        consecutiveTimelineFailures = 0
        hasScrobbled = false
    }

    func reportState(track: Track?, state: String, time: TimeInterval) {
        guard let track else { return }
        let reportTimelineThrowing = self.reportTimelineThrowing
        Task {
            try? await reportTimelineThrowing(track, state, time)
        }
    }

    func observePlayingProgress(
        track: Track?,
        time: TimeInterval,
        duration: TimeInterval,
        isNetworkConnected: Bool
    ) {
        reportPlayingTimelineIfNeeded(track: track, time: time, isNetworkConnected: isNetworkConnected)
        scrobbleIfNeeded(track: track, time: time, duration: duration)
    }

    private func reportPlayingTimelineIfNeeded(
        track: Track?,
        time: TimeInterval,
        isNetworkConnected: Bool
    ) {
        guard let track, isNetworkConnected else { return }
        let backoffInterval = currentTimelineBackoffInterval
        guard time - lastTimelineReportTime >= backoffInterval else { return }

        lastTimelineReportTime = time
        let reportTimelineThrowing = self.reportTimelineThrowing
        Task { [weak self] in
            do {
                try await reportTimelineThrowing(track, "playing", time)
                self?.consecutiveTimelineFailures = 0
            } catch {
                self?.consecutiveTimelineFailures += 1
            }
        }
    }

    private func scrobbleIfNeeded(track: Track?, time: TimeInterval, duration: TimeInterval) {
        guard !hasScrobbled,
              SettingsManager.effectiveScrobblingEnabled(in: defaults),
              let track,
              duration > 0,
              time / duration >= Self.scrobbleCompletionThreshold else {
            return
        }

        hasScrobbled = true
        let mutationCoordinator = self.mutationCoordinator
        let fallbackScrobbler = self.fallbackScrobbler
        Task {
            if let mutationCoordinator {
                await mutationCoordinator.scrobbleTrack(track)
            } else {
                await fallbackScrobbler(track)
            }
        }
    }

    private var currentTimelineBackoffInterval: TimeInterval {
        if consecutiveTimelineFailures >= 4 {
            return 60.0
        } else if consecutiveTimelineFailures >= 2 {
            return 30.0
        } else {
            return 10.0
        }
    }

    private static let scrobbleCompletionThreshold = 0.9
}
