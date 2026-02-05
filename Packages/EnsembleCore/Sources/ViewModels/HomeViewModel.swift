import Combine
import EnsembleAPI
import Foundation

@MainActor
public final class HomeViewModel: ObservableObject {
    @Published public private(set) var hubs: [Hub] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubRepository: HubRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastLoadTime: Date?
    
    // Debounce interval to prevent rapid successive loads
    private let debounceInterval: TimeInterval = 2.0
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        hubRepository: HubRepositoryProtocol
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubRepository = hubRepository
        
        // Load cached hubs immediately if available
        Task { @MainActor in
            if let cached = try? await hubRepository.fetchHubs(), !cached.isEmpty {
                print("🏠 HomeViewModel: Loaded \(cached.count) hubs from cache")
                self.hubs = cached
            }
        }
        
        // Reload when accounts change (e.g. after initial load from keychain)
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accounts in
                print("🏠 HomeViewModel: Accounts changed (count: \(accounts.count)), triggering load")
                Task { @MainActor in
                    await self?.loadHubs()
                }
            }
            .store(in: &cancellables)
        
        // Auto-reload when sync completes (with debouncing)
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] syncing in
                if !syncing {
                    print("🏠 HomeViewModel: Sync completed, triggering load")
                    Task { @MainActor in
                        await self?.loadHubs()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    /// Load hubs only if enough time has passed since last load (debouncing)
    private func loadHubsIfNeeded() async {
        await loadHubs()
    }
    
    /// Load hubs from all configured accounts
    public func loadHubs() async {
        let loadStartTime = Date()
        print("🏠 HomeViewModel.loadHubs() called at \(loadStartTime)")
        
        // Check if we should debounce
        if let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < debounceInterval {
            print("🏠 HomeViewModel: Skipping load due to debounce (last load: \(Date().timeIntervalSince(lastLoad))s ago)")
            return
        }
        
        // Cancel any existing load task
        loadTask?.cancel()
        
        // Record load time for debouncing
        lastLoadTime = Date()
        
        print("🏠 HomeViewModel: Creating load task...")
        
        // Create a new load task that runs off the main actor
        loadTask = Task { @MainActor in
            print("🏠 HomeViewModel: Load task started on main actor")
            isLoading = true
            error = nil
            
            // We DON'T clear hubs here if we already have some (from cache)
            // to avoid flickering. They will be replaced/updated as we fetch new ones.
            
            print("🏠 HomeViewModel: Starting to load hubs...")
            print("🏠 AccountManager has \(accountManager.plexAccounts.count) accounts")
            
            // Capture clients and library info on main actor BEFORE entering detached task
            // This ensures we reuse the cached API clients (with their active connections)
            // instead of creating new ones that would have to re-negotiate failover
            var fetchTasks: [(sourceKey: String, client: PlexAPIClient, sectionKey: String)] = []
            
            for account in accountManager.plexAccounts {
                print("🏠 Processing account: \(account.username) (ID: \(account.id)) with \(account.servers.count) servers")
                for server in account.servers {
                    // Reuse cached client from AccountManager
                    guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                        print("🏠 Could not create/retrieve API client for server: \(server.name)")
                        continue
                    }
                    
                    let enabledLibraries = server.libraries.filter { $0.isEnabled }
                    print("🏠 Server: \(server.name) has \(server.libraries.count) libraries (\(enabledLibraries.count) enabled)")
                    
                    for library in enabledLibraries {
                        let sourceKey = "\(account.id):\(server.id):\(library.key)"
                        fetchTasks.append((sourceKey, client, library.key))
                    }
                }
            }
            
            print("🏠 Prepared \(fetchTasks.count) fetch tasks")
            
            // Perform the actual loading in a detached task to avoid blocking UI
            print("🏠 HomeViewModel: Creating detached task for hub fetching...")
            let fetchedHubs = await Task.detached(priority: .userInitiated) { 
                print("🏠 HomeViewModel: Detached task started (off main actor)")
                
                var collectedHubs: [Hub] = []
                
                // 1. Process each fetch task (section-specific hubs)
                for task in fetchTasks {
                    print("🏠 Fetching hubs for source: \(task.sourceKey)")
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
                        print("❌ Error loading hubs for \(task.sourceKey): \(error.localizedDescription)")
                    }
                }
                
                // 2. Fallback to global hubs if needed
                if collectedHubs.count < 3 {
                    print("🏠 Few hubs found, fetching global hubs...")
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
                            print("❌ Error loading global hubs: \(error.localizedDescription)")
                        }
                    }
                }
                
                return collectedHubs
            }.value
            
            // Update UI all at once to avoid flickering
            if !fetchedHubs.isEmpty {
                self.hubs = fetchedHubs
            }
            
            isLoading = false
            let loadEndTime = Date()
            print("🏠 HomeViewModel: Load task completed in \(loadEndTime.timeIntervalSince(loadStartTime))s")
            
            // Persist to cache
            let hubsToCache = hubs
            Task.detached(priority: .background) { [hubRepository] in
                try? await hubRepository.saveHubs(hubsToCache)
                print("🏠 HomeViewModel: Hubs persisted to cache")
            }
        }
        
        print("🏠 HomeViewModel: Awaiting load task...")
        await loadTask?.value
        print("🏠 HomeViewModel: loadHubs() returning")
    }
    
    /// Refresh hubs
    public func refresh() async {
        await loadHubs()
    }
}
