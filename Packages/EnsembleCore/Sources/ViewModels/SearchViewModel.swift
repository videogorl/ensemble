import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Search section types for intelligent ordering
public enum SearchSection: String, CaseIterable {
    case artists
    case albums
    case playlists
    case songs
    
    public var displayTitle: String {
        switch self {
        case .artists: return "Artists"
        case .albums: return "Albums"
        case .playlists: return "Playlists"
        case .songs: return "Songs"
        }
    }
}

@MainActor
public final class SearchViewModel: ObservableObject {
    // MARK: - Search Results
    
    @Published public var searchQuery = ""
    @Published public private(set) var trackResults: [Track] = []
    @Published public private(set) var artistResults: [Artist] = []
    @Published public private(set) var albumResults: [Album] = []
    @Published public private(set) var playlistResults: [Playlist] = []
    @Published public private(set) var orderedSections: [SearchSection] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var searchError: String?
    
    // MARK: - Explore Content
    
    @Published public private(set) var recentlyPlayedAlbums: [Album] = []
    @Published public private(set) var recentlyPlayedArtists: [Artist] = []
    @Published public private(set) var recentlyAddedAlbums: [Album] = []
    @Published public private(set) var recommendedItems: [HubItem] = []
    @Published public private(set) var allGenres: [Genre] = []
    @Published public private(set) var isLoadingExplore = false
    @Published public private(set) var exploreError: String?
    
    // Legacy support
    public var results: [Track] { trackResults }
    
    public let focusRequested = PassthroughSubject<Void, Never>()

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let hubRepository: HubRepositoryProtocol
    private let accountManager: AccountManager
    private var searchTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastExploreLoadTime: Date?
    private let exploreDebounceInterval: TimeInterval = 2.0

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        hubRepository: HubRepositoryProtocol,
        accountManager: AccountManager
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.hubRepository = hubRepository
        self.accountManager = accountManager

        // Debounced search
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
        
        // Reload explore content when accounts change
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadExploreContent()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Search
    
    private func performSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            isSearching = false
            searchError = nil
            trackResults = []
            artistResults = []
            albumResults = []
            playlistResults = []
            orderedSections = []
            return
        }

        searchTask = Task {
            await search(query: trimmed)
        }
    }

    public func search(query: String) async {
        isSearching = true
        searchError = nil

        do {
            async let localTracks = libraryRepository.searchTracks(query: query)
            async let localArtists = libraryRepository.searchArtists(query: query)
            async let localAlbums = libraryRepository.searchAlbums(query: query)
            async let localPlaylists = playlistRepository.searchPlaylists(query: query)
            
            let (tracks, artists, albums, playlists) = try await (localTracks, localArtists, localAlbums, localPlaylists)
            
            trackResults = tracks.map { Track(from: $0) }
            artistResults = artists.map { Artist(from: $0) }
            albumResults = albums.map { Album(from: $0) }
            playlistResults = playlists.map { Playlist(from: $0) }
            
            // Determine intelligent section ordering based on match count
            determineSearchSectionOrder()
        } catch {
            if !Task.isCancelled {
                self.searchError = error.localizedDescription
            }
        }

        isSearching = false
    }
    
    /// Intelligently orders search sections based on match count (most results first)
    private func determineSearchSectionOrder() {
        var sectionCounts: [(section: SearchSection, count: Int)] = [
            (.artists, artistResults.count),
            (.albums, albumResults.count),
            (.playlists, playlistResults.count),
            (.songs, trackResults.count)
        ]
        
        // Sort by count descending, then by default order
        sectionCounts.sort { lhs, rhs in
            if lhs.count == rhs.count {
                // Default order: Artists, Albums, Playlists, Songs
                return SearchSection.allCases.firstIndex(of: lhs.section)! < SearchSection.allCases.firstIndex(of: rhs.section)!
            }
            return lhs.count > rhs.count
        }
        
        // Only include sections with results
        orderedSections = sectionCounts.filter { $0.count > 0 }.map { $0.section }
    }

    public func clearSearch() {
        searchQuery = ""
        trackResults = []
        artistResults = []
        albumResults = []
        playlistResults = []
        orderedSections = []
    }
    
    public func requestFocus() {
        focusRequested.send()
    }
    
    // MARK: - Explore Content
    
    /// Load explore content only if data is empty (avoids reloading on each navigation)
    public func loadExploreContentIfNeeded() async {
        // Don't reload if we already have data
        guard recentlyPlayedAlbums.isEmpty &&
              recentlyPlayedArtists.isEmpty &&
              recentlyAddedAlbums.isEmpty &&
              recommendedItems.isEmpty &&
              allGenres.isEmpty else {
            return
        }
        
        await loadExploreContent()
    }
    
    /// Load explore content with offline-first approach: load cached data, then fetch fresh
    public func loadExploreContent() async {
        // Check if we should debounce
        if let lastLoad = lastExploreLoadTime,
           Date().timeIntervalSince(lastLoad) < exploreDebounceInterval {
            return
        }
        
        // Cancel any existing load task
        exploreTask?.cancel()
        
        // Record load time for debouncing
        lastExploreLoadTime = Date()
        
        // Create a new load task
        exploreTask = Task { @MainActor in
            isLoadingExplore = true
            exploreError = nil
            
            // Step 1: Load cached hubs for offline-first experience
            do {
                let cachedHubs = try await hubRepository.fetchHubs()
                let (albums, artists, added, recommended) = extractContentFromHubs(cachedHubs)
                self.recentlyPlayedAlbums = Array(albums.prefix(6))
                self.recentlyPlayedArtists = Array(artists.prefix(6))
                self.recentlyAddedAlbums = Array(added.prefix(6))
                self.recommendedItems = Array(recommended.prefix(6))
            } catch {
                // Silently continue - no cached data available
                print("ℹ️ No cached explore content available")
            }
            
            // Capture API clients on main actor before entering detached task
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
            
            // Step 2: Fetch fresh data from server in background and update cache
            await Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else { return }
                
                // Fetch hubs from each source
                var freshHubs: [Hub] = []
                var recentAlbums: [Album] = []
                var recentArtists: [Artist] = []
                var addedAlbums: [Album] = []
                var recommendedHubItems: [HubItem] = []
                
                for task in fetchTasks {
                    do {
                        let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey)
                        
                        for plexHub in plexHubs {
                            let title = plexHub.title.lowercased()
                            
                            // Extract metadata from hub
                            var metadata: [PlexHubMetadata] = []
                            if let existing = plexHub.metadata, !existing.isEmpty {
                                metadata = existing
                            } else if let key = plexHub.key ?? plexHub.hubKey {
                                if let items = try? await task.client.getHubItems(hubKey: key) {
                                    metadata = items
                                }
                            }
                            
                            // Filter to music-only content
                            let filteredMetadata = metadata.filter { item in
                                let type = item.type?.lowercased() ?? ""
                                return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                            }
                            
                            // Convert to HubItems and create Hub for caching
                            let hubItems = filteredMetadata.map { HubItem(from: $0, sourceKey: task.sourceKey) }
                            freshHubs.append(Hub(
                                id: plexHub.key ?? plexHub.hubKey ?? UUID().uuidString,
                                title: plexHub.title,
                                type: plexHub.type ?? "mixed",
                                items: hubItems
                            ))
                            
                            // Categorize hubs for UI display
                            if title.contains("recently played") || title.contains("recent plays") {
                                // Extract albums and artists from Recently Played
                                for item in hubItems.prefix(12) {
                                    if let album = item.album {
                                        recentAlbums.append(album)
                                    }
                                    if let artist = item.artist {
                                        recentArtists.append(artist)
                                    }
                                }
                            } else if title.contains("recently added") || title.contains("recent additions") {
                                // Recently Added albums
                                for item in hubItems.prefix(12) {
                                    if let album = item.album {
                                        addedAlbums.append(album)
                                    }
                                }
                            } else if title.contains("recommend") || title.contains("for you") || title.contains("similar") {
                                // Recommended content
                                for item in hubItems.prefix(12) {
                                    recommendedHubItems.append(item)
                                }
                            }
                        }
                    } catch {
                        // Silently continue on error - will use cached data
                        print("⚠️ Failed to fetch hubs: \(error)")
                    }
                }
                
                // Save fresh hubs to cache for offline use
                if !freshHubs.isEmpty {
                    do {
                        try await self.hubRepository.saveHubs(freshHubs)
                        print("✅ Cached \(freshHubs.count) hubs for offline use")
                    } catch {
                        print("⚠️ Failed to cache hubs: \(error)")
                    }
                }
                
                // Update UI on main actor with fresh data
                await MainActor.run {
                    self.recentlyPlayedAlbums = Array(recentAlbums.prefix(6))
                    self.recentlyPlayedArtists = Array(recentArtists.prefix(6))
                    self.recentlyAddedAlbums = Array(addedAlbums.prefix(6))
                    self.recommendedItems = Array(recommendedHubItems.prefix(6))
                    self.isLoadingExplore = false
                }
            }.value
            
            // Fetch all genres from library
            do {
                let genreCDs = try await libraryRepository.fetchGenres()
                self.allGenres = genreCDs.map { Genre(from: $0) }
            } catch {
                // Silently continue if genre fetch fails
            }
        }
    }
    
    /// Extract albums, artists, and items from Hub array
    private func extractContentFromHubs(_ hubs: [Hub]) -> (albums: [Album], artists: [Artist], addedAlbums: [Album], recommendedItems: [HubItem]) {
        var recentAlbums: [Album] = []
        var recentArtists: [Artist] = []
        var addedAlbums: [Album] = []
        var recommendedItems: [HubItem] = []
        
        for hub in hubs {
            let title = hub.title.lowercased()
            
            if title.contains("recently played") || title.contains("recent plays") {
                for item in hub.items.prefix(12) {
                    if let album = item.album {
                        recentAlbums.append(album)
                    }
                    if let artist = item.artist {
                        recentArtists.append(artist)
                    }
                }
            } else if title.contains("recently added") || title.contains("recent additions") {
                for item in hub.items.prefix(12) {
                    if let album = item.album {
                        addedAlbums.append(album)
                    }
                }
            } else if title.contains("recommend") || title.contains("for you") || title.contains("similar") {
                for item in hub.items.prefix(12) {
                    recommendedItems.append(item)
                }
            }
        }
        
        return (recentAlbums, recentArtists, addedAlbums, recommendedItems)
    }
}