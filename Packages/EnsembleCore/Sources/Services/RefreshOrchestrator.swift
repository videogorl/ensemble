import Foundation

/// Centralizes health-refresh gating so SyncCoordinator can delegate
/// cooldown, staleness, and startup-ownership decisions.
@MainActor
final class RefreshOrchestrator {
    enum HealthRefreshReason: Equatable {
        case networkReconnect
        case interfaceSwitch(from: NetworkType, to: NetworkType)
        case appForeground
        case accountInventoryRefresh

        var description: String {
            switch self {
            case .networkReconnect:
                return "network_reconnect"
            case .interfaceSwitch(let from, let to):
                return "interface_switch(\(from.description)->\(to.description))"
            case .appForeground:
                return "app_foreground"
            case .accountInventoryRefresh:
                return "account_inventory_refresh"
            }
        }
    }

    struct HealthRefreshRequest: Equatable {
        let reason: HealthRefreshReason
        let forceServerRefresh: Bool
    }

    typealias RefreshRunner = @MainActor (_ request: HealthRefreshRequest, _ eligibleServerKeys: Set<String>, _ startedAt: Date) async -> Void
    typealias CompletionHandler = @MainActor (_ completionTime: Date) -> Void

    private let healthRefreshCooldown: TimeInterval
    private let foregroundHealthStalenessThreshold: TimeInterval
    private let foregroundHealthLoadDeferralThreshold: TimeInterval
    private let postRatingPlaylistDebounceNanoseconds: UInt64
    private let postRatingFavoritesDebounceNanoseconds: UInt64
    private var lastHealthRefreshAt: Date?
    private var activeHealthRefreshTask: Task<Void, Never>?
    private var activeHealthRefreshRequest: HealthRefreshRequest?
    private var trailingHealthRefreshTask: Task<Void, Never>?
    private var trailingHealthRefreshRequest: HealthRefreshRequest?
    private var startupHealthChecksInitiated = false
    private let postRatingPlaylistSyncTasks = DebouncedTaskRegistry<String>()
    private let postRatingFavoritesReconciliationTasks = DebouncedTaskRegistry<String>()

    init(
        healthRefreshCooldown: TimeInterval = 30,
        foregroundHealthStalenessThreshold: TimeInterval = 60,
        foregroundHealthLoadDeferralThreshold: TimeInterval = 5 * 60,
        postRatingPlaylistDebounceNanoseconds: UInt64 = 5_000_000_000,
        postRatingFavoritesDebounceNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.healthRefreshCooldown = healthRefreshCooldown
        self.foregroundHealthStalenessThreshold = foregroundHealthStalenessThreshold
        self.foregroundHealthLoadDeferralThreshold = foregroundHealthLoadDeferralThreshold
        self.postRatingPlaylistDebounceNanoseconds = postRatingPlaylistDebounceNanoseconds
        self.postRatingFavoritesDebounceNanoseconds = postRatingFavoritesDebounceNanoseconds
    }

    @discardableResult
    func beginStartupHealthChecksIfNeeded() -> Bool {
        guard !startupHealthChecksInitiated, lastHealthRefreshAt == nil else {
            return false
        }

        startupHealthChecksInitiated = true
        return true
    }

    @discardableResult
    func runStartupHealthChecksIfNeeded(
        now: @escaping () -> Date,
        runRefresh: @escaping @MainActor () async -> Void,
        didComplete: @escaping CompletionHandler
    ) async -> Bool {
        if activeHealthRefreshTask != nil {
            EnsembleLogger.debug("🌐 RefreshOrchestrator: Awaiting in-flight health refresh before startup")
            await waitForActiveHealthRefresh()
            return false
        }
        guard beginStartupHealthChecksIfNeeded() else { return false }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                let completionTime = now()
                self.lastHealthRefreshAt = completionTime
                self.activeHealthRefreshTask = nil
                didComplete(completionTime)
            }

            await runRefresh()
        }

        activeHealthRefreshTask = task
        await task.value
        return true
    }

    @discardableResult
    func scheduleHealthRefresh(
        request: HealthRefreshRequest,
        now: @escaping () -> Date,
        shouldDeferForegroundHealthRefresh: (() -> Bool)?,
        eligibleServerKeysProvider: @escaping () -> Set<String>,
        runRefresh: @escaping RefreshRunner,
        didComplete: @escaping CompletionHandler,
        bypassCooldown: Bool = false
    ) -> Bool {
        if let activeHealthRefreshTask {
            guard request.forceServerRefresh,
                  trailingHealthRefreshRequest != request,
                  request.reason == .accountInventoryRefresh || activeHealthRefreshRequest != request else {
                EnsembleLogger.debug("🌐 RefreshOrchestrator: Coalescing health refresh request (\(request.reason.description))")
                return false
            }

            trailingHealthRefreshTask?.cancel()
            trailingHealthRefreshRequest = request
            trailingHealthRefreshTask = Task { @MainActor [weak self] in
                await activeHealthRefreshTask.value
                guard !Task.isCancelled, let self else { return }
                self.trailingHealthRefreshTask = nil
                self.trailingHealthRefreshRequest = nil
                self.scheduleHealthRefresh(
                    request: request,
                    now: now,
                    shouldDeferForegroundHealthRefresh: shouldDeferForegroundHealthRefresh,
                    eligibleServerKeysProvider: eligibleServerKeysProvider,
                    runRefresh: runRefresh,
                    didComplete: didComplete,
                    bypassCooldown: true
                )
            }
            EnsembleLogger.debug("🌐 RefreshOrchestrator: Queued trailing health refresh request (\(request.reason.description))")
            return true
        }

        let currentTime = now()

        if request.reason == .appForeground,
           let lastRefresh = lastHealthRefreshAt,
           currentTime.timeIntervalSince(lastRefresh) < foregroundHealthStalenessThreshold {
            EnsembleLogger.debug(
                "🌐 RefreshOrchestrator: Skipping foreground health refresh (last run \(String(format: "%.1f", currentTime.timeIntervalSince(lastRefresh)))s ago)"
            )
            return false
        }

        if request.reason == .appForeground,
           shouldDeferForegroundHealthRefresh?() == true,
           let lastRefresh = lastHealthRefreshAt,
           currentTime.timeIntervalSince(lastRefresh) < foregroundHealthLoadDeferralThreshold {
            EnsembleLogger.debug(
                "🌐 RefreshOrchestrator: Deferring foreground health refresh due to active playback/download load (\(String(format: "%.1f", currentTime.timeIntervalSince(lastRefresh)))s since last run)"
            )
            return false
        }

        if !bypassCooldown,
           shouldHonorCooldown(for: request.reason),
           let lastRefresh = lastHealthRefreshAt,
           currentTime.timeIntervalSince(lastRefresh) < healthRefreshCooldown {
            EnsembleLogger.debug(
                "🌐 RefreshOrchestrator: Skipping health refresh due to cooldown (\(String(format: "%.1f", currentTime.timeIntervalSince(lastRefresh)))s ago)"
            )
            return false
        }

        let eligibleServerKeys = eligibleServerKeysProvider()
        guard !eligibleServerKeys.isEmpty else {
            EnsembleLogger.debug("🌐 RefreshOrchestrator: No enabled-library servers eligible for health checks")
            return false
        }

        let startedAt = now()
        activeHealthRefreshRequest = request
        activeHealthRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                let completionTime = now()
                self.lastHealthRefreshAt = completionTime
                self.activeHealthRefreshRequest = nil
                self.activeHealthRefreshTask = nil
                didComplete(completionTime)
            }

            await runRefresh(request, eligibleServerKeys, startedAt)
        }

        return true
    }

    func schedulePostRatingPlaylistSync(
        serverSourceKey: String,
        action: @escaping @MainActor (String) async -> Void
    ) {
        postRatingPlaylistSyncTasks.schedule(
            key: serverSourceKey,
            delayNanoseconds: postRatingPlaylistDebounceNanoseconds
        ) {
            EnsembleLogger.debug("🔄 RefreshOrchestrator: Post-rating playlist sync for \(serverSourceKey)")
            await action(serverSourceKey)
        }
    }

    func schedulePostRatingFavoritesReconciliation(
        action: @escaping @MainActor () async -> Void
    ) {
        postRatingFavoritesReconciliationTasks.schedule(
            key: "favorites",
            delayNanoseconds: postRatingFavoritesDebounceNanoseconds
        ) {
            EnsembleLogger.debug("🔄 RefreshOrchestrator: Post-rating favorites reconciliation")
            await action()
        }
    }

    internal func awaitHealthRefreshForTesting() async {
        await waitForActiveHealthRefresh()
    }

    var hasScheduledHealthRefresh: Bool {
        activeHealthRefreshTask != nil || trailingHealthRefreshTask != nil
    }

    func waitForActiveHealthRefresh() async {
        while let healthRefreshTask = trailingHealthRefreshTask ?? activeHealthRefreshTask {
            await healthRefreshTask.value
        }
    }

    internal func setLastHealthRefreshForTesting(_ date: Date?) {
        lastHealthRefreshAt = date
    }

    private func shouldHonorCooldown(for reason: HealthRefreshReason) -> Bool {
        switch reason {
        case .accountInventoryRefresh:
            return false
        case .networkReconnect, .interfaceSwitch, .appForeground:
            return true
        }
    }
}
