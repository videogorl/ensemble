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
    
    // Edit mode state
    @Published public var isEditingOrder = false
    @Published public var editableHubs: [Hub] = []
    @Published public private(set) var currentSourceName: String = ""
    
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubRepository: HubRepositoryProtocol
    private let hubOrderManager: HubOrderManager
    private let visibilityStore: LibraryVisibilityStore
    private var cancellables = Set<AnyCancellable>()
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

    // Hub keys (from getHubItems) that returned errors — persisted across sessions
    // to avoid re-requesting endpoints that consistently 404. Cleared on pull-to-refresh
    // or when the server list changes.
    private static let failedHubKeysKey = "failedHubKeys"
    private var failedHubKeys: Set<String> = {
        let saved = UserDefaults.standard.stringArray(forKey: failedHubKeysKey) ?? []
        return Set(saved)
    }()
    
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
        hubRepository: HubRepositoryProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager(),
        visibilityStore: LibraryVisibilityStore? = nil
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubRepository = hubRepository
        self.hubOrderManager = hubOrderManager
        self.visibilityStore = visibilityStore ?? .shared
        updateSourceAvailability()
        
        // Load cached hubs immediately for offline-first experience
        Task { @MainActor in
            do {
                let cached = try await hubRepository.fetchHubs()
                let enabledSourceKeys = enabledSourceCompositeKeys()
                let cachedForEnabledSources = Self.filterHubsToEnabledSources(
                    cached,
                    enabledSourceCompositeKeys: enabledSourceKeys
                )
                if !cachedForEnabledSources.isEmpty {
                    // Apply saved custom order to cached hubs
                    updateCurrentSource()
                    if let sourceKey = currentSourceKey {
                        let serverHubs = hubsForServer(sourceKey: sourceKey, in: cachedForEnabledSources)
                        let orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                        self.unfilteredHubs = mergeOrderedServerHubs(
                            orderedServerHubs,
                            sourceKey: sourceKey,
                            into: cachedForEnabledSources
                        )
                        self.hubs = Self.filterHubsForVisibility(
                            self.unfilteredHubs,
                            hiddenSourceCompositeKeys: self.visibilityStore.hiddenSourceCompositeKeys
                        )
                        #if DEBUG
                        EnsembleLogger.debug("[HubOrder] Applied saved order to \(serverHubs.count) cached hubs")
                        #endif
                    } else {
                        self.unfilteredHubs = cachedForEnabledSources
                        self.hubs = Self.filterHubsForVisibility(
                            cachedForEnabledSources,
                            hiddenSourceCompositeKeys: self.visibilityStore.hiddenSourceCompositeKeys
                        )
                    }
                    EnsembleStartupTiming.logTTFMP(milestone: "Cached hubs visible (\(self.hubs.count) hubs)")
                } else {
                    self.clearHubContentForUnavailableSources()
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("[HomeViewModel] Failed to load cached hubs: \(error.localizedDescription)")
                #endif
            }
        }
        
        // Reload when accounts change (skip initial publish — only clear
        // persisted hub keys when accounts actually change after startup)
        accountManager.$plexAccounts
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accounts in
                guard let self else { return }
                self.updateSourceAvailability(from: accounts)
                // Server list changed — clear persisted failed hub keys so
                // they're retried against the new configuration
                self.clearFailedHubKeys()
                guard self.hasEnabledLibraries else {
                    self.clearHubContentForUnavailableSources()
                    return
                }
                self.requestAutoRefresh(reason: .accountChange)
            }
            .store(in: &cancellables)
        
        // Auto-reload when sync completes or source statuses change.
        // Combined into a single subscriber to avoid duplicate refreshes when both
        // publishers fire in close succession (e.g., sync completion updates both
        // isSyncing and sourceStatuses within the debounce window).
        syncCoordinator.$isSyncing
            .combineLatest(syncCoordinator.$sourceStatuses)
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] syncing, _ in
                if !syncing {
                    self?.requestAutoRefresh(reason: .syncCompleted)
                }
            }
            .store(in: &cancellables)

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
            #if DEBUG
            EnsembleLogger.debug("🏠 Home initial load safety timeout — unblocking auto-refresh")
            #endif
        }
    }
    
    deinit {
        // Invalidate timer directly without calling @MainActor method from nonisolated deinit
        hubRefreshTimer?.invalidate()
        deferredAutoRefreshTask?.cancel()
        pendingHubApplyTask?.cancel()
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
        
        // Identify the primary source key and name for ordering
        updateCurrentSource()
        #if DEBUG
        EnsembleLogger.debug(
            "[HubOrder] loadHubs applySavedOrder=\(applySavedOrder) sourceKey=\(currentSourceKey ?? "nil") deferUI=\(deferUIUpdatesWhileInteracting)"
        )
        #endif
        
        // Create a new load task
        loadTask = Task { @MainActor in
            isLoading = true
            error = nil
            
            // Capture API clients on main actor before entering detached task
            // This reuses cached clients with active connections
            var fetchTasks: [(sourceKey: String, client: PlexAPIClient, sectionKey: String)] = []
            
            for account in accountManager.plexAccounts {
                for server in account.servers {
                    guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                        continue
                    }
                    
                    let enabledLibraries = server.libraries.filter { $0.isEnabled }
                    
                    for library in enabledLibraries {
                        let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"
                        fetchTasks.append((sourceKey, client, library.key))
                    }
                }
            }

            guard !fetchTasks.isEmpty else {
                clearHubContentForUnavailableSources()
                return
            }
            
            // Perform loading with parallel fetching and optional progressive UI updates.
            // Progressive updates are only used for empty-state loads to avoid in-scroll churn.
            var collectedHubs: [Hub] = []
            let shouldApplyProgressiveUpdates = self.hubs.isEmpty
            let hubCount = self.currentHubCount
            let knownFailedHubKeys = self.failedHubKeys

            await withTaskGroup(of: (hubs: [Hub], failedKeys: [String]).self) { group in
                // Fetch section-specific hubs in parallel
                for task in fetchTasks {
                    group.addTask {
                        var hubs: [Hub] = []
                        var newFailedKeys: [String] = []
                        do {
                            let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey, count: hubCount)

                            // Process hub items in parallel
                            await withTaskGroup(of: (hub: Hub?, failedKey: String?).self) { hubGroup in
                                for plexHub in plexHubs {
                                    hubGroup.addTask {
                                        let hubId = "\(task.sourceKey):\(plexHub.id)"
                                        var hubItems: [HubItem] = []

                                        if let metadata = plexHub.metadata, !metadata.isEmpty {
                                            let filteredMetadata = metadata.filter { item in
                                                let type = item.type?.lowercased() ?? ""
                                                return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                                            }
                                            hubItems = Array(filteredMetadata.prefix(12)).map { HubItem(from: $0, sourceKey: task.sourceKey) }
                                        } else if let key = plexHub.key ?? plexHub.hubKey {
                                            // Skip hub keys that previously failed (e.g. 404)
                                            guard !knownFailedHubKeys.contains(key) else {
                                                return (hub: nil, failedKey: nil)
                                            }
                                            do {
                                                let metadata = try await task.client.getHubItems(hubKey: key)
                                                let filteredMetadata = metadata.filter { item in
                                                    let type = item.type?.lowercased() ?? ""
                                                    return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                                                }
                                                hubItems = Array(filteredMetadata.prefix(12)).map { HubItem(from: $0, sourceKey: task.sourceKey) }
                                            } catch {
                                                // Track the failed key so we don't retry it this session
                                                return (hub: nil, failedKey: key)
                                            }
                                        }

                                        if !hubItems.isEmpty {
                                            let hub = Hub(
                                                id: hubId,
                                                title: plexHub.title,
                                                type: plexHub.type ?? "mixed",
                                                items: hubItems,
                                                context: plexHub.context
                                            )
                                            return (hub: hub, failedKey: nil)
                                        }
                                        return (hub: nil, failedKey: nil)
                                    }
                                }

                                for await result in hubGroup {
                                    if let hub = result.hub {
                                        hubs.append(hub)
                                    }
                                    if let failedKey = result.failedKey {
                                        newFailedKeys.append(failedKey)
                                    }
                                }
                            }
                        } catch {
                            // Silently continue on error
                        }
                        return (hubs: hubs, failedKeys: newFailedKeys)
                    }
                }

                // Collect hubs progressively and update UI only for first-time loads.
                for await result in group {
                    collectedHubs.append(contentsOf: result.hubs)
                    // Cache failed hub keys across sessions
                    if !result.failedKeys.isEmpty {
                        for key in result.failedKeys {
                            self.failedHubKeys.insert(key)
                        }
                        self.persistFailedHubKeys()
                    }

                    guard shouldApplyProgressiveUpdates, !result.hubs.isEmpty else { continue }

                    let progressiveResult = self.mergeAndGroupHubs(collectedHubs)
                    let displayHubs: [Hub]
                    if let sourceKey = currentSourceKey {
                        let serverHubs = hubsForServer(sourceKey: sourceKey, in: progressiveResult)
                        let orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                        displayHubs = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: progressiveResult)
                    } else {
                        displayHubs = progressiveResult
                    }

                    applyHubSnapshot(
                        displayHubs,
                        deferIfInteracting: deferUIUpdatesWhileInteracting,
                        source: "progressive"
                    )
                }
            }

            let fetchedHubs = collectedHubs

            #if DEBUG
            if !self.failedHubKeys.isEmpty {
                EnsembleLogger.debug("🏠 Cached \(self.failedHubKeys.count) failed hub key(s) — will skip on future loads")
            }
            #endif

            // Fallback to global hubs if few section hubs found
            let finalHubs: [Hub]
            if fetchedHubs.count < 3 {
                finalHubs = await Task.detached(priority: .userInitiated) {
                    var allHubs = fetchedHubs

                    // Get unique server IDs
                    var handledServers = Set<String>()
                    var serverTasks: [(sourceKey: String, client: PlexAPIClient)] = []
                    for task in fetchTasks {
                        let serverId = task.sourceKey.split(separator: ":").prefix(2).joined(separator: ":")
                        if !handledServers.contains(serverId) {
                            handledServers.insert(serverId)
                            serverTasks.append((task.sourceKey, task.client))
                        }
                    }

                    // Fetch global hubs in parallel
                    let globalHubs = await withTaskGroup(of: [Hub].self) { group in
                        var collected: [Hub] = []

                        for task in serverTasks {
                            group.addTask {
                                var hubs: [Hub] = []
                                do {
                                    let globalHubs = try await task.client.getGlobalHubs()
                                    for plexHub in globalHubs {
                                        let hubType = plexHub.type?.lowercased() ?? ""
                                        let isMusic = hubType.contains("artist") || hubType.contains("album") || hubType.contains("track") || hubType.contains("playlist") || hubType.contains("music")
                                        if !isMusic { continue }

                                        let hubId = "\(task.sourceKey):global:\(plexHub.id)"
                                        var hubItems: [HubItem] = []

                                        if let metadata = plexHub.metadata, !metadata.isEmpty {
                                            let filteredMetadata = metadata.filter { item in
                                                let type = item.type?.lowercased() ?? ""
                                                return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                                            }
                                            hubItems = Array(filteredMetadata.prefix(12)).map { HubItem(from: $0, sourceKey: task.sourceKey) }
                                        }

                                        if !hubItems.isEmpty {
                                            hubs.append(Hub(
                                                id: hubId,
                                                title: plexHub.title,
                                                type: plexHub.type ?? "mixed",
                                                items: hubItems,
                                                context: plexHub.context
                                            ))
                                        }
                                    }
                                } catch {
                                    // Silently continue on error
                                }
                                return hubs
                            }
                        }

                        for await hubs in group {
                            collected.append(contentsOf: hubs)
                        }

                        return collected
                    }

                    allHubs.append(contentsOf: globalHubs)
                    return allHubs
                }.value
            } else {
                finalHubs = fetchedHubs
            }

            // Merge and group hubs
            let fetchedHubsResult = mergeAndGroupHubs(finalHubs)

            #if DEBUG
            EnsembleLogger.debug("[HubOrder] Fetched hubs count=\(fetchedHubsResult.count)")
            #endif

            // CRITICAL: Save default order IMMEDIATELY after fetch, before any other operations
            // This ensures reset always has a baseline to return to
            if let sourceKey = currentSourceKey {
                let defaultHubs = hubsForServer(sourceKey: sourceKey, in: fetchedHubsResult)
                #if DEBUG
                EnsembleLogger.debug("[HubOrder] Saving default order for sourceKey=\(sourceKey) count=\(defaultHubs.count)")
                #endif
                hubOrderManager.saveDefaultOrder(defaultHubs.map { $0.id }, for: sourceKey)
            }

            // Apply saved or default order to the fetched hubs
            let orderedHubs: [Hub]
            if let sourceKey = currentSourceKey {
                let serverHubs = hubsForServer(sourceKey: sourceKey, in: fetchedHubsResult)
                let orderedServerHubs: [Hub]

                if applySavedOrder {
                    orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                } else {
                    orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
                }

                orderedHubs = mergeOrderedServerHubs(
                    orderedServerHubs,
                    sourceKey: sourceKey,
                    into: fetchedHubsResult
                )
            } else {
                orderedHubs = fetchedHubsResult
            }
            
            // Update UI all at once; defer while interacting to prevent scroll jumps.
            if !orderedHubs.isEmpty {
                applyHubSnapshot(
                    orderedHubs,
                    deferIfInteracting: deferUIUpdatesWhileInteracting,
                    source: "final"
                )
            }
            
            isLoading = false
            initialLoadCompleted = true
            lastNetworkHubFetchTime = Date()
            loadTask = nil

            // Persist to cache for offline access
            let hubsToCache = hubs
            Task.detached(priority: .background) { [hubRepository] in
                try? await hubRepository.saveHubs(hubsToCache)
            }
        }

        await loadTask?.value
    }
    
    /// Refresh hubs (clears debounce to force immediate reload)
    /// Uses a rotated count to encourage PMS to pick different dynamic hub content
    /// (e.g. different "More by...", "More in..." selections)
    public func refresh() async {
        lastLoadTime = nil
        refreshCount += 1
        clearFailedHubKeys()
        await loadHubs(deferUIUpdatesWhileInteracting: false)
    }

    public func handleViewVisibilityChange(isVisible: Bool) {
        guard isViewVisible != isVisible else { return }
        isViewVisible = isVisible

        if isVisible {
            startPeriodicRefresh()
            flushDeferredUpdatesIfIdle()
        } else {
            stopPeriodicRefresh()
            isUserInteracting = false
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
            #if DEBUG
            EnsembleLogger.debug("🏠 Home auto-refresh suppressed (initial load in flight) reason=\(reason.rawValue)")
            #endif
            return
        }

        guard !syncCoordinator.isOffline else {
            #if DEBUG
            EnsembleLogger.debug("📴 Home auto-refresh skipped (offline) reason=\(reason.rawValue)")
            #endif
            return
        }

        // Skip if we recently completed a network hub fetch (prevents
        // duplicate fetches when sync-completed fires shortly after a load)
        if reason != .accountChange,
           let lastFetch = lastNetworkHubFetchTime,
           Date().timeIntervalSince(lastFetch) < networkHubFetchCooldown {
            #if DEBUG
            EnsembleLogger.debug("🏠 Home auto-refresh skipped (fetched \(String(format: "%.1f", Date().timeIntervalSince(lastFetch)))s ago) reason=\(reason.rawValue)")
            #endif
            return
        }

        if !isViewVisible || isUserInteracting {
            if !pendingAutoRefreshReasons.insert(reason).inserted {
                coalescedAutoRefreshCount += 1
            }
            #if DEBUG
            EnsembleLogger.debug(
                "🏠 Home auto-refresh deferred reason=\(reason.rawValue), visible=\(isViewVisible), interacting=\(isUserInteracting), pending=\(pendingAutoRefreshReasons.count)"
            )
            #endif
            scheduleDeferredAutoRefresh()
            return
        }

        // Coalesce immediate refreshes: if a load is already in progress, skip
        guard loadTask == nil else {
            #if DEBUG
            EnsembleLogger.debug("🏠 Home auto-refresh coalesced (load in progress) reason=\(reason.rawValue)")
            #endif
            return
        }

        deferredAutoRefreshTask?.cancel()
        deferredAutoRefreshTask = nil

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

        #if DEBUG
        EnsembleLogger.debug("🏠 Home auto-refresh executing reason=\(reason.rawValue)")
        #endif
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
            #if DEBUG
            EnsembleLogger.debug("🏠 Applying deferred hub snapshot with \(pendingHubSnapshot.count) hubs")
            #endif
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
            #if DEBUG
            EnsembleLogger.debug("🏠 Deferred hub snapshot update source=\(source) count=\(visibleSnapshot.count)")
            #endif
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
    
    /// Normalize hub titles by removing " in [Library Name]" suffix
    /// Only strips the suffix for known hub title patterns (e.g. "Recently Added in Music")
    /// to avoid breaking titles like "More in Pop/Rock"
    private static nonisolated func normalizeHubTitle(_ title: String) -> String {
        // Only strip " in ..." for titles that start with known prefixes
        // Dynamic hubs like "More in Pop/Rock" should keep their full title
        let stripPrefixes = ["Recently Added", "Recently Played", "Most Played"]
        for prefix in stripPrefixes {
            if title.hasPrefix(prefix), let range = title.range(of: " in ", options: .backwards) {
                return String(title[..<range.lowerBound])
            }
        }
        return title
    }

    /// Extract the hub type identifier from a hub ID for merging across libraries.
    /// Hub IDs are formatted as "plex:{accountId}:{serverId}:{libraryKey}:{hubIdentifier}"
    /// where hubIdentifier is like "music.recent.added.3". The trailing section number
    /// is stripped so hubs from different libraries can be grouped together.
    private static nonisolated func hubTypeIdentifier(from hubId: String) -> String {
        // Extract the hubIdentifier portion (after the 4th colon)
        let components = hubId.split(separator: ":")
        if components.count >= 5 {
            // hubIdentifier is everything after the 4th ":"
            let hubIdentifier = components[4...].joined(separator: ":")
            // Strip trailing section number (e.g. "music.recent.added.3" -> "music.recent.added")
            if let lastDot = hubIdentifier.lastIndex(of: ".") {
                let suffix = hubIdentifier[hubIdentifier.index(after: lastDot)...]
                if suffix.allSatisfy(\.isNumber) {
                    return String(hubIdentifier[..<lastDot])
                }
            }
            return hubIdentifier
        }
        return hubId
    }

    /// Merge and group hubs by server and hub type identifier.
    /// Uses the stable hubIdentifier (e.g. "music.recent.added") for grouping
    /// rather than title normalization, so dynamic hubs like "More in Pop/Rock"
    /// don't get incorrectly merged.
    private func mergeAndGroupHubs(_ hubs: [Hub]) -> [Hub] {
        // Server key is first 3 components: "plex:{acct}:{srv}"
        func getServerKey(_ hubId: String) -> String {
            let components = hubId.split(separator: ":")
            if components.count >= 3 {
                return "\(components[0]):\(components[1]):\(components[2])"
            }
            return "global"
        }

        // Group hubs by server and hub type identifier to merge libraries on the same server
        var hubGroups: [String: [Hub]] = [:]
        var groupOrder: [String] = []

        for hub in hubs {
            let serverKey = getServerKey(hub.id)
            let typeId = HomeViewModel.hubTypeIdentifier(from: hub.id)
            let groupingKey = "\(serverKey)|\(typeId)"

            if hubGroups[groupingKey] == nil {
                hubGroups[groupingKey] = []
                groupOrder.append(groupingKey)
            }
            hubGroups[groupingKey]?.append(hub)
        }

        var mergedResults: [Hub] = []
        for key in groupOrder {
            guard let group = hubGroups[key] else { continue }

            let firstHub = group[0]
            let serverKey = getServerKey(firstHub.id)
            let normalizedTitle = HomeViewModel.normalizeHubTitle(firstHub.title)

            if group.count == 1 {
                mergedResults.append(Hub(
                    id: firstHub.id,
                    title: normalizedTitle,
                    type: firstHub.type,
                    items: firstHub.items,
                    context: firstHub.context
                ))
            } else {
                // Merge items from all hubs in this group
                var allItems: [HubItem] = []
                var seenItems = Set<String>()

                for hub in group {
                    for item in hub.items {
                        let itemKey = "\(item.id):\(item.sourceCompositeKey)"
                        if !seenItems.contains(itemKey) {
                            allItems.append(item)
                            seenItems.insert(itemKey)
                        }
                    }
                }

                // Sort merged items by dateAdded descending
                allItems.sort { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }

                let typeId = HomeViewModel.hubTypeIdentifier(from: firstHub.id)
                let mergedHub = Hub(
                    id: "\(serverKey):merged:\(typeId)",
                    title: normalizedTitle,
                    type: firstHub.type,
                    items: Array(allItems.prefix(40)),
                    context: firstHub.context
                )
                mergedResults.append(mergedHub)
            }
        }

        return mergedResults
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

    /// Persist failed hub keys to UserDefaults so they survive app restarts
    private func persistFailedHubKeys() {
        UserDefaults.standard.set(Array(failedHubKeys), forKey: Self.failedHubKeysKey)
    }

    /// Clear persisted failed hub keys (on pull-to-refresh or server list change)
    private func clearFailedHubKeys() {
        failedHubKeys.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.failedHubKeysKey)
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

    private func enabledSourceCompositeKeys(from accounts: [PlexAccountConfig]? = nil) -> Set<String> {
        let snapshot = accounts ?? accountManager.plexAccounts
        var keys = Set<String>()
        for account in snapshot {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    keys.insert("plex:\(account.id):\(server.id):\(library.key)")
                }
            }
        }
        return keys
    }

    private static func filterHubsToEnabledSources(
        _ hubs: [Hub],
        enabledSourceCompositeKeys: Set<String>
    ) -> [Hub] {
        guard !enabledSourceCompositeKeys.isEmpty else { return [] }
        return hubs.compactMap { hub in
            let enabledItems = hub.items.filter { enabledSourceCompositeKeys.contains($0.sourceCompositeKey) }
            guard !enabledItems.isEmpty else { return nil }
            return Hub(id: hub.id, title: hub.title, type: hub.type, items: enabledItems)
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
        
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] Reset requested for sourceKey=\(sourceKey)")
        #endif
        hubOrderManager.resetOrder(for: sourceKey)

        // Apply cached default order immediately
        let serverHubs = hubsForServer(sourceKey: sourceKey, in: unfilteredHubs)
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] Applying default order to \(serverHubs.count) server hubs")
        #endif
        let orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
        let orderedSnapshot = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: unfilteredHubs)
        applyHubSnapshot(orderedSnapshot, deferIfInteracting: false, source: "resetOrder")

        // Clear debounce and reload hubs to show the reset order
        lastLoadTime = nil
        
        // Reload hubs to get fresh data from server
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] Triggering background refresh from server")
        #endif
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
        stopPeriodicRefresh()  // Stop any existing timer
        
        #if DEBUG
        EnsembleLogger.debug("⏰ Starting periodic hub refresh (every 10 minutes)")
        #endif
        hubRefreshTimer = Timer.scheduledTimer(withTimeInterval: hubRefreshInterval, repeats: true) { [weak self] _ in
            // No [weak self] here — the outer Timer closure already captures self weakly
            Task { @MainActor in
                guard let self = self else { return }
                
                // Don't refresh if offline
                guard !self.syncCoordinator.isOffline else {
                    #if DEBUG
                    EnsembleLogger.debug("📴 Offline - skipping periodic hub refresh")
                    #endif
                    return
                }

                guard self.isViewVisible else { return }
                
                #if DEBUG
                EnsembleLogger.debug("⏰ Periodic hub refresh triggered")
                #endif
                self.requestAutoRefresh(reason: .periodicTimer)
            }
        }
    }
    
    /// Stop periodic hub refresh
    public func stopPeriodicRefresh() {
        hubRefreshTimer?.invalidate()
        hubRefreshTimer = nil
        #if DEBUG
        EnsembleLogger.debug("🛑 Stopped periodic hub refresh")
        #endif
    }
}
