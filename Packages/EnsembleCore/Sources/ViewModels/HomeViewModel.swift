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
            if let cached = try? await hubRepository.fetchHubs(), !cached.isEmpty {
                self.hubs = cached
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
        print("[HubOrder] loadHubs applySavedOrder=\(applySavedOrder) sourceKey=\(currentSourceKey ?? "nil")")
        
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
                        let sourceKey = "\(account.id):\(server.id):\(library.key)"
                        fetchTasks.append((sourceKey, client, library.key))
                    }
                }
            }
            
            // Perform loading in detached task to avoid blocking UI
            let fetchedHubs = await Task.detached(priority: .userInitiated) { 
                var collectedHubs: [Hub] = []
                
                // Fetch section-specific hubs
                for task in fetchTasks {
                    do {
                        let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey)
                        
                        for plexHub in plexHubs {
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
                                collectedHubs.append(Hub(
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
                }
                
                // Fallback to global hubs if few section hubs found
                if collectedHubs.count < 3 {
                    var handledServers = Set<String>()
                    for task in fetchTasks {
                        let serverId = task.sourceKey.split(separator: ":").prefix(2).joined(separator: ":")
                        if handledServers.contains(serverId) { continue }
                        handledServers.insert(serverId)
                        
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
                                    collectedHubs.append(Hub(
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
                    }
                }
                
                return collectedHubs
            }.value
            
            print("[HubOrder] Fetched hubs count=\(fetchedHubs.count)")
            
            if let sourceKey = currentSourceKey {
                let defaultHubs = hubsForServer(sourceKey: sourceKey, in: fetchedHubs)
                hubOrderManager.saveDefaultOrder(defaultHubs.map { $0.id }, for: sourceKey)
            }
            
            // Apply saved or default order to the fetched hubs
            let orderedHubs: [Hub]
            if let sourceKey = currentSourceKey {
                let serverHubs = hubsForServer(sourceKey: sourceKey, in: fetchedHubs)
                let orderedServerHubs: [Hub]
                
                if applySavedOrder {
                    orderedServerHubs = hubOrderManager.applyOrder(to: serverHubs, for: sourceKey)
                } else {
                    orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
                }
                
                orderedHubs = mergeOrderedServerHubs(
                    orderedServerHubs,
                    sourceKey: sourceKey,
                    into: fetchedHubs
                )
            } else {
                orderedHubs = fetchedHubs
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
        
        print("[HubOrder] Reset requested for sourceKey=\(sourceKey)")
        hubOrderManager.resetOrder(for: sourceKey)

        let serverHubs = hubsForServer(sourceKey: sourceKey, in: hubs)
        let orderedServerHubs = hubOrderManager.applyDefaultOrder(to: serverHubs, for: sourceKey)
        hubs = mergeOrderedServerHubs(orderedServerHubs, sourceKey: sourceKey, into: hubs)
        if isEditingOrder {
            editableHubs = hubs
        }

        // Clear debounce and reload hubs to show the reset order
        lastLoadTime = nil
        
        // Reload hubs to show the reset order
        Task {
            await loadHubs(applySavedOrder: false)
            if isEditingOrder {
                editableHubs = hubs
            }
        }
    }
}

