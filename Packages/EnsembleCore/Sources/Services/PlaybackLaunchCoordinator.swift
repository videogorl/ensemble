import Foundation

/// Owns the success path after a playable source has been resolved.
/// Keeps visualizer planning, engine load, recovery seek, and gapless prefetch
/// out of PlaybackService's request/retry loop.
final class PlaybackLaunchCoordinator {
    struct VisualizerPlan: Equatable {
        let priority: TaskPriority
        let throttled: Bool
        let startDelayNanoseconds: UInt64

        init(priority: TaskPriority, throttled: Bool, startDelayNanoseconds: UInt64 = 0) {
            self.priority = priority
            self.throttled = throttled
            self.startDelayNanoseconds = startDelayNanoseconds
        }
    }

    enum VisualizerLoadContext {
        case activePlayback
        case scheduledPrefetch
        case restoredPrebuffer
        case userVisibleToggle
    }

    struct Dependencies {
        let processorCount: @Sendable () -> Int
        let isVisualizerEnabled: @Sendable () -> Bool
        let isInstrumentalModeActive: @Sendable () -> Bool
        let enqueueVisualizerLoad: @Sendable (Track, URL, VisualizerPlan) -> Void
        let loadAndPlay: @MainActor (PlaybackSource, Track, UInt64) async -> Bool
        let seek: @MainActor (TimeInterval, UInt64) -> Bool
        let prefetchNext: @Sendable () async -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func visualizerPlan(
        isVisualizerEnabled: Bool,
        isInstrumentalModeActive: Bool,
        processorCount: Int,
        context: VisualizerLoadContext = .activePlayback
    ) -> VisualizerPlan? {
        guard isVisualizerEnabled else { return nil }

        let isLowCoreDevice = processorCount <= 2
        let throttled = isInstrumentalModeActive || isLowCoreDevice
        let priority: TaskPriority
        if isInstrumentalModeActive {
            priority = .background
        } else if isLowCoreDevice {
            switch context {
            case .activePlayback, .userVisibleToggle:
                priority = .utility
            case .scheduledPrefetch, .restoredPrebuffer:
                priority = .background
            }
        } else {
            switch context {
            case .activePlayback, .userVisibleToggle:
                priority = .userInitiated
            case .scheduledPrefetch, .restoredPrebuffer:
                priority = .utility
            }
        }

        let startDelayNanoseconds: UInt64 = context == .scheduledPrefetch && throttled
            ? 10_000_000_000
            : 0

        return VisualizerPlan(
            priority: priority,
            throttled: throttled,
            startDelayNanoseconds: startDelayNanoseconds
        )
    }

    func completeLaunch(
        for track: Track,
        source: PlaybackSource,
        recoverySeekTime: TimeInterval?,
        generation: UInt64
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

        guard await dependencies.loadAndPlay(source, track, generation) else { return }

        if source.fileURL != nil, let recoverySeekTime, recoverySeekTime > 0 {
            guard await dependencies.seek(recoverySeekTime, generation) else { return }
            EnsembleLogger.debug("[playCurrentQueueItem] Recovered position at \(recoverySeekTime)s")
        }

        Task { await dependencies.prefetchNext() }
    }
}
