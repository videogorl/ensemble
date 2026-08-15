import Foundation

/// Owns the repeating timers used for foreground incremental sync so
/// SyncCoordinator can delegate scheduling mechanics.
@MainActor
final class PeriodicSyncController {
    typealias SyncRunner = @MainActor () async -> Void
    typealias TimerFactory = @MainActor (_ interval: TimeInterval, _ handler: @escaping @MainActor () -> Void) -> PeriodicSyncTimer

    private let defaultInterval: TimeInterval
    private let relaxedWebSocketInterval: TimeInterval
    private let downloadedPlaylistInterval: TimeInterval
    private let timerFactory: TimerFactory
    private var timer: PeriodicSyncTimer?
    private var downloadedPlaylistTimer: PeriodicSyncTimer?
    private var isRunning = false

    init(
        defaultInterval: TimeInterval = 60 * 60,
        relaxedWebSocketInterval: TimeInterval = 4 * 60 * 60,
        downloadedPlaylistInterval: TimeInterval = 60,
        timerFactory: @escaping TimerFactory = { interval, handler in
            FoundationPeriodicSyncTimer(interval: interval, handler: handler)
        }
    ) {
        self.defaultInterval = defaultInterval
        self.relaxedWebSocketInterval = relaxedWebSocketInterval
        self.downloadedPlaylistInterval = downloadedPlaylistInterval
        self.timerFactory = timerFactory
    }

    func start(
        action: @escaping SyncRunner,
        downloadedPlaylistAction: SyncRunner? = nil
    ) {
        isRunning = true
        schedule(interval: defaultInterval, action: action)
        downloadedPlaylistTimer?.invalidate()
        downloadedPlaylistTimer = downloadedPlaylistAction.map { action in
            timerFactory(downloadedPlaylistInterval) {
                Task { @MainActor in
                    await action()
                }
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        downloadedPlaylistTimer?.invalidate()
        downloadedPlaylistTimer = nil
    }

    @discardableResult
    func adjustForWebSocket(hasActiveWebSocket: Bool, action: @escaping SyncRunner) -> TimeInterval {
        let interval = hasActiveWebSocket ? relaxedWebSocketInterval : defaultInterval
        if isRunning {
            schedule(interval: interval, action: action)
        }
        return interval
    }

    private func schedule(interval: TimeInterval, action: @escaping SyncRunner) {
        timer?.invalidate()
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
}
