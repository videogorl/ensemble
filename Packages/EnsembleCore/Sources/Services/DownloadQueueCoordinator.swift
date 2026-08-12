import Foundation

/// Owns the offline queue task lifecycle so OfflineDownloadService no longer
/// mixes queue orchestration with download processing details.
@MainActor
final class DownloadQueueCoordinator {
    private static let interactivePlaybackBurstThreshold = 8

    struct Dependencies {
        let canRunAutomatically: @MainActor () -> Bool
        let setQueueRunning: @MainActor (Bool) -> Void
        let refreshQueueStatus: @MainActor () -> Void
        let fetchPendingCount: @Sendable () async -> Int
        let currentWorkMode: @MainActor () -> DownloadWorkMode
        let queueWorkerCount: @MainActor (Int, DownloadWorkMode) -> Int
        let runWorker: @Sendable (Bool) async -> Bool
        let applyNetworkPolicy: @Sendable () async -> Void
        let finishBackgroundTask: @MainActor (Bool) -> Void
        let showCompletionToast: @MainActor () -> Void
    }

    private let dependencies: Dependencies
    private var queueTask: Task<Void, Never>?
    private var loggedNoPendingInCurrentIdleBurst = false

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var hasActiveTask: Bool {
        queueTask != nil
    }

    func startIfNeeded() {
        guard queueTask == nil else { return }
        guard dependencies.canRunAutomatically() else {
            dependencies.setQueueRunning(false)
            dependencies.refreshQueueStatus()
            return
        }

        queueTask = Task { [weak self] in
            guard let self else { return }
            await self.runQueueLoop()
        }
    }

    func cancelCurrentTask() async {
        guard let task = queueTask else {
            dependencies.setQueueRunning(false)
            return
        }
        task.cancel()
        await task.value
        dependencies.setQueueRunning(false)
    }

    func handleBackgroundExecutionRequest() async {
        if queueTask != nil {
            dependencies.refreshQueueStatus()
            return
        }

        let pending = await dependencies.fetchPendingCount()
        if pending == 0 {
            dependencies.finishBackgroundTask(true)
            return
        }

        await dependencies.applyNetworkPolicy()
        dependencies.refreshQueueStatus()
        startIfNeeded()
    }

    private func runQueueLoop() async {
        let initialPending = await dependencies.fetchPendingCount()
        if initialPending == 0 {
            if !loggedNoPendingInCurrentIdleBurst {
                EnsembleLogger.debug("📥 Queue loop: no pending downloads, skipping worker spawn")
                loggedNoPendingInCurrentIdleBurst = true
            }
            queueTask = nil
            dependencies.setQueueRunning(false)
            dependencies.refreshQueueStatus()
            return
        }
        loggedNoPendingInCurrentIdleBurst = false

        let workMode = dependencies.currentWorkMode()
        let workerCount = dependencies.queueWorkerCount(initialPending, workMode)
        let applyInteractiveCooldown = workMode == .interactivePlayback
            && initialPending >= Self.interactivePlaybackBurstThreshold

        let didProcessAny = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
            for _ in 0..<workerCount {
                group.addTask { await self.dependencies.runWorker(applyInteractiveCooldown) }
            }

            var anyProcessed = false
            for await workerDidWork in group where workerDidWork {
                anyProcessed = true
            }
            return anyProcessed
        }

        let wasCancelled = Task.isCancelled
        queueTask = nil

        if !wasCancelled && didProcessAny {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let remainingPending = await dependencies.fetchPendingCount()

            EnsembleLogger.debug(
                "📥 Queue wind-down: wasCancelled=\(wasCancelled), didProcessAny=\(didProcessAny), remainingPending=\(remainingPending)"
            )

            if remainingPending > 0 {
                dependencies.setQueueRunning(true)
                dependencies.refreshQueueStatus()
                startIfNeeded()
                return
            }
        }

        dependencies.setQueueRunning(false)
        dependencies.refreshQueueStatus()
        dependencies.finishBackgroundTask(true)

        if !wasCancelled && didProcessAny {
            dependencies.showCompletionToast()
        }
    }
}
