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

    /// Stable tie-break order for sections with equal match counts.
    public var sortPriority: Int {
        switch self {
        case .artists: return 0
        case .albums: return 1
        case .playlists: return 2
        case .songs: return 3
        }
    }
}

@MainActor
public final class SearchViewModel: ObservableObject {
    // MARK: - Search Results
    
    @Published public var searchQuery = ""
    @Published public private(set) var recentSearches: [String] = []
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
    @Published public private(set) var allMoods: [Mood] = []
    @Published public private(set) var isLoadingExplore = false
    @Published public private(set) var exploreError: String?
    
    // Legacy support
    public var results: [Track] { trackResults }
    
    public let focusRequested = PassthroughSubject<Void, Never>()

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let hubRepository: HubRepositoryProtocol
    private let moodRepository: MoodRepositoryProtocol
    private let accountManager: AccountManager
    private let visibilityStore: LibraryVisibilityStore
    private var searchTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastExploreLoadTime: Date?
    private let exploreDebounceInterval: TimeInterval = 2.0
    private let recentSearchesKey = "ensemble_recent_searches"
    private var commitSearchTask: Task<Void, Never>?
    private var hasLoadedExploreContent = false
    private var unfilteredTrackResults: [Track] = []
    private var unfilteredArtistResults: [Artist] = []
    private var unfilteredAlbumResults: [Album] = []
    private var unfilteredPlaylistResults: [Playlist] = []
    private var unfilteredRecentlyPlayedAlbums: [Album] = []
    private var unfilteredRecentlyPlayedArtists: [Artist] = []
    private var unfilteredRecentlyAddedAlbums: [Album] = []
    private var unfilteredRecommendedItems: [HubItem] = []
    private var unfilteredMoods: [Mood] = []

    public init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        hubRepository: HubRepositoryProtocol,
        moodRepository: MoodRepositoryProtocol,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore? = nil
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.hubRepository = hubRepository
        self.moodRepository = moodRepository
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore ?? .shared
        
        // Load recent searches
        self.recentSearches = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []

        // Debounced search
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
        
        // Separate debouncer for committing to recent searches (longer delay)
        $searchQuery
            .debounce(for: .milliseconds(1500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.commitSearchToHistory(query: query)
            }
            .store(in: &cancellables)
        
        // Reload explore content when accounts change
        accountManager.$plexAccounts
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.hasLoadedExploreContent else { return }
                Task { @MainActor in
                    await self.loadExploreContent()
                }
            }
            .store(in: &cancellables)

        self.visibilityStore.$profiles
            .combineLatest(self.visibilityStore.$activeProfileID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyVisibilityToSearchResults()
                self?.applyVisibilityToExploreContent()
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
            unfilteredTrackResults = []
            unfilteredArtistResults = []
            unfilteredAlbumResults = []
            unfilteredPlaylistResults = []
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
            
            unfilteredTrackResults = tracks.map { Track(from: $0) }
            unfilteredArtistResults = artists.map { Artist(from: $0) }
            unfilteredAlbumResults = albums.map { Album(from: $0) }
            unfilteredPlaylistResults = playlists.map { Playlist(from: $0) }
            applyVisibilityToSearchResults()
        } catch {
            if !Task.isCancelled {
                self.searchError = error.localizedDescription
            }
        }

        isSearching = false
    }

    public func commitCurrentSearch() {
        commitSearchToHistory(query: searchQuery)
    }

    private func commitSearchToHistory(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Only save if there were actual results in the last search
        guard !trackResults.isEmpty || !artistResults.isEmpty || !albumResults.isEmpty || !playlistResults.isEmpty else {
            return
        }
        
        addToRecentSearches(trimmed)
    }
    
    private func addToRecentSearches(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        var current = recentSearches
        
        // Combine similar searches: if existing search is a prefix or contains the new search, 
        // or if new search is a prefix of an existing one, consolidate.
        // User specifically asked: "if I search for tricia, and then tricia brock, just save tricia"
        if let existingIndex = current.firstIndex(where: { existing in
            let e = existing.lowercased()
            let q = trimmed.lowercased()
            return e.contains(q) || q.contains(e)
        }) {
            // Found a similar search.
            // Keep the longer (more specific) one.
            let existing = current[existingIndex]
            if trimmed.count > existing.count {
                // New search is longer/more specific, replace existing
                current.remove(at: existingIndex)
                current.insert(trimmed, at: 0)
            } else {
                // Existing one is longer or equal, keep it but move to top
                let item = current.remove(at: existingIndex)
                current.insert(item, at: 0)
            }
        } else {
            // Brand new search
            current.insert(trimmed, at: 0)
        }
        
        // Keep top 5 and remove duplicates just in case
        var unique: [String] = []
        for item in current {
            if !unique.contains(where: { $0.lowercased() == item.lowercased() }) {
                unique.append(item)
            }
            if unique.count >= 5 { break }
        }
        
        recentSearches = unique
        
        // Persist
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }
    
    public func removeRecentSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        UserDefaults.standard.set(recentSearches, forKey: recentSearchesKey)
    }
    
    public func clearRecentSearches() {
        recentSearches = []
        UserDefaults.standard.removeObject(forKey: recentSearchesKey)
    }
    
    /// Orders search sections with artists always first, then remaining by match count
    private func determineSearchSectionOrder() {
        var sectionCounts: [(section: SearchSection, count: Int)] = [
            (.artists, artistResults.count),
            (.albums, albumResults.count),
            (.playlists, playlistResults.count),
            (.songs, trackResults.count)
        ]

        // Artists always first, then sort remaining by count descending, with default order as tiebreaker
        sectionCounts.sort { lhs, rhs in
            // Artists always come first
            if lhs.section == .artists { return true }
            if rhs.section == .artists { return false }

            if lhs.count == rhs.count {
                // Default order for non-artist sections: Albums, Playlists, Songs
                return lhs.section.sortPriority < rhs.section.sortPriority
            }
            return lhs.count > rhs.count
        }

        // Only include sections with results
        orderedSections = sectionCounts.filter { $0.count > 0 }.map { $0.section }
    }

    private func applyVisibilityToSearchResults() {
        let hiddenSourceCompositeKeys = visibilityStore.hiddenSourceCompositeKeys
        trackResults = Self.filterTracksForVisibility(
            unfilteredTrackResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        artistResults = Self.filterArtistsForVisibility(
            unfilteredArtistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        albumResults = Self.filterAlbumsForVisibility(
            unfilteredAlbumResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        playlistResults = Self.filterPlaylistsForVisibility(
            unfilteredPlaylistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        determineSearchSectionOrder()
    }

    private func applyVisibilityToExploreContent() {
        let hiddenSourceCompositeKeys = visibilityStore.hiddenSourceCompositeKeys
        recentlyPlayedAlbums = Self.filterAlbumsForVisibility(
            unfilteredRecentlyPlayedAlbums,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        recentlyPlayedArtists = Self.filterArtistsForVisibility(
            unfilteredRecentlyPlayedArtists,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        recentlyAddedAlbums = Self.filterAlbumsForVisibility(
            unfilteredRecentlyAddedAlbums,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        recommendedItems = Self.filterHubItemsForVisibility(
            unfilteredRecommendedItems,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        allMoods = Self.filterMoodsForVisibility(
            unfilteredMoods,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
    }

    internal static func filterTracksForVisibility(
        _ tracks: [Track],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Track] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return tracks }
        return tracks.filter { track in
            guard let sourceKey = track.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterArtistsForVisibility(
        _ artists: [Artist],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Artist] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return artists }
        return artists.filter { artist in
            guard let sourceKey = artist.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterAlbumsForVisibility(
        _ albums: [Album],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Album] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return albums }
        return albums.filter { album in
            guard let sourceKey = album.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterPlaylistsForVisibility(
        _ playlists: [Playlist],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Playlist] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return playlists }
        return playlists.filter { playlist in
            guard let sourceKey = playlist.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    internal static func filterHubItemsForVisibility(
        _ items: [HubItem],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [HubItem] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return items }
        return items.filter { !hiddenSourceCompositeKeys.contains($0.sourceCompositeKey) }
    }

    internal static func filterMoodsForVisibility(
        _ moods: [Mood],
        hiddenSourceCompositeKeys: Set<String>
    ) -> [Mood] {
        guard !hiddenSourceCompositeKeys.isEmpty else { return moods }
        return moods.filter { mood in
            guard let sourceKey = mood.sourceCompositeKey else { return true }
            return !hiddenSourceCompositeKeys.contains(sourceKey)
        }
    }

    public func clearSearch() {
        searchQuery = ""
        unfilteredTrackResults = []
        unfilteredArtistResults = []
        unfilteredAlbumResults = []
        unfilteredPlaylistResults = []
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
              allMoods.isEmpty else {
            return
        }
        
        await loadExploreContent()
    }
    
    /// Load explore content with offline-first approach: load cached data, then fetch fresh
    public func loadExploreContent() async {
        hasLoadedExploreContent = true

        // Check if we should debounce
        if let lastLoad = lastExploreLoadTime,
           Date().timeIntervalSince(lastLoad) < exploreDebounceInterval {
            return
        }
        
        // Cancel any existing load task
        exploreTask?.cancel()
        
        // Record load time for debouncing
        lastExploreLoadTime = Date()

        exploreTask = Task { [weak self] in
            guard let self else { return }
            await self.loadExploreContentInternal()
        }

        await exploreTask?.value
    }

    private func loadExploreContentInternal() async {
        isLoadingExplore = false  // Show cached data immediately, don't block on loading state
        exploreError = nil

        // Load cached hubs first for fast offline-first rendering.
        do {
            let cachedHubs = try await hubRepository.fetchHubs()
            let results = extractContentFromHubs(cachedHubs)
            unfilteredRecentlyPlayedAlbums = Array(results.albums.prefix(6))
            unfilteredRecentlyPlayedArtists = Array(results.artists.prefix(6))
            unfilteredRecentlyAddedAlbums = Array(results.addedAlbums.prefix(6))
            unfilteredRecommendedItems = Array(results.recommendedItems.prefix(6))
            applyVisibilityToExploreContent()
        } catch {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ No cached explore content available")
            #endif
        }

        // Load cached moods immediately while fresh network fetch runs.
        if let cachedMoods = try? await moodRepository.fetchMoods(), !cachedMoods.isEmpty {
            unfilteredMoods = cachedMoods
            applyVisibilityToExploreContent()
        }

        guard !Task.isCancelled else { return }

        let fetchTasks = buildExploreFetchTasks()
        guard !fetchTasks.isEmpty else { return }

        // Fetch fresh hubs from all enabled libraries.
        var freshHubs: [Hub] = []
        var recentAlbums: [Album] = []
        var recentArtists: [Artist] = []
        var addedAlbums: [Album] = []
        var recommendedHubItems: [HubItem] = []

        for task in fetchTasks {
            guard !Task.isCancelled else { return }
            do {
                let plexHubs = try await task.client.getHubs(sectionKey: task.sectionKey)

                for plexHub in plexHubs {
                    guard !Task.isCancelled else { return }
                    let title = plexHub.title.lowercased()

                    var metadata: [PlexHubMetadata] = []
                    if let existing = plexHub.metadata, !existing.isEmpty {
                        metadata = existing
                    } else if let key = plexHub.key ?? plexHub.hubKey,
                              let items = try? await task.client.getHubItems(hubKey: key) {
                        metadata = items
                    }

                    let filteredMetadata = metadata.filter { item in
                        let type = item.type?.lowercased() ?? ""
                        return type.isEmpty || type == "track" || type == "album" || type == "artist" || type == "playlist" || type == "music" || type == "audio"
                    }

                    let hubItems = filteredMetadata.map { HubItem(from: $0, sourceKey: task.sourceKey) }
                    let hubId = "\(task.sourceKey):\(plexHub.id)"
                    freshHubs.append(
                        Hub(
                            id: hubId,
                            title: plexHub.title,
                            type: plexHub.type ?? "mixed",
                            items: hubItems
                        )
                    )

                    if title.contains("recently played") || title.contains("recent plays") {
                        for item in hubItems.prefix(12) {
                            if let album = item.album {
                                recentAlbums.append(album)
                            }
                            if let artist = item.artist {
                                recentArtists.append(artist)
                            }
                        }
                    } else if title.contains("recently added") || title.contains("recent additions") {
                        for item in hubItems.prefix(12) {
                            if let album = item.album {
                                addedAlbums.append(album)
                            }
                        }
                    } else if title.contains("recommend") || title.contains("for you") || title.contains("similar") {
                        recommendedHubItems.append(contentsOf: hubItems.prefix(12))
                    }
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to fetch hubs: \(error)")
                #endif
            }
        }

        guard !Task.isCancelled else { return }

        if !freshHubs.isEmpty {
            do {
                try await hubRepository.saveHubs(freshHubs)
                #if DEBUG
                EnsembleLogger.debug("✅ Cached \(freshHubs.count) hubs for offline use")
                #endif
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to cache hubs: \(error)")
                #endif
            }
        }

        unfilteredRecentlyPlayedAlbums = Array(recentAlbums.prefix(6))
        unfilteredRecentlyPlayedArtists = Array(recentArtists.prefix(6))
        unfilteredRecentlyAddedAlbums = Array(addedAlbums.prefix(6))
        unfilteredRecommendedItems = Array(recommendedHubItems.prefix(6))
        applyVisibilityToExploreContent()

        // Fetch moods once per library and dedupe by key.
        var moodsByKey: [String: Mood] = [:]
        for task in fetchTasks {
            guard !Task.isCancelled else { return }
            do {
                let plexMoods = try await task.client.getMoods(sectionKey: task.sectionKey)
                for plexMood in plexMoods where moodsByKey[plexMood.key] == nil {
                    moodsByKey[plexMood.key] = Mood(
                        id: plexMood.id,
                        key: plexMood.key,
                        title: plexMood.title,
                        sourceCompositeKey: task.sourceKey
                    )
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to fetch moods: \(error)")
                #endif
            }
        }

        guard !Task.isCancelled else { return }

        if !moodsByKey.isEmpty {
            let moodsToPublish = moodsByKey.values.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            do {
                try await moodRepository.saveMoods(moodsToPublish)
            } catch {
                #if DEBUG
                EnsembleLogger.debug("⚠️ Failed to cache moods: \(error)")
                #endif
            }
            unfilteredMoods = moodsToPublish
            applyVisibilityToExploreContent()
        }
    }

    private func buildExploreFetchTasks() -> [(sourceKey: String, client: PlexAPIClient, sectionKey: String)] {
        var tasks: [(sourceKey: String, client: PlexAPIClient, sectionKey: String)] = []

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let client = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                for library in server.libraries where library.isEnabled {
                    let sourceKey = "plex:\(account.id):\(server.id):\(library.key)"
                    tasks.append((sourceKey, client, library.key))
                }
            }
        }

        return tasks
    }
    
    /// Extract albums, artists, and items from Hub array
    nonisolated private func extractContentFromHubs(_ hubs: [Hub]) -> (albums: [Album], artists: [Artist], addedAlbums: [Album], recommendedItems: [HubItem]) {
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
