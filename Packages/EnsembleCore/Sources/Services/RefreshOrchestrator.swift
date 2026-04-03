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
    private var startupHealthChecksInitiated = false
    private var postRatingPlaylistSyncTasks: [String: Task<Void, Never>] = [:]
    private var postRatingFavoritesReconciliationTask: Task<Void, Never>?

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
    func scheduleHealthRefresh(
        request: HealthRefreshRequest,
        now: @escaping () -> Date,
        shouldDeferForegroundHealthRefresh: (() -> Bool)?,
        eligibleServerKeysProvider: () -> Set<String>,
        runRefresh: @escaping RefreshRunner,
        didComplete: @escaping CompletionHandler
    ) -> Bool {
        if activeHealthRefreshTask != nil {
            EnsembleLogger.debug("🌐 RefreshOrchestrator: Coalescing health refresh request (\(request.reason.description))")
            return false
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

        if shouldHonorCooldown(for: request.reason),
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
        activeHealthRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                let completionTime = now()
                self.lastHealthRefreshAt = completionTime
                self.activeHealthRefreshTask = nil
                didComplete(completionTime)
            }

            await runRefresh(request, eligibleServerKeys, startedAt)
        }

        return true
    }

    func markHealthRefreshCompleted(at date: Date) {
        lastHealthRefreshAt = date
    }

    func schedulePostRatingPlaylistSync(
        serverSourceKey: String,
        action: @escaping @MainActor (String) async -> Void
    ) {
        let debounceDelay = postRatingPlaylistDebounceNanoseconds
        postRatingPlaylistSyncTasks[serverSourceKey]?.cancel()
        postRatingPlaylistSyncTasks[serverSourceKey] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounceDelay)
            guard !Task.isCancelled, let self else { return }

            EnsembleLogger.debug("🔄 RefreshOrchestrator: Post-rating playlist sync for \(serverSourceKey)")
            await action(serverSourceKey)
            self.postRatingPlaylistSyncTasks.removeValue(forKey: serverSourceKey)
        }
    }

    func schedulePostRatingFavoritesReconciliation(
        action: @escaping @MainActor () async -> Void
    ) {
        let debounceDelay = postRatingFavoritesDebounceNanoseconds
        postRatingFavoritesReconciliationTask?.cancel()
        postRatingFavoritesReconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: debounceDelay)
            guard !Task.isCancelled, let self else { return }

            EnsembleLogger.debug("🔄 RefreshOrchestrator: Post-rating favorites reconciliation")
            await action()
            self.postRatingFavoritesReconciliationTask = nil
        }
    }

    internal func awaitHealthRefreshForTesting() async {
        await activeHealthRefreshTask?.value
    }

    internal func setLastHealthRefreshForTesting(_ date: Date?) {
        lastHealthRefreshAt = date
    }

    internal func awaitPostRatingPlaylistSyncForTesting(serverSourceKey: String) async {
        await postRatingPlaylistSyncTasks[serverSourceKey]?.value
    }

    internal func awaitPostRatingFavoritesReconciliationForTesting() async {
        await postRatingFavoritesReconciliationTask?.value
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
