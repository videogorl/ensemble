import Combine
import EnsembleAPI
import Foundation

/// ViewModel for the Home screen that displays dynamic content hubs from Plex servers
@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var hubs: [Hub] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    
    // Edit mode state
    @Published public var isEditingOrder = false
    @Published public var editableHubs: [Hub] = []
    @Published public private(set) var currentSourceName: String = ""
    
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubRepository: HubRepositoryProtocol
    private let hubOrderManager: HubOrderManager
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastLoadTime: Date?
    private var currentSourceKey: String?
    
    // Periodic hub refresh
    private var hubRefreshTimer: Timer?
    private let hubRefreshInterval: TimeInterval = 10 * 60  // 10 minutes
    
    // Debounce interval to prevent rapid successive loads
    private let debounceInterval: TimeInterval = 2.0
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        hubRepository: HubRepositoryProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager()
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubRepository = hubRepository
        self.hubOrderManager = hubOrderManager
        
        // Load cached hubs immediately for offline-first experience
        Task { @MainActor in
            do {
                let cached = try await hubRepository.fetchHubs()
                if !cached.isEmpty {
                    // Apply saved custom order to cached hubs
                    updateCurrentSource()
                    if let sourceKey = currentSourceKey {
                        let serverHubs = hubsForServer(sourceKey: sourceKey, in: cached)
                        let orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                        self.hubs = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: cached)
                        #if DEBUG
                        EnsembleLogger.debug("[HubOrder] Applied saved order to \(serverHubs.count) cached hubs")
                        #endif
                    } else {
                        self.hubs = cached
                    }
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("[HomeViewModel] Failed to load cached hubs: \(error.localizedDescription)")
                #endif
            }
        }
        
        // Reload when accounts change
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadHubs()
                }
            }
            .store(in: &cancellables)
        
        // Auto-reload when sync completes
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] syncing in
                if !syncing {
                    Task { @MainActor in
                        await self?.loadHubs()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    deinit {
        // Invalidate timer directly without calling @MainActor method from nonisolated deinit
        hubRefreshTimer?.invalidate()
    }
    
    /// Load hubs from all configured accounts with debouncing and offline-first caching
    public func loadHubs(applySavedOrder: Bool = true) async {
        // Check if we should debounce
        if let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < debounceInterval {
            return
        }
        
        // Cancel any existing load task
        loadTask?.cancel()
        
        // Record load time for debouncing
        lastLoadTime = Date()
        
        // Identify the primary source key and name for ordering
        updateCurrentSource()
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] loadHubs applySavedOrder=\(applySavedOrder) sourceKey=\(currentSourceKey ?? "nil")")
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
            
            // Perform loading with parallel fetching and progressive UI updates
            // Use TaskGroup for parallel fetching of hubs
            var collectedHubs: [Hub] = []

            await withTaskGroup(of: [Hub].self) { group in
                // Fetch section-specific hubs in parallel
                for task in fetchTasks {
                    group.addTask {
                        var hubs: [Hub] = []
                        do {
                            let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey)

                            // Process hub items in parallel
                            await withTaskGroup(of: Hub?.self) { hubGroup in
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
                                            if let metadata = try? await task.client.getHubItems(hubKey: key) {
                                                let filteredMetadata = metadata.filter { item in
                                                    let type = item.type?.lowercased() ?? ""
                                                    return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                                                }
                                                hubItems = Array(filteredMetadata.prefix(12)).map { HubItem(from: $0, sourceKey: task.sourceKey) }
                                            }
                                        }

                                        if !hubItems.isEmpty {
                                            return Hub(
                                                id: hubId,
                                                title: plexHub.title,
                                                type: plexHub.type ?? "mixed",
                                                items: hubItems
                                            )
                                        }
                                        return nil
                                    }
                                }

                                for await hub in hubGroup {
                                    if let hub = hub {
                                        hubs.append(hub)
                                    }
                                }
                            }
                        } catch {
                            // Silently continue on error
                        }
                        return hubs
                    }
                }

                // Collect hubs progressively and update UI
                for await hubs in group {
                    collectedHubs.append(contentsOf: hubs)

                    // Progressive UI update: merge and display hubs as they arrive
                    await MainActor.run {
                        if !hubs.isEmpty {
                            // Merge collected hubs so far
                            let progressiveResult = self.mergeAndGroupHubs(collectedHubs)

                            // Apply ordering if needed
                            let displayHubs: [Hub]
                            if let sourceKey = currentSourceKey {
                                let serverHubs = hubsForServer(sourceKey: sourceKey, in: progressiveResult)
                                let orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                                displayHubs = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: progressiveResult)
                            } else {
                                displayHubs = progressiveResult
                            }

                            self.hubs = displayHubs
                        }
                    }
                }
            }

            let fetchedHubs = collectedHubs

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
                                                items: hubItems
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
            
            // Update UI all at once to avoid flickering
            if !orderedHubs.isEmpty {
                self.hubs = orderedHubs
            }
            
            isLoading = false
            
            // Persist to cache for offline access
            let hubsToCache = hubs
            Task.detached(priority: .background) { [hubRepository] in
                try? await hubRepository.saveHubs(hubsToCache)
            }
        }
        
        await loadTask?.value
    }
    
    /// Refresh hubs (clears debounce to force immediate reload)
    public func refresh() async {
        lastLoadTime = nil
        await loadHubs()
    }
    
    /// Normalize hub titles to allow merging across libraries (e.g. "Recently Added in Music" -> "Recently Added")
    private static nonisolated func normalizeHubTitle(_ title: String) -> String {
        var normalized = title

        // Remove " in [Library Name]" pattern (e.g. "Recently Added in Music")
        if let range = normalized.range(of: " in ", options: .backwards) {
            normalized = String(normalized[..<range.lowerBound])
        }

        return normalized
    }

    /// Merge and group hubs by server and normalized title
    private func mergeAndGroupHubs(_ hubs: [Hub]) -> [Hub] {
        // Helper to get server key
        func getServerKey(_ hubId: String) -> String {
            let components = hubId.split(separator: ":")
            if components.count >= 2 {
                return "\(components[0]):\(components[1])"
            }
            return "global"
        }

        // Group hubs by server and normalized title to merge libraries on the same server
        var hubGroups: [String: [Hub]] = [:]
        var groupOrder: [String] = []

        for hub in hubs {
            let serverKey = getServerKey(hub.id)
            let normalizedTitle = HomeViewModel.normalizeHubTitle(hub.title)
            let groupingKey = "\(serverKey)|\(normalizedTitle)"

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
                // Even if not merged, use normalized title for consistency
                mergedResults.append(Hub(
                    id: firstHub.id,
                    title: normalizedTitle,
                    type: firstHub.type,
                    items: firstHub.items
                ))
            } else {
                // Merge items from all hubs in group
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

                // Create merged hub with a stable ID for ordering
                let mergedHub = Hub(
                    id: "\(serverKey):merged:\(normalizedTitle)",
                    title: normalizedTitle,
                    type: firstHub.type,
                    items: Array(allItems.prefix(40)) // Higher limit for merged hubs
                )
                mergedResults.append(mergedHub)
            }
        }

        return mergedResults
    }
    
    // MARK: - Edit Mode
    
    private func serverKey(from hubId: String) -> String? {
        let components = hubId.split(separator: ":")
        guard components.count >= 2 else { return nil }
        return "\(components[0]):\(components[1])"
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
    
    /// Determine the primary source key (first enabled server) and its display name
    private func updateCurrentSource() {
        let servers = accountManager.plexAccounts.flatMap { $0.servers }
        let hasMultipleServers = servers.count > 1

        for account in accountManager.plexAccounts {
            for server in account.servers {
                let enabledLibraries = server.libraries.filter { $0.isEnabled }
                if !enabledLibraries.isEmpty {
                    currentSourceKey = "\(account.id):\(server.id)"
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
        let serverHubs = hubsForServer(sourceKey: sourceKey, in: hubs)
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] Applying default order to \(serverHubs.count) server hubs")
        #endif
        let orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
        hubs = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: hubs)
        if isEditingOrder {
            editableHubs = hubs
        }

        // Clear debounce and reload hubs to show the reset order
        lastLoadTime = nil
        
        // Reload hubs to get fresh data from server
        #if DEBUG
        EnsembleLogger.debug("[HubOrder] Triggering background refresh from server")
        #endif
        Task {
            await loadHubs(applySavedOrder: false)
            if isEditingOrder {
                editableHubs = hubs
            }
        }
    }
    
    // MARK: - Periodic Refresh
    
    /// Start periodic hub refresh (every 10 minutes while app is active)
    public func startPeriodicRefresh() {
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
                
                #if DEBUG
                EnsembleLogger.debug("⏰ Periodic hub refresh triggered")
                #endif
                await self.refresh()
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

