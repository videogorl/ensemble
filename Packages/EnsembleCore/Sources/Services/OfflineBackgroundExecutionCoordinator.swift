import Foundation

/// Adapter around platform background execution APIs used by offline downloads.
/// The offline queue remains the source of truth; this coordinator is best-effort acceleration only.
@MainActor
public protocol OfflineDownloadBackgroundCoordinating: AnyObject {
    var onExecutionRequested: (() -> Void)? { get set }
    var onExpiration: (() -> Void)? { get set }
    var onBackgroundURLSessionEvents: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)? { get set }
    var onSystemWillSleep: (() -> Void)? { get set }
    var onSystemDidWake: (() -> Void)? { get set }

    func register()
    func requestContinuedProcessingIfAvailable(pendingTrackCount: Int)
    func setProgress(completedUnitCount: Int, totalUnitCount: Int)
    func finishCurrentTask(success: Bool)
    func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void)
    func completeBackgroundURLSessionEvents(identifier: String)
    func handleSystemWillSleep()
    func handleSystemDidWake()
}

@MainActor
private final class OfflineDownloadBackgroundEventStore {
    var onExecutionRequested: (() -> Void)?
    var onExpiration: (() -> Void)?
    var onBackgroundURLSessionEvents: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)?
    var onSystemWillSleep: (() -> Void)?
    var onSystemDidWake: (() -> Void)?

    private var backgroundURLSessionCompletions: [String: () -> Void] = [:]

    func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        backgroundURLSessionCompletions[identifier] = completionHandler
        guard let onBackgroundURLSessionEvents else {
            completeBackgroundURLSessionEvents(identifier: identifier)
            return
        }

        onBackgroundURLSessionEvents(identifier) { [weak self] in
            Task { @MainActor in
                self?.completeBackgroundURLSessionEvents(identifier: identifier)
            }
        }
    }

    func completeBackgroundURLSessionEvents(identifier: String) {
        guard let completionHandler = backgroundURLSessionCompletions.removeValue(forKey: identifier) else {
            return
        }
        completionHandler()
    }

    func handleSystemWillSleep() {
        onSystemWillSleep?()
    }

    func handleSystemDidWake() {
        onSystemDidWake?()
    }
}

@MainActor
class OfflineBackgroundExecutionCoordinatorBase: OfflineDownloadBackgroundCoordinating {
    var onExecutionRequested: (() -> Void)? {
        get { eventStore.onExecutionRequested }
        set { eventStore.onExecutionRequested = newValue }
    }

    var onExpiration: (() -> Void)? {
        get { eventStore.onExpiration }
        set { eventStore.onExpiration = newValue }
    }

    var onBackgroundURLSessionEvents: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)? {
        get { eventStore.onBackgroundURLSessionEvents }
        set { eventStore.onBackgroundURLSessionEvents = newValue }
    }

    var onSystemWillSleep: (() -> Void)? {
        get { eventStore.onSystemWillSleep }
        set { eventStore.onSystemWillSleep = newValue }
    }

    var onSystemDidWake: (() -> Void)? {
        get { eventStore.onSystemDidWake }
        set { eventStore.onSystemDidWake = newValue }
    }

    fileprivate let eventStore = OfflineDownloadBackgroundEventStore()

    init() {}

    func register() {}
    func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {}
    func setProgress(completedUnitCount: Int, totalUnitCount: Int) {}
    func finishCurrentTask(success: Bool) {}

    func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
        eventStore.handleBackgroundURLSessionEvents(identifier: identifier, completionHandler: completionHandler)
    }

    func completeBackgroundURLSessionEvents(identifier: String) {
        eventStore.completeBackgroundURLSessionEvents(identifier: identifier)
    }

    func handleSystemWillSleep() {
        eventStore.handleSystemWillSleep()
    }

    func handleSystemDidWake() {
        eventStore.handleSystemDidWake()
    }
}

#if os(iOS) && canImport(BackgroundTasks)
import BackgroundTasks
import UIKit

@MainActor
final class OfflineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinatorBase {
    private static let continuedTaskIdentifier = "com.videogorl.ensemble.offline.continued"
    private var currentTask: AnyObject?
    private var applicationBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var didRegister = false

    override init() {
        super.init()
    }

    override func register() {
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
                    self?.eventStore.onExpiration?()
                    // Mark success even on expiration — downloads are best-effort
                    // background acceleration. The persistent queue resumes in
                    // foreground. Using success:false shows "Task Failed" in the
                    // Dynamic Island which is misleading for a paused download.
                    self?.finishCurrentTask(success: true)
                }
            }
            // Notify the download service so it can start/continue processing.
            // If the queue is already idle (downloads finished while in foreground),
            // the callback starts the queue which immediately drains and calls
            // finishCurrentTask(success: true).
            self.eventStore.onExecutionRequested?()
        }

        didRegister = registered
        EnsembleLogger.debug("📦 Offline BG registration \(registered ? "succeeded" : "failed")")
    }

    override func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {
        guard pendingTrackCount > 0 else { return }
        beginApplicationBackgroundTaskIfNeeded()

        guard #available(iOS 26.0, *) else { return }
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

    override func setProgress(completedUnitCount: Int, totalUnitCount: Int) {
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

    override func finishCurrentTask(success: Bool) {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskIdentifier)
            (currentTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
            currentTask = nil
        }
        endApplicationBackgroundTaskIfNeeded()
    }

    private func beginApplicationBackgroundTaskIfNeeded() {
        guard applicationBackgroundTask == .invalid else { return }

        applicationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Offline Downloads") { [weak self] in
            Task { @MainActor in
                self?.eventStore.onExpiration?()
                self?.finishCurrentTask(success: true)
            }
        }
        EnsembleLogger.debug("📦 Began app background task for offline downloads")
    }

    private func endApplicationBackgroundTaskIfNeeded() {
        guard applicationBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(applicationBackgroundTask)
        applicationBackgroundTask = .invalid
        EnsembleLogger.debug("📦 Ended app background task for offline downloads")
    }
}

#elseif os(macOS)
import AppKit

@MainActor
final class OfflineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinatorBase {
    private var didRegister = false
    private var workspaceObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
    }

    deinit {
        let observers = workspaceObservers
        Task { @MainActor in
            for observer in observers {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
        }
    }

    override func register() {
        guard !didRegister else { return }
        didRegister = true

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.eventStore.handleSystemWillSleep()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.eventStore.handleSystemDidWake()
                }
            },
        ]
        EnsembleLogger.debug("📦 Offline download macOS sleep/wake recovery registered")
    }
}

#else

@MainActor
final class OfflineBackgroundExecutionCoordinator: OfflineBackgroundExecutionCoordinatorBase {}

#endif
