import Combine
import EnsembleAPI
import Foundation

/// ViewModel for the Home screen that displays dynamic content hubs from Plex servers
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
    public func loadHubs() async {
        // Check if we should debounce
        if let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < debounceInterval {
            return
        }
        
        // Cancel any existing load task
        loadTask?.cancel()
        
        // Record load time for debouncing
        lastLoadTime = Date()
        
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
            
            // Update UI all at once to avoid flickering
            if !fetchedHubs.isEmpty {
                self.hubs = fetchedHubs
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
}
