import Foundation

/// Adapter around platform background execution APIs used by offline downloads.
/// The offline queue remains the source of truth; this coordinator is best-effort acceleration only.
@MainActor
public protocol OfflineBackgroundExecutionCoordinating: AnyObject {
    var onExecutionRequested: (() -> Void)? { get set }
    var onExpiration: (() -> Void)? { get set }

    func register()
    func requestContinuedProcessingIfAvailable(pendingTrackCount: Int)
    func setProgress(completedUnitCount: Int, totalUnitCount: Int)
    func finishCurrentTask(success: Bool)
}

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks

@MainActor
public final class OfflineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating {
    public var onExecutionRequested: (() -> Void)?
    public var onExpiration: (() -> Void)?

    private static let continuedTaskIdentifier = "com.videogorl.ensemble.offline.continued"
    private var currentTask: AnyObject?
    private var didRegister = false

    public init() {}

    public func register() {
        guard #available(iOS 26.0, *) else { return }
        guard !didRegister else { return }

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self.currentTask = continuedTask
            continuedTask.expirationHandler = { [weak self] in
                Task { @MainActor in
                    self?.onExpiration?()
                    // Mark success even on expiration — downloads are best-effort
                    // background acceleration. The persistent queue resumes in
                    // foreground. Using success:false shows "Task Failed" in the
                    // Dynamic Island which is misleading for a paused download.
                    (self?.currentTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: true)
                    self?.currentTask = nil
                }
            }
            // Notify the download service so it can start/continue processing.
            // If the queue is already idle (downloads finished while in foreground),
            // the callback starts the queue which immediately drains and calls
            // finishCurrentTask(success: true).
            self.onExecutionRequested?()
        }

        didRegister = registered
        EnsembleLogger.debug("📦 Offline BG registration \(registered ? "succeeded" : "failed")")
    }

    public func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {
        guard #available(iOS 26.0, *) else { return }
        guard pendingTrackCount > 0 else { return }
        guard didRegister else {
            EnsembleLogger.debug("⚠️ Skipping BG continued processing submit: handler not registered")
            return
        }

        // Cancel any previously queued requests to prevent stale tasks from
        // stacking up as "Task Failed" in the Dynamic Island when they expire.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskIdentifier)

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.continuedTaskIdentifier,
            title: "Downloading Music",
            subtitle: "Preparing offline tracks"
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            EnsembleLogger.debug("📦 Submitted BG continued processing request for \(pendingTrackCount) tracks")
        } catch {
            EnsembleLogger.debug("⚠️ BG continued processing request rejected: \(error.localizedDescription)")
        }
    }

    public func setProgress(completedUnitCount: Int, totalUnitCount: Int) {
        guard #available(iOS 26.0, *) else { return }
        guard let currentTask = currentTask as? BGContinuedProcessingTask else { return }

        let total = max(1, totalUnitCount)
        currentTask.progress.totalUnitCount = Int64(total)
        currentTask.progress.completedUnitCount = Int64(min(max(0, completedUnitCount), total))
        currentTask.updateTitle(
            "Downloading Music",
            subtitle: "\(min(completedUnitCount, total))/\(total) tracks"
        )
    }

    public func finishCurrentTask(success: Bool) {
        guard #available(iOS 26.0, *) else { return }
        (currentTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
        currentTask = nil
    }
}

#else

@MainActor
public final class OfflineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinating {
    public var onExecutionRequested: (() -> Void)?
    public var onExpiration: (() -> Void)?

    public init() {}

    public func register() {}
    public func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {}
    public func setProgress(completedUnitCount: Int, totalUnitCount: Int) {}
    public func finishCurrentTask(success: Bool) {}
}

#endif
