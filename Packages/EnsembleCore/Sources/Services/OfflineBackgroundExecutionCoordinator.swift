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

    private static let identifierPrefix = "com.videogorl.ensemble.offline.continued"
    private var currentTask: AnyObject?
    private var didRegister = false

    public init() {}

    public func register() {
        guard #available(iOS 26.0, *) else { return }
        guard !didRegister else { return }

        let wildcardIdentifier = "\(Self.identifierPrefix).*"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: wildcardIdentifier, using: nil) { [weak self] task in
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
                    (self?.currentTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: false)
                    self?.currentTask = nil
                }
            }
            self.onExecutionRequested?()
        }

        didRegister = registered
        #if DEBUG
        EnsembleLogger.debug("📦 Offline BG registration \(registered ? "succeeded" : "failed")")
        #endif
    }

    public func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {
        guard #available(iOS 26.0, *) else { return }
        guard pendingTrackCount > 0 else { return }

        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Downloading Music",
            subtitle: "Preparing offline tracks"
        )
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            EnsembleLogger.debug("📦 Submitted BG continued processing request for \(pendingTrackCount) tracks")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("⚠️ BG continued processing request rejected: \(error.localizedDescription)")
            #endif
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
