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
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        
        // Auto-reload when sync completes
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing {
                    Task { @MainActor in
                        await self?.loadHubs()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    /// Load hubs from all configured accounts
    public func loadHubs() async {
        isLoading = true
        error = nil
        
        var allHubs: [Hub] = []
        
        // Fetch hubs from each Plex account
        for account in accountManager.plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
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
                        let plexHubs = try await apiClient.getHubs(sectionKey: library.key)
                        
                        // Convert to domain models (limit to first 10 items per hub)
                        let sourceKey = "\(account.id):\(server.id):\(library.key)"
                        
                        for plexHub in plexHubs {
                            // Fetch items for this hub (limited)
                            let hubItems: [HubItem]
                            if let metadata = plexHub.metadata {
                                hubItems = Array(metadata.prefix(10)).map { 
                                    HubItem(from: $0, sourceKey: sourceKey)
                                }
                            } else {
                                hubItems = []
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
                        print("Error loading hubs for \(library.title): \(error.localizedDescription)")
                        // Continue with other libraries
                    }
                }
            }
        }
        
        hubs = allHubs
        isLoading = false
    }
    
    /// Refresh hubs
    public func refresh() async {
        await loadHubs()
    }
}
