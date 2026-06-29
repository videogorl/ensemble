import Foundation

/// Owns the success path after a playable source has been resolved.
/// Keeps visualizer planning, engine load, recovery seek, and gapless prefetch
/// out of PlaybackService's request/retry loop.
final class PlaybackLaunchCoordinator {
    struct VisualizerPlan: Equatable {
        let priority: TaskPriority
        let throttled: Bool
    }

    struct Dependencies {
        let processorCount: @Sendable () -> Int
        let isVisualizerEnabled: @Sendable () -> Bool
        let isInstrumentalModeActive: @Sendable () -> Bool
        let enqueueVisualizerLoad: @Sendable (Track, URL, VisualizerPlan) -> Void
        let loadAndPlay: @MainActor (PlaybackSource, Track) async -> Void
        let seek: @MainActor (TimeInterval) -> Void
        let prefetchNext: @Sendable () async -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func visualizerPlan(
        isVisualizerEnabled: Bool,
        isInstrumentalModeActive: Bool,
        processorCount: Int
    ) -> VisualizerPlan? {
        guard isVisualizerEnabled else { return nil }

        let isLowCoreDevice = processorCount <= 2
        let throttled = isInstrumentalModeActive || isLowCoreDevice
        let priority: TaskPriority
        if isInstrumentalModeActive {
            priority = .background
        } else if isLowCoreDevice {
            priority = .utility
        } else {
            priority = .userInitiated
        }

        return VisualizerPlan(priority: priority, throttled: throttled)
    }

    func completeLaunch(
        for track: Track,
        source: PlaybackSource,
        recoverySeekTime: TimeInterval?
    ) async {
        if let fileURL = source.fileURL {
            if let plan = Self.visualizerPlan(
                isVisualizerEnabled: dependencies.isVisualizerEnabled(),
                isInstrumentalModeActive: dependencies.isInstrumentalModeActive(),
                processorCount: dependencies.processorCount()
            ) {
                dependencies.enqueueVisualizerLoad(track, fileURL, plan)
            } else {
                EnsembleLogger.debug("[Visualizer] Skipped: isVisualizerEnabled=false")
            }
        } else {
            EnsembleLogger.debug("[Visualizer] Streaming source uses live PCM until cache analysis completes")
        }

        await dependencies.loadAndPlay(source, track)

        if source.fileURL != nil, let recoverySeekTime, recoverySeekTime > 0 {
            await MainActor.run {
                dependencies.seek(recoverySeekTime)
            }
            EnsembleLogger.debug("[playCurrentQueueItem] Recovered position at \(recoverySeekTime)s")
        }

        Task {
            await dependencies.prefetchNext()
        }
    }
}
