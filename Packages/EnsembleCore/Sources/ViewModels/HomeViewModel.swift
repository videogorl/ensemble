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
    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var lastLoadTime: Date?
    
    // Debounce interval to prevent rapid successive loads
    private let debounceInterval: TimeInterval = 2.0
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        
        // Auto-reload when sync completes (with debouncing)
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
            
            print("🏠 HomeViewModel: Starting to load hubs...")
            
            // Capture accounts on main actor BEFORE entering detached task
            let accounts = accountManager.plexAccounts
            print("🏠 Accounts count: \(accounts.count)")
            
            // Perform the actual loading in a detached task to avoid blocking UI
            print("🏠 HomeViewModel: Creating detached task for hub fetching...")
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[Hub], Error> in
                print("🏠 HomeViewModel: Detached task started (off main actor)")
                var allHubs: [Hub] = []
                
                // Fetch hubs from each Plex account (using captured accounts)
                for account in accounts {
                    print("🏠 Processing account: \(account.username)")
                    for server in account.servers {
                        print("🏠 Processing server: \(server.name)")
                        for library in server.libraries where library.isEnabled {
                            print("🏠 Processing library: \(library.title)")
                            do {
                                // Create API client for this library
                                let connection = PlexServerConnection(
                                    url: server.url,
                                    token: account.authToken,
                                    identifier: server.id,
                                    name: server.name
                                )
                                
                                let librarySelection = PlexLibrarySelection(
                                    key: library.key,
                                    title: library.title
                                )
                                
                                let apiClient = PlexAPIClient(
                                    connection: connection,
                                    librarySelection: librarySelection
                                )
                                
                                // Fetch hubs
                                print("🏠 Fetching hubs for \(library.title)...")
                                let plexHubs = try await apiClient.getHubs(sectionKey: library.key)
                                print("🏠 Received \(plexHubs.count) hubs")
                                
                                // Convert to domain models (limit to first 10 items per hub)
                                let sourceKey = "\(account.id):\(server.id):\(library.key)"
                                
                                for plexHub in plexHubs {
                                    // Fetch items for this hub (limited)
                                    let hubItems: [HubItem]
                                    if let metadata = plexHub.metadata {
                                        hubItems = Array(metadata.prefix(10)).map { 
                                            HubItem(from: $0, sourceKey: sourceKey)
                                        }
                                        print("🏠 Hub '\(plexHub.title)': \(hubItems.count) items")
                                    } else {
                                        hubItems = []
                                        print("🏠 Hub '\(plexHub.title)': no metadata")
                                    }
                                    
                                    let hub = Hub(
                                        id: plexHub.hubIdentifier,
                                        title: plexHub.title,
                                        type: plexHub.type,
                                        items: hubItems
                                    )
                                    
                                    allHubs.append(hub)
                                }
                            } catch {
                                print("❌ Error loading hubs for \(library.title): \(error.localizedDescription)")
                                // Continue with other libraries even if one fails
                            }
                        }
                    }
                }
                
                print("🏠 Total hubs loaded: \(allHubs.count)")
                return .success(allHubs)
            }.value
            
            // Update UI on main actor with results
            print("🏠 HomeViewModel: Updating UI with results...")
            switch result {
            case .success(let loadedHubs):
                hubs = loadedHubs
                print("🏠 HomeViewModel: UI updated with \(loadedHubs.count) hubs")
            case .failure(let loadError):
                error = "Failed to load hubs: \(loadError.localizedDescription)"
                print("🏠 HomeViewModel: UI updated with error")
            }
            
            isLoading = false
            let loadEndTime = Date()
            print("🏠 HomeViewModel: Load task completed in \(loadEndTime.timeIntervalSince(loadStartTime))s")
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
