import Foundation

/// Owns the repeating timer used for foreground incremental sync so
/// SyncCoordinator can delegate scheduling mechanics.
@MainActor
final class PeriodicSyncController {
    typealias SyncRunner = @MainActor () async -> Void
    typealias TimerFactory = @MainActor (_ interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> PeriodicSyncTimer

    private let defaultInterval: TimeInterval
    private let relaxedWebSocketInterval: TimeInterval
    private let timerFactory: TimerFactory
    private var timer: PeriodicSyncTimer?

    init(
        defaultInterval: TimeInterval = 60 * 60,
        relaxedWebSocketInterval: TimeInterval = 4 * 60 * 60,
        timerFactory: @escaping TimerFactory = { interval, handler in
            FoundationPeriodicSyncTimer(interval: interval, handler: handler)
        }
    ) {
        self.defaultInterval = defaultInterval
        self.relaxedWebSocketInterval = relaxedWebSocketInterval
        self.timerFactory = timerFactory
    }

    func start(action: @escaping SyncRunner) {
        schedule(interval: defaultInterval, action: action)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @discardableResult
    func adjustForWebSocket(hasActiveWebSocket: Bool, action: @escaping SyncRunner) -> TimeInterval {
        let interval = hasActiveWebSocket ? relaxedWebSocketInterval : defaultInterval
        schedule(interval: interval, action: action)
        return interval
    }

    internal func fireForTesting() {
        timer?.fire()
    }

    private func schedule(interval: TimeInterval, action: @escaping SyncRunner) {
        stop()
        timer = timerFactory(interval) {
            Task { @MainActor in
                await action()
            }
        }
    }
}

@MainActor
protocol PeriodicSyncTimer: AnyObject {
    func invalidate()
    func fire()
}

@MainActor
private final class FoundationPeriodicSyncTimer: PeriodicSyncTimer {
    private let timer: Timer

    init(interval: TimeInterval, handler: @escaping @MainActor () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func invalidate() {
        timer.invalidate()
    }

    func fire() {
        timer.fire()
    }
}
