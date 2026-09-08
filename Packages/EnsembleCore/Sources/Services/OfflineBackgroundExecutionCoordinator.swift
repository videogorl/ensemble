import Foundation

/// Work in one user-requested queue pass, independent of overlapping download targets.
struct OfflineDownloadBatchProgress {
    private var units: [String: Int] = [:]
    private(set) var completedUnitCount = 0
    var totalUnitCount: Int { units.count * 1_000 }

    mutating func include(_ identities: [String]) {
        for identity in identities where units[identity] == nil { units[identity] = 0 }
    }

    mutating func update(_ identity: String, fraction: Double) {
        guard let previous = units[identity], fraction.isFinite else { return }
        let next = max(previous, Int(min(1, max(0, fraction)) * 1_000))
        units[identity] = next
        completedUnitCount += next - previous
    }
}

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
    private var pendingIdentifier: String?
    private var progressCounts = (completed: 0, total: 1)
    private var applicationBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
    }

    @available(iOS 26.0, *)
    private func registerContinuedTask(identifier: String) -> Bool {

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: .main
        ) { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            guard self.pendingIdentifier == continuedTask.identifier else {
                continuedTask.setTaskCompleted(success: true)
                return
            }
            self.pendingIdentifier = nil
            self.currentTask = continuedTask
            self.setProgress(completedUnitCount: self.progressCounts.completed, totalUnitCount: self.progressCounts.total)
            // The continued-processing grant replaces the short UIKit safety window.
            // Its expiration must not cancel work protected by the longer grant.
            self.endApplicationBackgroundTaskIfNeeded()
            EnsembleLogger.debug("📦 Offline continued processing execution granted")
            continuedTask.expirationHandler = { [weak self, weak continuedTask] in
                Task { @MainActor in
                    guard let self, let continuedTask, self.currentTask === continuedTask else { return }
                    EnsembleLogger.debug("📦 Offline continued processing grant expired")
                    self.eventStore.onExpiration?()
                    // Relinquish this execution grant. Durable URLSession transfers and
                    // queue recovery are independent; iOS may still display expiration.
                    self.finishCurrentTask(success: true)
                }
            }
            // Notify the download service so it can start/continue processing.
            // If the queue is already idle (downloads finished while in foreground),
            // the callback starts the queue which immediately drains and calls
            // finishCurrentTask(success: true).
            self.eventStore.onExecutionRequested?()
        }

        EnsembleLogger.debug("📦 Offline BG registration \(registered ? "succeeded" : "failed")")
        return registered
    }

    override func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {
        guard pendingTrackCount > 0, currentTask == nil, pendingIdentifier == nil else { return }
        beginApplicationBackgroundTaskIfNeeded()

        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return }
        // Continued-processing registrations may be made after launch. The plist
        // permits a wildcard, but register and submit the same concrete identifier.
        let identifier = Self.continuedTaskIdentifier + "." + UUID().uuidString
        guard registerContinuedTask(identifier: identifier) else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Downloading Music",
            subtitle: "0% of current batch"
        )
        // Work already runs independently. Do not enqueue a stale accelerator grant.
        request.strategy = .fail
        pendingIdentifier = identifier

        do {
            try BGTaskScheduler.shared.submit(request)
            EnsembleLogger.debug("📦 Submitted BG continued processing request for \(pendingTrackCount) tracks")
        } catch {
            pendingIdentifier = nil
            EnsembleLogger.debug("⚠️ BG continued processing request rejected: \(error.localizedDescription)")
        }
    }

    override func setProgress(completedUnitCount: Int, totalUnitCount: Int) {
        let total = max(1, totalUnitCount)
        let completed = min(max(0, completedUnitCount), total)
        progressCounts = (completed, total)
        guard #available(iOS 26.0, *), let currentTask = currentTask as? BGContinuedProcessingTask else { return }
        guard currentTask.progress.totalUnitCount != Int64(total)
                || currentTask.progress.completedUnitCount != Int64(completed) else { return }
        currentTask.progress.totalUnitCount = Int64(total)
        currentTask.progress.completedUnitCount = Int64(completed)
        currentTask.updateTitle(
            "Downloading Music",
            subtitle: "\(Int(Double(completed) / Double(total) * 100))% of current batch"
        )
        EnsembleLogger.debug("📦 Offline continued processing progress units=\(completed)/\(total)")
    }

    override func finishCurrentTask(success: Bool) {
        if #available(iOS 26.0, *) {
            if let pendingIdentifier {
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: pendingIdentifier)
                self.pendingIdentifier = nil
            }
            if currentTask != nil {
                EnsembleLogger.debug("📦 Offline continued processing finished success=\(success) units=\(progressCounts.completed)/\(progressCounts.total)")
            }
            (currentTask as? BGContinuedProcessingTask)?.setTaskCompleted(success: success)
            currentTask = nil
        }
        progressCounts = (0, 1)
        endApplicationBackgroundTaskIfNeeded()
    }

    private func beginApplicationBackgroundTaskIfNeeded() {
        guard applicationBackgroundTask == .invalid, currentTask == nil else { return }

        applicationBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Offline Downloads") { [weak self] in
            guard let self, self.applicationBackgroundTask != .invalid else { return }
            self.endApplicationBackgroundTaskIfNeeded()
            guard self.currentTask == nil else { return }
            EnsembleLogger.debug("📦 Offline short background window expired without a continued grant")
            self.eventStore.onExpiration?()
            self.finishCurrentTask(success: true)
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
