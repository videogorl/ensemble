import Combine
import EnsembleAPI
import Foundation

/// ViewModel for the Home screen that displays dynamic content hubs from Plex servers
@MainActor
public final class HomeViewModel: ObservableObject {
    enum AutoRefreshReason: String, Hashable {
        case accountChange
        case syncCompleted
        case periodicTimer
    }

    @Published public private(set) var hubs: [Hub] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var hasConfiguredAccounts = false
    @Published public private(set) var hasEnabledLibraries = false
    @Published public private(set) var isRestoringCloudSources = false
    
    // Edit mode state
    @Published public var isEditingOrder = false
    @Published public var editableHubs: [Hub] = []
    @Published public private(set) var currentSourceName: String = ""
    
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubLoader: HomeHubLoaderProtocol
    private let hubOrderManager: HubOrderManager
    private let visibilityStore: LibraryVisibilityStore
    private var cancellables = Set<AnyCancellable>()
    private var refreshTriggerCancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastLoadTime: Date?
    private var currentSourceKey: String?
    private var isViewVisible = false
    private var isUserInteracting = false
    private var pendingAutoRefreshReasons = Set<AutoRefreshReason>()
    private var deferredAutoRefreshTask: Task<Void, Never>?
    private var pendingHubSnapshot: [Hub]?
    private var pendingHubApplyTask: Task<Void, Never>?
    private var unfilteredHubs: [Hub] = []

    // Startup suppression: the explicit .task load IS the startup load;
    // auto-refresh should not fire additional loads until it completes.
    private var initialLoadCompleted = false

    // Tracks when the last network hub fetch completed, so auto-refresh
    // can skip redundant fetches if one just happened (10s guard)
    private var lastNetworkHubFetchTime: Date?
    private let networkHubFetchCooldown: TimeInterval = 10.0

    // Periodic hub refresh
    private var hubRefreshTimer: Timer?
    private let hubRefreshInterval: TimeInterval = 10 * 60  // 10 minutes
    
    // Debounce interval to prevent rapid successive loads
    private let debounceInterval: TimeInterval = 2.0
    private let idleApplyDebounceNanoseconds: UInt64 = 350_000_000

    // Rotating count for hub requests — different counts cause PMS to select
    // different dynamic hub content (e.g. "More by...", "More in..." sections)
    private var refreshCount: Int = 0
    private static let hubCountOptions = [12, 15, 18, 20]

    /// Returns a count parameter that rotates on each pull-to-refresh,
    /// encouraging PMS to pick different dynamic hub content
    private var currentHubCount: String {
        let index = refreshCount % Self.hubCountOptions.count
        return String(Self.hubCountOptions[index])
    }
    internal private(set) var deferredAutoRefreshCount = 0
    internal private(set) var coalescedAutoRefreshCount = 0
    internal var autoRefreshRunnerForTesting: ((AutoRefreshReason) async -> Void)?
    internal var loadHubsRunnerForTesting: ((Bool, Bool) async -> Void)?
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        hubLoader: HomeHubLoaderProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager(),
        visibilityStore: LibraryVisibilityStore? = nil
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubLoader = hubLoader
        self.hubOrderManager = hubOrderManager
        self.visibilityStore = visibilityStore ?? .shared
        updateSourceAvailability()

        accountManager.$isAwaitingCloudSources
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRestoringCloudSources)
        
        // Load cached hubs immediately for offline-first experience
        Task { @MainActor in
            do {
                let cachedSnapshot = try await hubLoader.loadCachedSnapshot()
                self.currentSourceKey = cachedSnapshot.metadata.currentSourceKey
                self.currentSourceName = cachedSnapshot.metadata.currentSourceName

                if !cachedSnapshot.orderedHubs.isEmpty {
                    self.unfilteredHubs = cachedSnapshot.orderedHubs
                    self.hubs = Self.filterHubsForVisibility(
                        cachedSnapshot.orderedHubs,
                        hiddenSourceCompositeKeys: self.visibilityStore.hiddenSourceCompositeKeys
                    )
                    EnsembleStartupTiming.logTTFMP(milestone: "Cached hubs visible (\(self.hubs.count) hubs)")
                } else {
                    self.clearHubContentForUnavailableSources()
                }
            } catch {
                EnsembleLogger.debug("[HomeViewModel] Failed to load cached hubs: \(error.localizedDescription)")
            }
        }
        
        self.visibilityStore.$profiles
            .combineLatest(self.visibilityStore.$activeProfileID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyVisibilityToPublishedHubs()
            }
            .store(in: &cancellables)

        // Safety timeout: if the initial .task load never completes (e.g. no
        // configured accounts), unblock auto-refresh after 15 seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.initialLoadCompleted else { return }
            self.initialLoadCompleted = true
            EnsembleLogger.debug("🏠 Home initial load safety timeout — unblocking auto-refresh")
        }
    }
    
    deinit {
        // Invalidate timer directly without calling @MainActor method from nonisolated deinit
        hubRefreshTimer?.invalidate()
        deferredAutoRefreshTask?.cancel()
        pendingHubApplyTask?.cancel()
        refreshTriggerCancellables.removeAll()
    }
    
    /// Load hubs from all configured accounts with debouncing and offline-first caching
    public func loadHubs(
        applySavedOrder: Bool = true,
        deferUIUpdatesWhileInteracting: Bool = true
    ) async {
        updateSourceAvailability()
        guard hasEnabledLibraries else {
            clearHubContentForUnavailableSources()
            return
        }

        // Check if we should debounce
        if let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < debounceInterval {
            return
        }
        
        // Cancel any existing load task
        loadTask?.cancel()
        
        // Record load time for debouncing
        lastLoadTime = Date()

        if let loadHubsRunnerForTesting {
            await loadHubsRunnerForTesting(applySavedOrder, deferUIUpdatesWhileInteracting)
            return
        }

        loadTask = Task { @MainActor in
            isLoading = true
            error = nil

            guard let snapshot = await hubLoader.loadSnapshot(
                applySavedOrder: applySavedOrder,
                hubCount: self.currentHubCount
            ) else {
                clearHubContentForUnavailableSources()
                initialLoadCompleted = true
                loadTask = nil
                return
            }

            currentSourceKey = snapshot.metadata.currentSourceKey
            currentSourceName = snapshot.metadata.currentSourceName
            applyHubSnapshot(
                snapshot.orderedHubs,
                deferIfInteracting: deferUIUpdatesWhileInteracting,
                source: "network"
            )

            isLoading = false
            initialLoadCompleted = true
            lastNetworkHubFetchTime = snapshot.metadata.networkFetchCompletedAt
            loadTask = nil
        }

        await loadTask?.value
    }
    
    /// Refresh hubs (clears debounce to force immediate reload)
    /// Uses a rotated count to encourage PMS to pick different dynamic hub content
    /// (e.g. different "More by...", "More in..." selections)
    public func refresh() async {
        lastLoadTime = nil
        refreshCount += 1
        hubLoader.clearFailedHubKeys()
        await loadHubs(deferUIUpdatesWhileInteracting: false)
    }

    public func handleViewVisibilityChange(isVisible: Bool) {
        guard isViewVisible != isVisible else { return }
        isViewVisible = isVisible
        EnsembleLogger.debug("🏠 Feed visibility changed visible=\(isVisible)")

        if isVisible {
            startRefreshTriggerObservation()
            startPeriodicRefresh()
            flushDeferredUpdatesIfIdle()
        } else {
            stopRefreshTriggerObservation()
            stopPeriodicRefresh()
            isUserInteracting = false
            pendingAutoRefreshReasons.removeAll()
            deferredAutoRefreshTask?.cancel()
            deferredAutoRefreshTask = nil
        }
    }

    public func handleScrollInteraction(isInteracting: Bool) {
        guard isUserInteracting != isInteracting else { return }
        isUserInteracting = isInteracting

        if !isInteracting {
            flushDeferredUpdatesIfIdle()
        } else {
            pendingHubApplyTask?.cancel()
        }
    }

    private func requestAutoRefresh(reason: AutoRefreshReason) {
        guard hasEnabledLibraries else {
            clearHubContentForUnavailableSources()
            return
        }

        // Suppress auto-refresh until the initial .task load completes.
        // The explicit loadHubs() from HomeView.task IS the startup load.
        guard initialLoadCompleted else {
            EnsembleLogger.debug("🏠 Home auto-refresh skipped reason=\(reason.rawValue) detail=initialLoadInFlight")
            return
        }

        guard !syncCoordinator.isOffline else {
            EnsembleLogger.debug("🏠 Home auto-refresh skipped reason=\(reason.rawValue) detail=offline")
            return
        }

        // Skip if we recently completed a network hub fetch (prevents
        // duplicate fetches when sync-completed fires shortly after a load)
        if reason != .accountChange,
           let lastFetch = lastNetworkHubFetchTime,
           Date().timeIntervalSince(lastFetch) < networkHubFetchCooldown {
            EnsembleLogger.debug(
                "🏠 Home auto-refresh skipped reason=\(reason.rawValue) detail=cooldown elapsed=\(String(format: "%.1f", Date().timeIntervalSince(lastFetch)))"
            )
            return
        }

        if !isViewVisible || isUserInteracting {
            if !pendingAutoRefreshReasons.insert(reason).inserted {
                coalescedAutoRefreshCount += 1
            }
            EnsembleLogger.debug(
                "🏠 Home auto-refresh deferred reason=\(reason.rawValue), visible=\(isViewVisible), interacting=\(isUserInteracting), pending=\(pendingAutoRefreshReasons.count)"
            )
            scheduleDeferredAutoRefresh()
            return
        }

        // Coalesce immediate refreshes: if a load is already in progress, skip
        guard loadTask == nil else {
            EnsembleLogger.debug("🏠 Home auto-refresh coalesced (load in progress) reason=\(reason.rawValue)")
            return
        }

        deferredAutoRefreshTask?.cancel()
        deferredAutoRefreshTask = nil
        EnsembleLogger.debug("🏠 Home auto-refresh scheduled reason=\(reason.rawValue)")

        Task { @MainActor [weak self] in
            await self?.performAutoRefresh(triggeringReason: reason)
        }
    }

    private func scheduleDeferredAutoRefresh() {
        deferredAutoRefreshTask?.cancel()
        deferredAutoRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: idleApplyDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self.flushDeferredUpdatesIfIdle()
        }
    }

    private func performAutoRefresh(triggeringReason reason: AutoRefreshReason) async {
        pendingAutoRefreshReasons.removeAll()

        if let autoRefreshRunnerForTesting {
            await autoRefreshRunnerForTesting(reason)
            return
        }

        EnsembleLogger.debug("🏠 Home auto-refresh executing reason=\(reason.rawValue)")
        await loadHubs(deferUIUpdatesWhileInteracting: true)
    }

    private func flushDeferredUpdatesIfIdle() {
        guard isViewVisible, !isUserInteracting else { return }

        if !pendingAutoRefreshReasons.isEmpty {
            deferredAutoRefreshCount += 1
            let reason = pendingAutoRefreshReasons.first ?? .periodicTimer
            pendingAutoRefreshReasons.removeAll()
            deferredAutoRefreshTask?.cancel()
            deferredAutoRefreshTask = nil
            Task { @MainActor [weak self] in
                await self?.performAutoRefresh(triggeringReason: reason)
            }
        }

        if let pendingHubSnapshot {
            EnsembleLogger.debug("🏠 Applying deferred hub snapshot with \(pendingHubSnapshot.count) hubs")
            self.pendingHubSnapshot = nil
            self.hubs = pendingHubSnapshot
            // Don't overwrite editableHubs — user may be actively reordering
        }
    }

    private func applyHubSnapshot(_ snapshot: [Hub], deferIfInteracting: Bool, source: String) {
        unfilteredHubs = snapshot
        let visibleSnapshot = Self.filterHubsForVisibility(
            snapshot,
            hiddenSourceCompositeKeys: visibilityStore.hiddenSourceCompositeKeys
        )

        if deferIfInteracting && isViewVisible && isUserInteracting && !hubs.isEmpty {
            pendingHubSnapshot = visibleSnapshot
            pendingHubApplyTask?.cancel()
            pendingHubApplyTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: idleApplyDebounceNanoseconds)
                guard !Task.isCancelled else { return }
                self.flushDeferredUpdatesIfIdle()
            }
            EnsembleLogger.debug("🏠 Deferred hub snapshot update source=\(source) count=\(visibleSnapshot.count)")
            return
        }

        pendingHubSnapshot = nil
        pendingHubApplyTask?.cancel()
        hubs = visibleSnapshot
        // Don't overwrite editableHubs — user may be actively reordering
    }

    private func applyVisibilityToPublishedHubs() {
        let visibleHubs = Self.filterHubsForVisibility(
            unfilteredHubs,
            hiddenSourceCompositeKeys: visibilityStore.hiddenSourceCompositeKeys
        )

        if isViewVisible && isUserInteracting && !hubs.isEmpty {
            pendingHubSnapshot = visibleHubs
            return
        }

        pendingHubSnapshot = nil
        pendingHubApplyTask?.cancel()
        hubs = visibleHubs
        // Don't overwrite editableHubs — user may be actively reordering
    }

    internal var hasPendingAutoRefreshForTesting: Bool {
        !pendingAutoRefreshReasons.isEmpty
    }

    internal func requestAutoRefreshForTesting(reason: AutoRefreshReason) {
        requestAutoRefresh(reason: reason)
    }

    internal func clearPendingAutoRefreshForTesting() {
        pendingAutoRefreshReasons.removeAll()
        deferredAutoRefreshTask?.cancel()
        deferredAutoRefreshTask = nil
    }

    /// Mark the initial load as complete so auto-refresh tests can proceed
    internal func markInitialLoadCompletedForTesting() {
        initialLoadCompleted = true
    }

    private func startRefreshTriggerObservation() {
        guard refreshTriggerCancellables.isEmpty else { return }

        accountManager.$plexAccounts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accounts in
                guard let self else { return }
                self.updateSourceAvailability(from: accounts)
                self.hubLoader.clearFailedHubKeys()
                guard self.hasEnabledLibraries else {
                    self.clearHubContentForUnavailableSources()
                    return
                }
                self.requestAutoRefresh(reason: .accountChange)
            }
            .store(in: &refreshTriggerCancellables)

        syncCoordinator.$isSyncing
            .combineLatest(syncCoordinator.$sourceStatuses)
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] syncing, _ in
                guard let self, !syncing else { return }
                self.requestAutoRefresh(reason: .syncCompleted)
            }
            .store(in: &refreshTriggerCancellables)
    }

    private func stopRefreshTriggerObservation() {
        guard !refreshTriggerCancellables.isEmpty else { return }
        refreshTriggerCancellables.removeAll()
    }

    internal static func filterHubsForVisibility(
        _ hubs: [Hub],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Hub] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return hubs }

        return hubs.compactMap { hub in
            let visibleItems = hub.items.filter { item in
                !hiddenSourceCompositeKeys.contains(item.sourceCompositeKey)
            }

            guard !visibleItems.isEmpty else { return nil }
            return Hub(id: hub.id, title: hub.title, type: hub.type, items: visibleItems)
        }
    }

    // MARK: - Edit Mode

    /// Extract the server key from a hub ID.
    /// Hub IDs are "plex:{acct}:{srv}:{lib}:{hubId}" — server key is the first 3 components.
    private func serverKey(from hubId: String) -> String? {
        let components = hubId.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return "\(components[0]):\(components[1]):\(components[2])"
    }
    
    private func hubsForServer(sourceKey: String, in hubs: [Hub]) -> [Hub] {
        hubs.filter { serverKey(from: $0.id) == sourceKey }
    }
    
    private func mergeOrderedServerHubs(_ orderedServerHubs: [Hub], sourceKey: String, into hubs: [Hub]) -> [Hub] {
        var iterator = orderedServerHubs.makeIterator()
        return hubs.map { hub in
            if serverKey(from: hub.id) == sourceKey {
                return iterator.next() ?? hub
            }
            return hub
        }
    }
    
    /// Determine the primary source key (first enabled server) and its display name.
    /// Source key format matches the first 3 components of hub IDs: "plex:{acct}:{srv}"
    private func updateCurrentSource() {
        let servers = accountManager.plexAccounts.flatMap { $0.servers }
        let hasMultipleServers = servers.count > 1

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                if !enabledLibraries.isEmpty {
                    currentSourceKey = "plex:\(account.id):\(server.id)"
                    if hasMultipleServers {
                        currentSourceName = "Editing Music (on \(server.name))"
                    } else {
                        currentSourceName = "Editing Music"
                    }
                    return
                }
            }
        }

        currentSourceKey = nil
        currentSourceName = "Editing Music"
    }

    private func updateSourceAvailability(from accounts: [PlexAccountConfig]? = nil) {
        let snapshot = accounts ?? accountManager.plexAccounts
        hasConfiguredAccounts = !snapshot.isEmpty
        hasEnabledLibraries = snapshot.contains { account in
            account.servers.contains { server in
                server.libraries.contains(where: \.isEnabled)
            }
        }
    }

    private func clearHubContentForUnavailableSources() {
        loadTask?.cancel()
        isLoading = false
        error = nil
        unfilteredHubs = []
        hubs = []
        editableHubs = []
        isEditingOrder = false
        pendingHubSnapshot = nil
        pendingHubApplyTask?.cancel()
        pendingAutoRefreshReasons.removeAll()
        deferredAutoRefreshTask?.cancel()
        deferredAutoRefreshTask = nil
    }
    
    /// Look up the library title for a hub based on its ID.
    /// Hub IDs contain the account, server, and library key: "plex:{acct}:{srv}:{lib}:{hubType}".
    /// Matches on both server ID and library key to avoid cross-server collisions
    /// (different servers can have the same library key for different libraries).
    /// Returns nil for merged hubs or if the library isn't found.
    public func libraryName(forHubId hubId: String) -> String? {
        let components = hubId.split(separator: ":")
        // Merged hubs don't have a library key
        guard components.count >= 5, components[3] != "merged" else { return nil }
        let serverId = String(components[2])
        let libraryKey = String(components[3])

        for account in accountManager.plexAccounts {
            for server in account.servers where server.id == serverId {
                if let library = server.libraries.first(where: { $0.key == libraryKey }) {
                    return library.title
                }
            }
        }
        return nil
    }

    /// Enter edit mode - prepare the hub list for reordering
    public func enterEditMode() {
        updateCurrentSource()
        editableHubs = hubs
    }
    
    /// Exit edit mode - either save the reordered hubs or discard changes
    public func exitEditMode(save: Bool) {
        guard save, !editableHubs.isEmpty else {
            editableHubs = []
            isEditingOrder = false
            return
        }
        
        // Save the new order and apply it to the displayed hubs
        Task {
            await saveHubOrder(editableHubs)
            hubs = editableHubs
            editableHubs = []
            isEditingOrder = false
        }
    }
    
    /// Save the hub order for the current source
    private func saveHubOrder(_ orderedHubs: [Hub]) async {
        updateCurrentSource()
        guard let sourceKey = currentSourceKey else { return }
        
        let hubIds = hubsForServer(sourceKey: sourceKey, in: orderedHubs).map { $0.id }
        hubOrderManager.saveOrder(hubIds, for: sourceKey)
    }
    
    /// Reset the hub order to Plex's default for the current source
    public func resetOrder() {
        updateCurrentSource()
        guard let sourceKey = currentSourceKey else { return }
        
        EnsembleLogger.debug("[HubOrder] Reset requested for sourceKey=\(sourceKey)")
        hubOrderManager.resetOrder(for: sourceKey)

        // Apply cached default order immediately
        let serverHubs = hubsForServer(sourceKey: sourceKey, in: unfilteredHubs)
        EnsembleLogger.debug("[HubOrder] Applying default order to \(serverHubs.count) server hubs")
        let orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
        let orderedSnapshot = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: unfilteredHubs)
        applyHubSnapshot(orderedSnapshot, deferIfInteracting: false, source: "resetOrder")

        // Clear debounce and reload hubs to show the reset order
        lastLoadTime = nil
        
        // Reload hubs to get fresh data from server
        EnsembleLogger.debug("[HubOrder] Triggering background refresh from server")
        Task {
            await loadHubs(applySavedOrder: false, deferUIUpdatesWhileInteracting: false)
            if isEditingOrder {
                editableHubs = hubs
            }
        }
    }
    
    // MARK: - Periodic Refresh
    
    /// Start periodic hub refresh (every 10 minutes while app is active)
    public func startPeriodicRefresh() {
        guard isViewVisible else { return }
        guard hubRefreshTimer == nil else { return }
        
        EnsembleLogger.debug("⏰ Starting periodic hub refresh (every 10 minutes)")
        hubRefreshTimer = Timer.scheduledTimer(withTimeInterval: hubRefreshInterval, repeats: true) { [weak self] _ in
            // No [weak self] here — the outer Timer closure already captures self weakly
            Task { @MainActor in
                guard let self = self else { return }
                
                // Don't refresh if offline
                guard !self.syncCoordinator.isOffline else {
                    EnsembleLogger.debug("📴 Offline - skipping periodic hub refresh")
                    return
                }

                guard self.isViewVisible else { return }
                
                EnsembleLogger.debug("⏰ Periodic hub refresh triggered")
                self.requestAutoRefresh(reason: .periodicTimer)
            }
        }
    }
    
    /// Stop periodic hub refresh
    public func stopPeriodicRefresh() {
        guard hubRefreshTimer != nil else { return }
        hubRefreshTimer?.invalidate()
        hubRefreshTimer = nil
        EnsembleLogger.debug("🛑 Stopped periodic hub refresh")
    }
}
