import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Search section types for intelligent ordering
public enum SearchSection: String, CaseIterable, Hashable, Sendable {
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

public enum SearchScope: String, CaseIterable, Sendable {
    case library = "Library"
    case appleMusic = "Apple Music"
}

@MainActor
public final class SearchViewModel: ObservableObject {
    // MARK: - Search Results
    
    @Published public var searchQuery = ""
    @Published public var scope: SearchScope = .library
    @Published public private(set) var recentSearches: [String] = []
    @Published public private(set) var trackResults: [Track] = []
    @Published public private(set) var artistResults: [Artist] = []
    @Published public private(set) var displayArtistResults: [DisplayArtist] = []
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
    
    public let focusRequested = PassthroughSubject<Void, Never>()

    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let hubRepository: HubRepositoryProtocol
    private let moodRepository: MoodRepository
    private let accountManager: AccountManager
    private let visibilityStore: LibraryVisibilityStore
    private var searchTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var lastExploreLoadTime: Date?
    private let exploreDebounceInterval: TimeInterval = 2.0
    private let recentSearchesKey = "ensemble_recent_searches"
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
        moodRepository: MoodRepository,
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

        $searchQuery
            .removeDuplicates()
            .sink { [weak self] query in
                self?.prepareForSearchQueryChange(query)
            }
            .store(in: &cancellables)

        $scope
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.prepareForSearchQueryChange(self.searchQuery)
                self.performSearch(query: self.searchQuery)
            }
            .store(in: &cancellables)

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
                Task { @MainActor in
                    guard let self else { return }

                    let trimmedQuery = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedQuery.isEmpty {
                        await self.search(
                            query: trimmedQuery,
                            startedAt: Date(),
                            requireCurrentQuery: true
                        )
                    } else if self.hasLoadedExploreContent {
                        await self.loadExploreContent()
                    }
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

        observeMetadataChanges()
    }

    // MARK: - Search

    private func prepareForSearchQueryChange(_ query: String) {
        searchTask?.cancel()
        searchTask = nil

        let trimmed = trimmedSearchQuery(query)

        guard !trimmed.isEmpty else {
            isSearching = false
            searchError = nil
            clearSearchResults()
            return
        }

        isSearching = true
        searchError = nil
        UserJourneyLogger.log(
            context: "search",
            event: "inputChanged",
            details: ["queryLength": "\(trimmed.count)"]
        )
    }
    
    private func performSearch(query: String) {
        searchTask?.cancel()

        let trimmed = trimmedSearchQuery(query)

        guard !trimmed.isEmpty else {
            isSearching = false
            searchError = nil
            clearSearchResults()
            return
        }

        let startedAt = Date()
        UserJourneyLogger.log(
            context: "search",
            event: "started",
            details: ["queryLength": "\(trimmed.count)"]
        )

        searchTask = Task { [trimmed, startedAt] in
            await search(query: trimmed, startedAt: startedAt, requireCurrentQuery: true)
        }
    }

    public func search(query: String) async {
        await search(query: query, startedAt: Date(), requireCurrentQuery: false)
    }

    private func search(query: String, startedAt: Date, requireCurrentQuery: Bool) async {
        let query = trimmedSearchQuery(query)
        guard !query.isEmpty else {
            isSearching = false
            clearSearchResults()
            return
        }

        isSearching = true
        searchError = nil

        do {
            #if os(iOS)
            if scope == .appleMusic, #available(iOS 18, *) {
                let results = try await AppleMusicCatalogSearch.search(query)
                guard !requireCurrentQuery || isCurrentSearch(query) else { return }
                unfilteredTrackResults = results.tracks
                unfilteredArtistResults = results.artists
                unfilteredAlbumResults = results.albums
                unfilteredPlaylistResults = results.playlists
                applyVisibilityToSearchResults()
                isSearching = false
                return
            }
            #endif

            async let localTracks = libraryRepository.searchTracks(query: query)
            async let localArtists = libraryRepository.searchArtists(query: query)
            async let localAlbums = libraryRepository.searchAlbums(query: query)
            async let localPlaylists = playlistRepository.searchPlaylists(query: query)
            
            let (tracks, artists, albums, playlists) = try await (localTracks, localArtists, localAlbums, localPlaylists)

            guard !requireCurrentQuery || isCurrentSearch(query) else {
                UserJourneyLogger.log(
                    context: "search",
                    event: "discardedStale",
                    details: ["queryLength": "\(query.count)"]
                )
                return
            }
            
            unfilteredTrackResults = tracks.map { Track(from: $0) }
            unfilteredArtistResults = artists.map { Artist(from: $0) }
            unfilteredAlbumResults = albums.map { Album(from: $0) }
            unfilteredPlaylistResults = playlists.map { Playlist(from: $0) }
            applyVisibilityToSearchResults()

            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
            UserJourneyLogger.log(
                context: "search",
                event: "finished",
                details: [
                    "queryLength": "\(query.count)",
                    "elapsedMs": "\(elapsedMs)",
                    "tracks": "\(tracks.count)",
                    "artists": "\(artists.count)",
                    "albums": "\(albums.count)",
                    "playlists": "\(playlists.count)"
                ]
            )
        } catch {
            if !Task.isCancelled, !requireCurrentQuery || isCurrentSearch(query) {
                self.searchError = error.localizedDescription
                UserJourneyLogger.log(
                    context: "search",
                    event: "failed",
                    details: [
                        "queryLength": "\(query.count)",
                        "error": String(describing: type(of: error))
                    ]
                )
            }
        }

        if !requireCurrentQuery || isCurrentSearch(query) {
            isSearching = false
        }
    }

    private func clearSearchResults() {
        unfilteredTrackResults = []
        unfilteredArtistResults = []
        unfilteredAlbumResults = []
        unfilteredPlaylistResults = []
        trackResults = []
        artistResults = []
        displayArtistResults = []
        albumResults = []
        playlistResults = []
        orderedSections = []
    }

    private func trimmedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCurrentSearch(_ query: String) -> Bool {
        trimmedSearchQuery(searchQuery) == query
    }

    public func commitCurrentSearch() {
        commitSearchToHistory(query: searchQuery)
    }

    private func observeMetadataChanges() {
        ViewModelNotificationObserver.observeMetadataChanges(storingIn: &cancellables) { [weak self] in
            guard let self else { return }
            let trimmedQuery = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                await self.search(
                    query: trimmedQuery,
                    startedAt: Date(),
                    requireCurrentQuery: true
                )
            } else if self.hasLoadedExploreContent {
                await self.loadExploreContent()
            }
        }
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
    
    /// Keeps search result categories in a stable, predictable order.
    private func determineSearchSectionOrder() {
        let sectionCounts: [SearchSection: Int] = [
            .artists: displayArtistResults.count,
            .albums: albumResults.count,
            .playlists: playlistResults.count,
            .songs: trackResults.count
        ]
        orderedSections = SearchSection.allCases
            .filter { sectionCounts[$0, default: 0] > 0 }
            .sorted { $0.sortPriority < $1.sortPriority }
    }

    private func applyVisibilityToSearchResults() {
        let hiddenSourceCompositeKeys = visibilityStore.hiddenSourceCompositeKeys
        trackResults = LibraryVisibilityFiltering.visibleItems(
            unfilteredTrackResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        artistResults = LibraryVisibilityFiltering.visibleItems(
            unfilteredArtistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        displayArtistResults = DisplayArtist.group(artistResults)
        albumResults = LibraryVisibilityFiltering.visibleItems(
            unfilteredAlbumResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        playlistResults = LibraryVisibilityFiltering.visibleItems(
            unfilteredPlaylistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        determineSearchSectionOrder()
    }

    private func applyVisibilityToExploreContent() {
        let hiddenSourceCompositeKeys = visibilityStore.hiddenSourceCompositeKeys
        recentlyPlayedAlbums = LibraryVisibilityFiltering.visibleItems(
            unfilteredRecentlyPlayedAlbums,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        recentlyPlayedArtists = LibraryVisibilityFiltering.visibleItems(
            unfilteredRecentlyPlayedArtists,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys
        )
        recentlyAddedAlbums = LibraryVisibilityFiltering.visibleItems(
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
            let sourceKeys = moodSourceCompositeKeys(from: mood.sourceCompositeKey)
            guard !sourceKeys.isEmpty else { return true }
            return !sourceKeys.isSubset(of: hiddenSourceCompositeKeys)
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
        displayArtistResults = []
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
            EnsembleLogger.debug("ℹ️ No cached explore content available")
        }

        // Load cached moods immediately while fresh network fetch runs.
        if let cachedMoods = try? await moodRepository.fetchMoods(), !cachedMoods.isEmpty {
            unfilteredMoods = Self.mergeMoodsForDisplay(cachedMoods)
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

                    let metadata = plexHub.metadata ?? []

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
                EnsembleLogger.debug("⚠️ Failed to fetch hubs: \(error)")
            }
        }

        guard !Task.isCancelled else { return }

        if !freshHubs.isEmpty {
            do {
                try await hubRepository.saveHubs(freshHubs)
                EnsembleLogger.debug("✅ Cached \(freshHubs.count) hubs for offline use")
            } catch {
                EnsembleLogger.debug("⚠️ Failed to cache hubs: \(error)")
            }
        }

        unfilteredRecentlyPlayedAlbums = Array(recentAlbums.prefix(6))
        unfilteredRecentlyPlayedArtists = Array(recentArtists.prefix(6))
        unfilteredRecentlyAddedAlbums = Array(addedAlbums.prefix(6))
        unfilteredRecommendedItems = Array(recommendedHubItems.prefix(6))
        applyVisibilityToExploreContent()

        // Plex mood keys are library-local. Deduplicate browse moods by title and
        // carry each source's resolved key so detail pages can skip refetching moods.
        var moodsByTitle: [String: Mood] = [:]
        var moodSourceReferencesByTitle: [String: [String: String]] = [:]
        for task in fetchTasks {
            guard !Task.isCancelled else { return }
            do {
                let plexMoods = try await task.client.getMoods(sectionKey: task.sectionKey)
                for plexMood in plexMoods {
                    let titleKey = Self.normalizedMoodTitleKey(plexMood.title)
                    guard !titleKey.isEmpty else { continue }
                    moodSourceReferencesByTitle[titleKey, default: [:]][task.sourceKey] = plexMood.key

                    if moodsByTitle[titleKey] == nil {
                        moodsByTitle[titleKey] = Mood(
                            id: "mood:\(titleKey)",
                            key: plexMood.key,
                            title: plexMood.title,
                            sourceCompositeKey: task.sourceKey
                        )
                    }
                }
            } catch {
                EnsembleLogger.debug("⚠️ Failed to fetch moods: \(error)")
            }
        }

        for (titleKey, sourceReferences) in moodSourceReferencesByTitle {
            guard let mood = moodsByTitle[titleKey] else { continue }
            let mergedSourceKey = Self.mergedMoodSourceCompositeKey(from: sourceReferences)
            moodsByTitle[titleKey] = Mood(
                id: mood.id,
                key: mood.key,
                title: mood.title,
                sourceCompositeKey: mergedSourceKey
            )
        }

        guard !Task.isCancelled else { return }

        if !moodsByTitle.isEmpty {
            let moodsToPublish = moodsByTitle.values.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            do {
                try await moodRepository.saveMoods(moodsToPublish)
            } catch {
                EnsembleLogger.debug("⚠️ Failed to cache moods: \(error)")
            }
            unfilteredMoods = moodsToPublish
            applyVisibilityToExploreContent()
        }
    }

    internal nonisolated static func normalizedMoodTitleKey(_ title: String) -> String {
        Mood.normalizedTitleKey(title)
    }

    internal nonisolated static func mergedMoodSourceCompositeKey(from sourceMoodKeys: [String: String]) -> String? {
        let references = sourceMoodKeys
            .sorted { $0.key < $1.key }
            .map { Mood.sourceReference(sourceCompositeKey: $0.key, moodKey: $0.value) }
        guard !references.isEmpty else { return nil }
        return references.joined(separator: "|")
    }

    internal nonisolated static func moodSourceCompositeKeys(from sourceCompositeKey: String?) -> Set<String> {
        Mood.sourceCompositeKeys(from: sourceCompositeKey)
    }

    internal nonisolated static func moodSourceReferences(from sourceCompositeKey: String?) -> [Mood.SourceReference] {
        Mood.sourceReferences(from: sourceCompositeKey)
    }

    internal nonisolated static func mergeMoodsForDisplay(_ moods: [Mood]) -> [Mood] {
        var moodsByTitle: [String: Mood] = [:]
        var moodSourceReferencesByTitle: [String: [String: String?]] = [:]

        for mood in moods {
            let titleKey = normalizedMoodTitleKey(mood.title)
            guard !titleKey.isEmpty else { continue }

            let sourceReferences = moodSourceReferences(from: mood.sourceCompositeKey)
            if sourceReferences.isEmpty {
                moodSourceReferencesByTitle[titleKey, default: [:]][""] = nil
            } else {
                for reference in sourceReferences {
                    moodSourceReferencesByTitle[titleKey, default: [:]][reference.sourceCompositeKey] = reference.moodKey
                }
            }

            if moodsByTitle[titleKey] == nil {
                moodsByTitle[titleKey] = Mood(
                    id: "mood:\(titleKey)",
                    key: mood.key,
                    title: mood.title,
                    sourceCompositeKey: mood.sourceCompositeKey
                )
            }
        }

        return moodsByTitle.map { titleKey, mood in
            let sourceReferences = moodSourceReferencesByTitle[titleKey] ?? [:]
            let mergedReferences = sourceReferences
                .filter { !$0.key.isEmpty }
                .sorted { $0.key < $1.key }
                .map { Mood.sourceReference(sourceCompositeKey: $0.key, moodKey: $0.value) }
            return Mood(
                id: mood.id,
                key: mood.key,
                title: mood.title,
                sourceCompositeKey: mergedReferences.isEmpty ? nil : mergedReferences.joined(separator: "|")
            )
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
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
