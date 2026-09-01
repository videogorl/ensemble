import Combine
import EnsembleAPI
import EnsembleDomain
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
    @Published public private(set) var displayAlbumResults: [DisplayAlbum] = []
    @Published public private(set) var playlistResults: [Playlist] = []
    @Published public private(set) var displayPlaylistResults: [DisplayPlaylist] = []
    @Published public private(set) var orderedSections: [SearchSection] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var searchError: String?
    
    // MARK: - Explore Content
    
    @Published public private(set) var recentlyPlayedAlbums: [Album] = []
    @Published public private(set) var recentlyPlayedDisplayAlbums: [DisplayAlbum] = []
    @Published public private(set) var recentlyPlayedArtists: [Artist] = []
    @Published public private(set) var recentlyAddedAlbums: [Album] = []
    @Published public private(set) var recentlyAddedDisplayAlbums: [DisplayAlbum] = []
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
    private let hiddenMediaStore: HiddenMediaStore
    private let playlistMergeDefaults: UserDefaults
    private let appleMusicCatalogSearch: AppleMusicCatalogSearchClient
    private var searchTask: Task<Void, Never>?
    private var exploreTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var exploreGeneration: UInt64 = 0
    private var cancellables = Set<AnyCancellable>()
    private var lastExploreLoadTime: Date?
    private let exploreDebounceInterval: TimeInterval = 2.0
    private let recentSearchesKey = "ensemble_recent_searches"
    private var hasLoadedExploreContent = false
    private var unfilteredTrackResults: [Track] = []
    private var unfilteredArtistResults: [Artist] = []
    private var unfilteredAlbumResults: [Album] = []
    private var unfilteredPlaylistResults: [Playlist] = []
    private var mergingPreferences: EnsembleMergingPreferences
    private var unfilteredRecentlyPlayedAlbums: [Album] = []
    private var unfilteredRecentlyPlayedArtists: [Artist] = []
    private var unfilteredRecentlyAddedAlbums: [Album] = []
    private var unfilteredRecommendedItems: [HubItem] = []
    private var unfilteredMoods: [Mood] = []

    public convenience init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        hubRepository: HubRepositoryProtocol,
        moodRepository: MoodRepository,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        playlistMergeDefaults: UserDefaults = .standard
    ) {
        self.init(
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            hubRepository: hubRepository,
            moodRepository: moodRepository,
            accountManager: accountManager,
            visibilityStore: visibilityStore,
            hiddenMediaStore: hiddenMediaStore,
            playlistMergeDefaults: playlistMergeDefaults,
            appleMusicCatalogSearch: .live
        )
    }

    init(
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        hubRepository: HubRepositoryProtocol,
        moodRepository: MoodRepository,
        accountManager: AccountManager,
        visibilityStore: LibraryVisibilityStore? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        playlistMergeDefaults: UserDefaults = .standard,
        appleMusicCatalogSearch: AppleMusicCatalogSearchClient
    ) {
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.hubRepository = hubRepository
        self.moodRepository = moodRepository
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore ?? .shared
        self.hiddenMediaStore = hiddenMediaStore ?? .shared
        self.playlistMergeDefaults = playlistMergeDefaults
        self.appleMusicCatalogSearch = appleMusicCatalogSearch
        self.mergingPreferences = SettingsManager.storedMergingPreferences(in: playlistMergeDefaults)
        
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
            .sink { [weak self] requestedScope in
                guard let self else { return }
                self.prepareForSearchQueryChange(self.searchQuery)
                self.performSearch(query: self.searchQuery, scope: requestedScope)
            }
            .store(in: &cancellables)

        // Debounced search
        $searchQuery
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
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
        
        // Reload search/explore content when any source configuration changes.
        accountManager.sourceConfigurationPublisher
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                self.invalidateExploreLoad(resetCadence: true)
                Task { @MainActor in
                    await self.reloadAfterExternalLibraryChange(forceExploreReload: false)
                }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            self.visibilityStore.$profiles,
            self.visibilityStore.$activeProfileID,
            self.visibilityStore.$focusFilter
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyVisibilityToSearchResults()
                self?.applyVisibilityToExploreContent()
            }
            .store(in: &cancellables)

        self.hiddenMediaStore.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyVisibilityToSearchResults()
                self?.applyVisibilityToExploreContent()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: SettingsManager.mergingPreferencesDidChange,
            object: playlistMergeDefaults
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMergingPreferences()
            }
            .store(in: &cancellables)

        observeMetadataChanges()
        ViewModelNotificationObserver.observeLibraryDataCleared(storingIn: &cancellables) { [weak self] in
            guard let self else { return }
            self.invalidateExploreLoad(resetCadence: true)
            try? await self.moodRepository.deleteAllMoods()
            await self.reloadAfterExternalLibraryChange(forceExploreReload: false)
        }
        ViewModelNotificationObserver.observeSourceCleanupCompleted(storingIn: &cancellables) { [weak self] in
            await self?.reloadAfterExternalLibraryChange(forceExploreReload: true)
        }
    }

    // MARK: - Search

    private func prepareForSearchQueryChange(_ query: String) {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1

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
    
    private func performSearch(query: String, scope requestedScope: SearchScope? = nil) {
        searchTask?.cancel()

        let trimmed = trimmedSearchQuery(query)

        guard !trimmed.isEmpty else {
            isSearching = false
            searchError = nil
            clearSearchResults()
            return
        }

        isSearching = true
        searchError = nil
        let startedAt = Date()
        searchGeneration &+= 1
        let generation = searchGeneration
        let requestedScope = requestedScope ?? scope
        UserJourneyLogger.log(
            context: "search",
            event: "started",
            details: ["queryLength": "\(trimmed.count)"]
        )

        searchTask = Task { [trimmed, startedAt, requestedScope, generation] in
            await search(
                query: trimmed,
                scope: requestedScope,
                startedAt: startedAt,
                generation: generation
            )
        }
    }

    public func search(query: String) async {
        await search(
            query: query,
            scope: scope,
            startedAt: Date(),
            generation: nil
        )
    }

    public func retrySearch() {
        performSearch(query: searchQuery)
    }

    private func search(
        query: String,
        scope requestedScope: SearchScope,
        startedAt: Date,
        generation: UInt64?
    ) async {
        let query = trimmedSearchQuery(query)
        guard !query.isEmpty else {
            isSearching = false
            clearSearchResults()
            return
        }

        isSearching = true
        searchError = nil

        do {
            if requestedScope == .appleMusic {
                let results = try await appleMusicCatalogSearch.search(query)
                guard isCurrentSearch(query, scope: requestedScope, generation: generation) else {
                    UserJourneyLogger.log(
                        context: "search",
                        event: "discardedStale",
                        details: [
                            "queryLength": "\(query.count)",
                            "scope": requestedScope.rawValue
                        ]
                    )
                    return
                }
                unfilteredTrackResults = results.tracks
                unfilteredArtistResults = results.artists
                unfilteredAlbumResults = results.albums
                unfilteredPlaylistResults = results.playlists
                applyVisibilityToSearchResults()
                isSearching = false
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
                UserJourneyLogger.log(
                    context: "search",
                    event: "finished",
                    details: [
                        "queryLength": "\(query.count)",
                        "scope": requestedScope.rawValue,
                        "elapsedMs": "\(elapsedMs)",
                        "tracks": "\(results.tracks.count)",
                        "artists": "\(results.artists.count)",
                        "albums": "\(results.albums.count)",
                        "playlists": "\(results.playlists.count)"
                    ]
                )
                return
            }

            async let localTracks = libraryRepository.searchTracks(query: query)
            async let localArtists = libraryRepository.searchArtists(query: query)
            async let localAlbums = libraryRepository.searchAlbums(query: query)
            async let localPlaylists = playlistRepository.searchPlaylists(query: query)
            
            let (tracks, artists, albums, playlists) = try await (localTracks, localArtists, localAlbums, localPlaylists)

            guard isCurrentSearch(query, scope: requestedScope, generation: generation) else {
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
            if !Task.isCancelled,
               isCurrentSearch(query, scope: requestedScope, generation: generation) {
                self.searchError = error.localizedDescription
                UserJourneyLogger.log(
                    context: "search",
                    event: "failed",
                    details: [
                        "queryLength": "\(query.count)",
                        "scope": requestedScope.rawValue,
                        "elapsedMs": "\(Int(Date().timeIntervalSince(startedAt) * 1_000))",
                        "error": String(describing: type(of: error))
                    ]
                )
            }
        }

        if isCurrentSearch(query, scope: requestedScope, generation: generation) {
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
        displayAlbumResults = []
        playlistResults = []
        displayPlaylistResults = []
        orderedSections = []
    }

    private func trimmedSearchQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isCurrentSearch(
        _ query: String,
        scope requestedScope: SearchScope,
        generation: UInt64?
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let generation else { return true }
        return Self.isCurrentSearchRequest(
            query: query,
            scope: requestedScope,
            generation: generation,
            currentQuery: trimmedSearchQuery(searchQuery),
            currentScope: scope,
            currentGeneration: searchGeneration
        )
    }

    internal nonisolated static func isCurrentSearchRequest(
        query: String,
        scope: SearchScope,
        generation: UInt64,
        currentQuery: String,
        currentScope: SearchScope,
        currentGeneration: UInt64
    ) -> Bool {
        query == currentQuery && scope == currentScope && generation == currentGeneration
    }

    public func commitCurrentSearch() {
        commitSearchToHistory(query: searchQuery)
    }

    private func observeMetadataChanges() {
        ViewModelNotificationObserver.observeMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.reloadAfterExternalLibraryChange(forceExploreReload: false)
        }
    }

    private func reloadAfterExternalLibraryChange(forceExploreReload: Bool) async {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        if forceExploreReload {
            invalidateExploreLoad(resetCadence: true)
        }
        applyVisibilityToSearchResults()
        applyVisibilityToExploreContent()

        let query = trimmedSearchQuery(searchQuery)
        if !query.isEmpty {
            performSearch(query: query)
        } else if hasLoadedExploreContent {
            await loadExploreContent()
        }
    }

    private func commitSearchToHistory(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Only save if there were actual results in the last search
        guard !trackResults.isEmpty || !artistResults.isEmpty || !albumResults.isEmpty || !displayPlaylistResults.isEmpty else {
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
            .albums: displayAlbumResults.count,
            .playlists: displayPlaylistResults.count,
            .songs: trackResults.count
        ]
        orderedSections = SearchSection.allCases
            .filter { sectionCounts[$0, default: 0] > 0 }
            .sorted { $0.sortPriority < $1.sortPriority }
    }

    private func applyVisibilityToSearchResults() {
        let sourceConfiguration = accountManager.sourceConfigurationSnapshot
        let hiddenSourceCompositeKeys = visibilityStore.effectiveHiddenSourceCompositeKeys(
            enabledSourceCompositeKeys: sourceConfiguration.enabledSourceKeys
        )
        let cachedSourceFilter = scope == .appleMusic
            ? sourceConfiguration
            : sourceConfigurationForCachedFiltering(sourceConfiguration)
        let hiddenMedia = scope == .library ? hiddenMediaStore.snapshot : .empty
        let visibleTracks = LibraryVisibilityFiltering.visibleItems(
            unfilteredTrackResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: cachedSourceFilter,
            hiddenMedia: hiddenMedia
        )
        trackResults = MergingProjection.tracks(visibleTracks, preferences: mergingPreferences)
        artistResults = LibraryVisibilityFiltering.visibleItems(
            unfilteredArtistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: cachedSourceFilter,
            hiddenMedia: hiddenMedia
        )
        displayArtistResults = DisplayArtist.group(artistResults, preferences: mergingPreferences)
        let visibleAlbums = LibraryVisibilityFiltering.visibleItems(
            unfilteredAlbumResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: cachedSourceFilter,
            hiddenMedia: hiddenMedia
        )
        albumResults = visibleAlbums
        displayAlbumResults = MergingProjection.albums(visibleAlbums, preferences: mergingPreferences)
        let visiblePlaylists = LibraryVisibilityFiltering.visibleItems(
            unfilteredPlaylistResults,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: cachedSourceFilter,
            hiddenMedia: hiddenMedia
        )
        playlistResults = visiblePlaylists
        let nextDisplayPlaylists = Self.displayPlaylists(
            visiblePlaylists,
            scope: scope,
            preferences: mergingPreferences
        )
        if displayPlaylistResults != nextDisplayPlaylists {
            displayPlaylistResults = nextDisplayPlaylists
        }
        determineSearchSectionOrder()
    }

    private func refreshMergingPreferences() {
        let nextValue = SettingsManager.storedMergingPreferences(in: playlistMergeDefaults)
        guard nextValue != mergingPreferences else { return }
        mergingPreferences = nextValue
        applyVisibilityToSearchResults()
        applyVisibilityToExploreContent()
    }

    internal nonisolated static func displayPlaylists(
        _ playlists: [Playlist],
        scope: SearchScope,
        preferences: EnsembleMergingPreferences
    ) -> [DisplayPlaylist] {
        DisplayPlaylist.group(
            playlists,
            merge: scope == .library && preferences.isEnabled && preferences.mergePlaylists,
            preferences: preferences
        )
    }

    private func applyVisibilityToExploreContent() {
        let currentSourceConfiguration = accountManager.sourceConfigurationSnapshot
        let hiddenSourceCompositeKeys = visibilityStore.effectiveHiddenSourceCompositeKeys(
            enabledSourceCompositeKeys: currentSourceConfiguration.enabledSourceKeys
        )
        let sourceConfiguration = sourceConfigurationForCachedFiltering(currentSourceConfiguration)
        recentlyPlayedAlbums = LibraryVisibilityFiltering.visibleItems(
            unfilteredRecentlyPlayedAlbums,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: sourceConfiguration,
            hiddenMedia: hiddenMediaStore.snapshot
        )
        recentlyPlayedDisplayAlbums = Array(
            MergingProjection.albums(recentlyPlayedAlbums, preferences: mergingPreferences).prefix(6)
        )
        recentlyPlayedArtists = Array(LibraryVisibilityFiltering.visibleItems(
            unfilteredRecentlyPlayedArtists,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: sourceConfiguration,
            hiddenMedia: hiddenMediaStore.snapshot
        ).prefix(6))
        recentlyAddedAlbums = LibraryVisibilityFiltering.visibleItems(
            unfilteredRecentlyAddedAlbums,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: sourceConfiguration,
            hiddenMedia: hiddenMediaStore.snapshot
        )
        recentlyAddedDisplayAlbums = Array(
            MergingProjection.albums(recentlyAddedAlbums, preferences: mergingPreferences).prefix(6)
        )
        recommendedItems = Array(Self.filterHubItemsForVisibility(
            unfilteredRecommendedItems,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: sourceConfiguration,
            hiddenMedia: hiddenMediaStore.snapshot
        ).prefix(6))
        allMoods = Self.filterMoodsForVisibility(
            unfilteredMoods,
            hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
            sourceConfiguration: sourceConfiguration
        )
    }

    private func sourceConfigurationForCachedFiltering(
        _ configuration: SourceConfigurationSnapshot
    ) -> SourceConfigurationSnapshot? {
        configuration.hasAnySources || !configuration.isAuthoritative ? configuration : nil
    }

    internal static func filterHubItemsForVisibility(
        _ items: [HubItem],
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot? = nil,
        hiddenMedia: HiddenMediaSnapshot = .empty
    ) -> [HubItem] {
        items.filter { item in
            MediaSourceIdentity.parse(item.sourceCompositeKey) != nil &&
                (sourceConfiguration?.shouldPreserveSourceKey(item.sourceCompositeKey) ?? true) &&
                !hiddenSourceCompositeKeys.contains(item.sourceCompositeKey) &&
                item.album.map { !hiddenMedia.isHidden($0) } ?? true &&
                item.track.map { !hiddenMedia.isHidden($0) } ?? true &&
                item.artist.map { !hiddenMedia.isHidden($0) } ?? true &&
                item.playlist.map { !hiddenMedia.isHidden($0) } ?? true
        }
    }

    internal static func filterMoodsForVisibility(
        _ moods: [Mood],
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot? = nil
    ) -> [Mood] {
        moods.compactMap { mood in
            let references = moodSourceReferences(from: mood.sourceCompositeKey)
            guard !references.isEmpty else { return nil }
            let visibleReferences = references.filter { reference in
                MediaSourceIdentity.parse(reference.sourceCompositeKey) != nil &&
                    (sourceConfiguration?.shouldPreserveSourceKey(reference.sourceCompositeKey) ?? true) &&
                    !hiddenSourceCompositeKeys.contains(reference.sourceCompositeKey)
            }
            guard !visibleReferences.isEmpty else { return nil }
            guard visibleReferences.count != references.count else { return mood }
            return Mood(
                id: mood.id,
                key: mood.key,
                title: mood.title,
                sourceCompositeKey: visibleReferences.map {
                    Mood.sourceReference(
                        sourceCompositeKey: $0.sourceCompositeKey,
                        moodKey: $0.moodKey
                    )
                }.joined(separator: "|")
            )
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
        displayAlbumResults = []
        playlistResults = []
        displayPlaylistResults = []
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
        exploreGeneration &+= 1
        let generation = exploreGeneration
        
        // Record load time for debouncing
        lastExploreLoadTime = Date()

        exploreTask = Task { [weak self, generation] in
            guard let self else { return }
            await self.loadExploreContentInternal(generation: generation)
        }

        await exploreTask?.value
    }

    private func invalidateExploreLoad(resetCadence: Bool) {
        exploreTask?.cancel()
        exploreTask = nil
        exploreGeneration &+= 1
        if resetCadence {
            lastExploreLoadTime = nil
        }
    }

    private func loadExploreContentInternal(generation: UInt64) async {
        isLoadingExplore = false  // Show cached data immediately, don't block on loading state
        exploreError = nil

        // Load cached hubs first for fast offline-first rendering.
        do {
            let cachedHubs = try await hubRepository.fetchHubs()
            guard isCurrentExploreLoad(generation) else { return }
            let results = Self.extractContentFromHubs(cachedHubs)
            unfilteredRecentlyPlayedAlbums = results.albums
            unfilteredRecentlyPlayedArtists = results.artists
            unfilteredRecentlyAddedAlbums = results.addedAlbums
            unfilteredRecommendedItems = results.recommendedItems
            applyVisibilityToExploreContent()
        } catch {
            EnsembleLogger.debug("ℹ️ No cached explore content available")
        }

        // Load cached moods immediately while fresh network fetch runs.
        if let cachedMoods = try? await moodRepository.fetchMoods(), !cachedMoods.isEmpty {
            guard isCurrentExploreLoad(generation) else { return }
            unfilteredMoods = Self.mergeMoodsForDisplay(cachedMoods)
            applyVisibilityToExploreContent()
        }

        guard isCurrentExploreLoad(generation) else { return }

        let fetchTasks = buildExploreFetchTasks()
        guard !fetchTasks.isEmpty else { return }

        // Plex mood keys are library-local. Deduplicate browse moods by title and
        // carry each source's resolved key so detail pages can skip refetching moods.
        var moodsByTitle: [String: Mood] = [:]
        var moodSourceReferencesByTitle: [String: [String: String]] = [:]
        for task in fetchTasks {
            guard isCurrentExploreLoad(generation) else { return }
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

        guard isCurrentExploreLoad(generation) else { return }

        if !moodsByTitle.isEmpty {
            let moodsToPublish = moodsByTitle.values.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            do {
                try await moodRepository.saveMoods(moodsToPublish)
            } catch is CancellationError {
                return
            } catch {
                EnsembleLogger.debug("⚠️ Failed to cache moods: \(error)")
            }
            guard isCurrentExploreLoad(generation) else { return }
            unfilteredMoods = moodsToPublish
            applyVisibilityToExploreContent()
        }
    }

    private func isCurrentExploreLoad(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == exploreGeneration
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
    nonisolated static func extractContentFromHubs(_ hubs: [Hub]) -> (albums: [Album], artists: [Artist], addedAlbums: [Album], recommendedItems: [HubItem]) {
        var recentAlbums: [Album] = []
        var recentArtists: [Artist] = []
        var addedAlbums: [Album] = []
        var recommendedItems: [HubItem] = []
        
        for hub in hubs {
            let title = hub.title.lowercased()
            
            if hub.semanticKind == .recentlyPlayed {
                for item in hub.items {
                    if let album = item.album {
                        recentAlbums.append(album)
                    }
                    if let artist = item.artist {
                        recentArtists.append(artist)
                    }
                }
            } else if hub.semanticKind == .recentlyAdded {
                for item in hub.items {
                    if let album = item.album {
                        addedAlbums.append(album)
                    }
                }
            } else if title.contains("recommend") || title.contains("for you") || title.contains("similar") {
                for item in hub.items {
                    recommendedItems.append(item)
                }
            }
        }
        
        return (recentAlbums, recentArtists, addedAlbums, recommendedItems)
    }
}
