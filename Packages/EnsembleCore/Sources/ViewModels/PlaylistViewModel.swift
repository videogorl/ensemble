import Combine
import EnsembleDomain
import EnsemblePersistence
import Foundation

struct PlaylistDetailTrackDerivation: Equatable {
    let filteredTracks: [Track]
    let availableGenres: [String]
    let totalDuration: String

    @MainActor
    static func make(tracks: [Track], filterOptions: FilterOptions) -> PlaylistDetailTrackDerivation {
        let filteredTracks = filter(tracks, with: filterOptions)
        return PlaylistDetailTrackDerivation(
            filteredTracks: filteredTracks,
            availableGenres: LibraryViewModel.extractUniqueGenres(from: tracks.flatMap(\.genres)),
            totalDuration: MediaFormatters.trackCollectionDuration(filteredTracks)
        )
    }

    static func filter(_ tracks: [Track], with options: FilterOptions) -> [Track] {
        MediaFilterEngine.filterTracks(tracks, with: options, configuration: .playlistDetail)
    }

    func publishChanges(
        filteredTracks currentFilteredTracks: inout [Track],
        availableGenres currentAvailableGenres: inout [String],
        totalDuration currentTotalDuration: inout String
    ) {
        if currentFilteredTracks != filteredTracks {
            currentFilteredTracks = filteredTracks
        }
        if currentAvailableGenres != availableGenres {
            currentAvailableGenres = availableGenres
        }
        if currentTotalDuration != totalDuration {
            currentTotalDuration = totalDuration
        }
    }
}

@MainActor
public final class PlaylistViewModel: ObservableObject {
    private static let optimisticCreatePrefix = "creating:"
    private static var lastGoodPlaylistsSnapshot: [Playlist] = []

    static func resetLastGoodSnapshotForTesting() {
        lastGoodPlaylistsSnapshot = []
    }

    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var visibleSnapshot: [Playlist] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public private(set) var isShowingStaleSnapshot = false
    @Published public var playlistSortOption: PlaylistSortOption = .title {
        didSet {
            filterOptions.sortBy = playlistSortOption.rawValue
        }
    }
    @Published public var filterOptions: FilterOptions
    /// Cached sorted + filtered playlists, updated via Combine pipeline instead of re-computed on every body access
    @Published public private(set) var filteredPlaylists: [Playlist] = []
    /// Sorted playlist list used by large-screen sidebar navigation.
    @Published public private(set) var sortedPlaylists: [Playlist] = []

    // MARK: - Merge Support

    @Published public private(set) var isMergeEnabled: Bool
    @Published private var mergingPreferences: EnsembleMergingPreferences
    /// Merge-aware playlist list for the UI — groups same-named playlists when merge is on
    @Published public private(set) var displayPlaylists: [DisplayPlaylist] = []
    /// Merge-aware sorted list for the macOS sidebar
    @Published public private(set) var sortedDisplayPlaylists: [DisplayPlaylist] = []
    /// Titles that appear on 2+ servers (used for showing server name chips when merge is off)
    public private(set) var nameCollisionTitles: Set<String> = []

    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private let toastCenter: ToastCenter
    private let accountManager: AccountManager?
    private let visibilityStore: LibraryVisibilityStore
    private let hiddenMediaStore: HiddenMediaStore
    private var cancellables = Set<AnyCancellable>()
    private var allPlaylists: [Playlist] = []
    private var coalescedReloadTask: Task<Void, Never>?
    private var hasLoadedPlaylists = false
    private var optimisticCreatingPlaylists: [Playlist] = []
    private var optimisticRenamedPlaylistTitlesByIdentity: [String: String] = [:]
    private var optimisticDeletedPlaylistIdentities: Set<String> = []
    private var lastObservedSourceConfiguration: SourceConfigurationSnapshot?
    /// A settled empty credential read is not proof that cached browse data was deleted.
    /// Once this ViewModel observes an explicit source removal, however, it must not
    /// re-publish that source's cache while cleanup converges.
    private var preservesAuthoritativeEmptySourceSnapshot = true
    internal private(set) var sourceCleanupReloadCountForTesting = 0
    /// Suppresses observer-triggered reloads during pull-to-refresh so intermediate
    /// CoreData states (partial data while sync rebuilds records) don't clobber the list.
    /// Published so the view can freeze its cached list during refresh.
    @Published public private(set) var isRefreshingFromServer = false

    public init(
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        toastCenter: ToastCenter,
        accountManager: AccountManager? = nil,
        visibilityStore: LibraryVisibilityStore? = nil,
        hiddenMediaStore: HiddenMediaStore? = nil,
        observesExternalChanges: Bool = true
    ) {
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.toastCenter = toastCenter
        self.accountManager = accountManager
        self.visibilityStore = visibilityStore ?? .shared
        self.hiddenMediaStore = hiddenMediaStore ?? .shared
        self.lastObservedSourceConfiguration = accountManager?.sourceConfigurationSnapshot
        let mergingPreferences = SettingsManager.storedMergingPreferences()
        self.mergingPreferences = mergingPreferences
        self.isMergeEnabled = mergingPreferences.isEnabled && mergingPreferences.mergePlaylists
        let savedFilters = FilterPersistence.load(for: "Playlists")
        self.filterOptions = savedFilters

        // Load sort option from filters
        if let savedSort = PlaylistSortOption(rawValue: savedFilters.sortBy) {
            self.playlistSortOption = savedSort
        }

        seedFromLastGoodSnapshotIfAvailable()
        seedFromPersistentCacheIfAvailable()

        // Save filter options when they change
        setupFilterPersistence()

        // Cache sorted+filtered playlists so they aren't recomputed on every SwiftUI body access
        setupFilteredPlaylistsPipeline()
        setupSortedPlaylistsPipeline()

        // Merge-aware pipelines that group playlists into DisplayPlaylist entries
        setupDisplayPlaylistsPipeline()
        setupSortedDisplayPlaylistsPipeline()
        setupVisibilityObservation()
        setupPlaylistMergePreferenceObservation()

        if observesExternalChanges {
            observeExternalChanges()
        }

        ViewModelNotificationObserver.observeLibraryDataCleared(storingIn: &cancellables) { [weak self] in
            self?.handleLibraryDataCleared()
        }
        ViewModelNotificationObserver.observeSourceCleanupCompleted(storingIn: &cancellables) { [weak self] in
            guard let self else { return }
            self.sourceCleanupReloadCountForTesting += 1
            await self.reloadPlaylists(showLoading: false)
        }
    }

    private func observeExternalChanges() {
        // Auto-reload when sync completes (skip during pull-to-refresh — it does its own reload)
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing, self?.isRefreshingFromServer != true {
                    self?.scheduleCoalescedPlaylistReload(reason: "sync-complete")
                }
            }
            .store(in: &cancellables)

        hiddenMediaStore.$snapshot
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVisibilityToPublishedPlaylists() }
            .store(in: &cancellables)

        // Auto-reload when playlists are refreshed after a mutation (e.g. track counts changed)
        NotificationCenter.default.publisher(for: SyncCoordinator.playlistsDidRefresh)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] notification in
                guard self?.isRefreshingFromServer != true else { return }
                let serverKey = notification.userInfo?["serverSourceKey"] as? String ?? "unknown"
                EnsembleLogger.debug("📋 PlaylistViewModel: playlistsDidRefresh notification from \(serverKey)")
                self?.scheduleCoalescedPlaylistReload(reason: "playlistsDidRefresh")
            }
            .store(in: &cancellables)

        accountManager?.sourceConfigurationPublisher
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] configuration in
                self?.handleSourceConfigurationChange(configuration)
            }
            .store(in: &cancellables)
    }
    
    private func setupFilterPersistence() {
        FilterPersistence.observe($filterOptions, key: "Playlists", storingIn: &cancellables)
    }

    private func setupVisibilityObservation() {
        Publishers.CombineLatest3(
            visibilityStore.$profiles,
            visibilityStore.$activeProfileID,
            visibilityStore.$focusFilter
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyVisibilityToPublishedPlaylists()
            }
            .store(in: &cancellables)
    }

    private func setupPlaylistMergePreferenceObservation() {
        NotificationCenter.default.publisher(
            for: SettingsManager.mergingPreferencesDidChange,
            object: UserDefaults.standard
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            guard let self else { return }
            let preferences = SettingsManager.storedMergingPreferences()
            if self.mergingPreferences != preferences { self.mergingPreferences = preferences }
            let isEnabled = preferences.isEnabled && preferences.mergePlaylists
            if self.isMergeEnabled != isEnabled { self.isMergeEnabled = isEnabled }
        }
        .store(in: &cancellables)
    }

    public func loadPlaylistsIfNeeded() async {
        guard !hasLoadedPlaylists else { return }
        hasLoadedPlaylists = true
        await reloadPlaylists(showLoading: playlists.isEmpty)
    }

    public func loadPlaylists() async {
        hasLoadedPlaylists = true
        await reloadPlaylists(showLoading: playlists.isEmpty)
    }

    /// Sync playlists from server, then reload from cache
    public func refreshFromServer() async {
        // Check if offline
        if syncCoordinator.isOffline {
            EnsembleLogger.debug("📴 Offline - loading playlists from cache only")
            await loadPlaylists()
            return
        }

        // Check if sync is already in progress
        if syncCoordinator.isSyncing {
            EnsembleLogger.debug("⏳ Sync already in progress - loading playlists from cache")
            toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "arrow.triangle.2.circlepath",
                    title: "Sync in progress",
                    message: "A background sync is already running.",
                    dedupeKey: "sync-already-in-progress"
                )
            )
            await loadPlaylists()
            return
        }

        error = nil

        // Suppress observer-triggered reloads during sync to prevent intermediate
        // CoreData states (partial data while records are rebuilt) from clobbering the list.
        // refreshFromServer does its own loadPlaylists() after sync completes.
        isRefreshingFromServer = true

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        EnsembleLogger.debug("🔄 Starting playlist sync (detached)...")
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncPlaylistsOnly()
                continuation.resume()
            }
        }
        EnsembleLogger.debug("✅ Playlist sync complete")

        // Reload from updated cache (now that sync is fully committed).
        // Keep the flag set until AFTER loadPlaylists finishes — clearing it before
        // would let queued debounced observers fire in the window between flag-clear
        // and loadPlaylists, potentially publishing partial CoreData state.
        await loadPlaylists()
        isRefreshingFromServer = false
    }

    public func deletePlaylist(_ playlist: Playlist) async -> Bool {
        do {
            _ = try await mutationCoordinator.deletePlaylist(playlist)
            applyOptimisticDelete(for: playlist)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func applyOptimisticDelete(for playlist: Playlist) {
        let identity = playlist.sourceScopedID
        optimisticDeletedPlaylistIdentities.insert(identity)
        optimisticCreatingPlaylists.removeAll { $0.sourceScopedID == identity }
        optimisticRenamedPlaylistTitlesByIdentity.removeValue(forKey: identity)
        publishPlaylistsIfChanged(
            applyOptimisticRenames(to: filterOptimisticallyDeletedPlaylists(allPlaylists))
        )
        updateLastGoodSnapshotIfNeeded(allPlaylists)
    }

    public func clearOptimisticDelete(forPlaylistIdentity playlistIdentity: String) {
        optimisticDeletedPlaylistIdentities.remove(playlistIdentity)
    }

    public func createPlaylist(title: String, serverSourceKey: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Playlist name cannot be empty."
            return false
        }

        addOptimisticCreatingPlaylist(title: trimmed, serverSourceKey: serverSourceKey)

        do {
            _ = try await mutationCoordinator.createPlaylist(
                title: trimmed,
                tracks: [],
                serverSourceKey: serverSourceKey
            )
            Task { [weak self] in
                await self?.awaitCreatedPlaylistMaterialization(
                    title: trimmed,
                    serverSourceKey: serverSourceKey
                )
            }
            return true
        } catch {
            removeOptimisticCreatingPlaylist(title: trimmed, serverSourceKey: serverSourceKey)
            await reloadPlaylists(showLoading: false)
            self.error = error.localizedDescription
            return false
        }
    }

    public func isPlaylistPendingCreation(_ playlist: Playlist) -> Bool {
        Self.isOptimisticCreatingPlaylistID(playlist.id)
    }
    
    // MARK: - Sort & Filter (static, used by Combine pipeline)

    /// Sorts playlists using the same options as the Playlists screen.
    public static func sortPlaylists(_ playlists: [Playlist], by option: PlaylistSortOption, ascending asc: Bool) -> [Playlist] {
        switch option {
        case .title:
            return playlists.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: asc)
        case .trackCount:
            return playlists.sortedByComparableKey(\.trackCount, ascending: asc)
        case .duration:
            return playlists.sortedByComparableKey(\.duration, ascending: asc)
        case .dateAdded:
            return playlists.sortedByOptionalComparableKey(\.dateAdded, stableID: \.sourceScopedID, ascending: asc)
        case .dateModified:
            return playlists.sortedByOptionalComparableKey(\.dateModified, stableID: \.sourceScopedID, ascending: asc)
        case .lastPlayed:
            return playlists.sortedByOptionalComparableKey(\.lastPlayed, stableID: \.sourceScopedID, ascending: asc)
        }
    }

    public static func sortDisplayPlaylists(
        _ playlists: [DisplayPlaylist],
        by option: PlaylistSortOption,
        ascending asc: Bool
    ) -> [DisplayPlaylist] {
        switch option {
        case .title:
            return playlists.sortedByCachedStringKey({ $0.title.sortingKey }, ascending: asc)
        case .trackCount:
            return playlists.sortedByComparableKey(\.trackCount, ascending: asc)
        case .duration:
            return playlists.sortedByComparableKey(\.duration, ascending: asc)
        case .dateAdded:
            return playlists.sortedByOptionalComparableKey(\.dateAdded, stableID: \.id, ascending: asc)
        case .dateModified:
            return playlists.sortedByOptionalComparableKey(\.dateModified, stableID: \.id, ascending: asc)
        case .lastPlayed:
            return playlists.sortedByOptionalComparableKey(\.lastPlayed, stableID: \.id, ascending: asc)
        }
    }

    private static func filterPlaylists(_ playlists: [Playlist], searchText: String) -> [Playlist] {
        guard !searchText.isEmpty else { return playlists }
        let searchLower = searchText.lowercased()
        return playlists.filter { $0.title.lowercased().contains(searchLower) }
    }

    /// Background queue for sort/filter computation so the main thread stays responsive
    private static let computeQueue = DispatchQueue(label: "com.ensemble.playlist-compute", qos: .userInitiated)

    /// Combine pipeline that caches sorted+filtered playlists whenever inputs change.
    /// Debounced on a background queue to avoid main-thread stutter (e.g. when .searchable reveals).
    private func setupFilteredPlaylistsPipeline() {
        Publishers.CombineLatest3($playlists, $playlistSortOption, $filterOptions)
            .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
            .map { playlists, sortOption, options -> [Playlist] in
                let sorted = Self.sortPlaylists(playlists, by: sortOption, ascending: options.sortDirection == .ascending)
                return Self.filterPlaylists(sorted, searchText: options.searchText)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playlists in
                if self?.filteredPlaylists != playlists {
                    self?.filteredPlaylists = playlists
                }
            }
            .store(in: &cancellables)
    }

    private func setupSortedPlaylistsPipeline() {
        Publishers.CombineLatest3(
            $playlists,
            $playlistSortOption,
            $filterOptions.map(\.sortDirection).removeDuplicates()
        )
        .debounce(for: .milliseconds(100), scheduler: Self.computeQueue)
        .map { playlists, sortOption, sortDirection -> [Playlist] in
            Self.sortPlaylists(playlists, by: sortOption, ascending: sortDirection == .ascending)
        }
        .removeDuplicates()
        .receive(on: DispatchQueue.main)
        .sink { [weak self] playlists in
            if self?.sortedPlaylists != playlists {
                self?.sortedPlaylists = playlists
            }
        }
        .store(in: &cancellables)
    }

    // MARK: - Merge Pipelines

    /// Filters raw playlists, then groups before sorting by aggregate display metadata.
    private func setupDisplayPlaylistsPipeline() {
        Publishers.CombineLatest4($playlists, $mergingPreferences, $playlistSortOption, $filterOptions)
            .debounce(for: .milliseconds(50), scheduler: Self.computeQueue)
            .map { playlists, preferences, sortOption, filterOptions -> [DisplayPlaylist] in
                let matching = Self.filterPlaylists(playlists, searchText: filterOptions.searchText)
                return Self.sortDisplayPlaylists(
                    DisplayPlaylist.group(
                        matching,
                        merge: preferences.isEnabled && preferences.mergePlaylists,
                        preferences: preferences
                    ),
                    by: sortOption,
                    ascending: filterOptions.sortDirection == .ascending
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playlists in
                if self?.displayPlaylists != playlists {
                    self?.displayPlaylists = playlists
                }
            }
            .store(in: &cancellables)
    }

    /// Groups raw playlists before aggregate sorting for the macOS sidebar.
    private func setupSortedDisplayPlaylistsPipeline() {
        Publishers.CombineLatest4(
            $playlists,
            $mergingPreferences,
            $playlistSortOption,
            $filterOptions.map(\.sortDirection).removeDuplicates()
        )
            .debounce(for: .milliseconds(50), scheduler: Self.computeQueue)
            .map { playlists, preferences, sortOption, sortDirection -> [DisplayPlaylist] in
                Self.sortDisplayPlaylists(
                    DisplayPlaylist.group(
                        playlists,
                        merge: preferences.isEnabled && preferences.mergePlaylists,
                        preferences: preferences
                    ),
                    by: sortOption,
                    ascending: sortDirection == .ascending
                )
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playlists in
                if self?.sortedDisplayPlaylists != playlists {
                    self?.sortedDisplayPlaylists = playlists
                }
            }
            .store(in: &cancellables)
    }

    /// Whether a playlist title has name collisions across servers (for showing server chips)
    public func hasNameCollision(_ title: String) -> Bool {
        nameCollisionTitles.contains(title)
    }

    /// Checks if a DisplayPlaylist contains any pending-creation playlists
    public func isDisplayPlaylistPendingCreation(_ dp: DisplayPlaylist) -> Bool {
        dp.playlists.contains { Self.isOptimisticCreatingPlaylistID($0.id) }
    }

    private func reloadPlaylists(showLoading: Bool) async {
        if showLoading && playlists.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            let serverPlaylists = try await fetchCachedPlaylists()
            optimisticCreatingPlaylists.removeAll { optimistic in
                serverPlaylists.contains(where: { matchesPlaylistIdentity($0, optimistic) })
            }
            let renamedApplied = applyOptimisticRenames(to: serverPlaylists)
            let merged = filterPlaylistsForSourceConfiguration(
                filterOptimisticallyDeletedPlaylists(
                    mergeWithOptimisticCreatingPlaylists(renamedApplied)
                )
            )

            // Never replace populated playlists with empty or degraded results.
            // CoreData can return empty mid-sync while records are being rebuilt,
            // or return partial records with empty titles before the full sync commits.
            let emptyTitleCount = merged.lazy.filter { $0.title.isEmpty }.count
            let hasDegradedData = emptyTitleCount > 0
            if merged.isEmpty && shouldTreatEmptyPlaylistCacheAsAuthoritative {
                clearLocalPlaylistCache(resetLastGoodSnapshot: true)
            } else if (merged.isEmpty || hasDegradedData) && !allPlaylists.isEmpty {
                EnsembleLogger.debug("📋 PlaylistViewModel: skipping degraded reload (\(merged.count) playlists, \(emptyTitleCount) empty titles, preserving \(self.allPlaylists.count) existing)")
            } else {
                publishPlaylistsIfChanged(merged)
                updateLastGoodSnapshotIfNeeded(merged)
            }
        } catch {
            self.error = error.localizedDescription
        }

        if showLoading && isLoading {
            isLoading = false
        }
    }

    private func seedFromLastGoodSnapshotIfAvailable() {
        let snapshot = Self.lastGoodPlaylistsSnapshot
        guard !snapshot.isEmpty else { return }
        let configuredSnapshot = filterPlaylistsForSourceConfiguration(snapshot)
        if configuredSnapshot != snapshot {
            Self.lastGoodPlaylistsSnapshot = configuredSnapshot
        }
        guard !configuredSnapshot.isEmpty else { return }
        allPlaylists = configuredSnapshot
        applyVisibilityToPublishedPlaylists()
        isShowingStaleSnapshot = true
    }

    private func seedFromPersistentCacheIfAvailable() {
        guard playlists.isEmpty,
              let repository = playlistRepository as? PlaylistRepository,
              let snapshot = try? repository.fetchPlaylistsSnapshot().map({ Playlist(from: $0) }) else {
            return
        }
        let filteredSnapshot = filterPlaylistsForSourceConfiguration(snapshot)
        guard !filteredSnapshot.isEmpty else { return }
        allPlaylists = filteredSnapshot
        applyVisibilityToPublishedPlaylists()
        updateLastGoodSnapshotIfNeeded(filteredSnapshot)
    }

    private func updateLastGoodSnapshotIfNeeded(_ playlists: [Playlist]) {
        guard !playlists.isEmpty, !playlists.contains(where: { $0.title.isEmpty }) else { return }
        if Self.lastGoodPlaylistsSnapshot != playlists {
            Self.lastGoodPlaylistsSnapshot = playlists
        }
        isShowingStaleSnapshot = false
    }

    private var shouldTreatEmptyPlaylistCacheAsAuthoritative: Bool {
        guard let accountManager else {
            return isShowingStaleSnapshot
        }

        let configuration = accountManager.sourceConfigurationSnapshot
        return configuration.isAuthoritative &&
            ((configuration.enabledSources.isEmpty && configuration.hasAnySources) ||
             !preservesAuthoritativeEmptySourceSnapshot)
    }

    private func clearLocalPlaylistCache(resetLastGoodSnapshot: Bool) {
        if resetLastGoodSnapshot {
            Self.lastGoodPlaylistsSnapshot = []
        }
        allPlaylists = []
        optimisticCreatingPlaylists = []
        optimisticRenamedPlaylistTitlesByIdentity = [:]
        optimisticDeletedPlaylistIdentities = []
        publishPlaylistsIfChanged([])
        visibleSnapshot = []
        filteredPlaylists = []
        sortedPlaylists = []
        displayPlaylists = []
        sortedDisplayPlaylists = []
        nameCollisionTitles = []
        isShowingStaleSnapshot = false
    }

    private func publishPlaylistsIfChanged(_ nextPlaylists: [Playlist]) {
        if allPlaylists != nextPlaylists {
            allPlaylists = nextPlaylists
        }
        applyVisibilityToPublishedPlaylists()
    }

    private func applyVisibilityToPublishedPlaylists() {
        let configuredPlaylists = filterPlaylistsForSourceConfiguration(allPlaylists)
        let sourceConfiguration = accountManager?.sourceConfigurationSnapshot
        let hiddenSourceCompositeKeys = visibilityStore.effectiveHiddenSourceCompositeKeys(
            enabledSourceCompositeKeys: sourceConfiguration?.enabledSourceKeys ?? []
        )
        let visiblePlaylists = configuredPlaylists.filter { playlist in
            guard !hiddenMediaStore.snapshot.isHidden(playlist) else { return false }
            guard let sourceKey = playlist.sourceCompositeKey else { return false }
            return !LibraryVisibilityFiltering.isHiddenSourceKey(
                sourceKey,
                hiddenSourceCompositeKeys: hiddenSourceCompositeKeys,
                sourceConfiguration: sourceConfiguration
            )
        }
        guard playlists != visiblePlaylists else { return }
        playlists = visiblePlaylists
        visibleSnapshot = visiblePlaylists
        applyDerivedPlaylistSnapshots(visiblePlaylists)
    }

    private func filterOptimisticallyDeletedPlaylists(_ playlists: [Playlist]) -> [Playlist] {
        guard !optimisticDeletedPlaylistIdentities.isEmpty else { return playlists }
        return playlists.filter { !optimisticDeletedPlaylistIdentities.contains($0.sourceScopedID) }
    }

    private func applyDerivedPlaylistSnapshots(_ snapshot: [Playlist]) {
        let nextSorted = Self.sortPlaylists(
            snapshot,
            by: playlistSortOption,
            ascending: filterOptions.sortDirection == .ascending
        )
        let matching = Self.filterPlaylists(snapshot, searchText: filterOptions.searchText)
        let nextFiltered = Self.sortPlaylists(
            matching,
            by: playlistSortOption,
            ascending: filterOptions.sortDirection == .ascending
        )
        let nextDisplay = Self.sortDisplayPlaylists(
            DisplayPlaylist.group(
                matching,
                merge: isMergeEnabled,
                preferences: mergingPreferences
            ),
            by: playlistSortOption,
            ascending: filterOptions.sortDirection == .ascending
        )
        let nextSortedDisplay = Self.sortDisplayPlaylists(
            DisplayPlaylist.group(
                snapshot,
                merge: isMergeEnabled,
                preferences: mergingPreferences
            ),
            by: playlistSortOption,
            ascending: filterOptions.sortDirection == .ascending
        )

        if filteredPlaylists != nextFiltered { filteredPlaylists = nextFiltered }
        if sortedPlaylists != nextSorted { sortedPlaylists = nextSorted }
        if displayPlaylists != nextDisplay { displayPlaylists = nextDisplay }
        if sortedDisplayPlaylists != nextSortedDisplay { sortedDisplayPlaylists = nextSortedDisplay }
        nameCollisionTitles = DisplayPlaylist.detectNameCollisions(snapshot)
    }

    private func scheduleCoalescedPlaylistReload(reason: String) {
        coalescedReloadTask?.cancel()
        coalescedReloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, !Task.isCancelled, !self.isRefreshingFromServer else { return }
            EnsembleLogger.debug("📋 PlaylistViewModel: coalesced reload reason=\(reason)")
            await self.loadPlaylists()
            self.coalescedReloadTask = nil
        }
    }

    private func handleSourceConfigurationChange(_ configuration: SourceConfigurationSnapshot) {
        let previous = lastObservedSourceConfiguration
        lastObservedSourceConfiguration = configuration

        let removedEnabledSources = previous?.enabledSourceKeys
            .subtracting(configuration.enabledSourceKeys) ?? []
        if configuration.hasAnySources {
            preservesAuthoritativeEmptySourceSnapshot = true
        } else if !removedEnabledSources.isEmpty || previous?.hasAnySources == true {
            preservesAuthoritativeEmptySourceSnapshot = false
        }

        optimisticCreatingPlaylists = filterPlaylistsForSourceConfiguration(
            optimisticCreatingPlaylists,
            configuration: configuration
        )
        let configured = filterPlaylistsForSourceConfiguration(
            allPlaylists,
            configuration: configuration
        )
        if configured != allPlaylists {
            publishPlaylistsIfChanged(configured)
            if !configured.contains(where: { $0.title.isEmpty }) {
                Self.lastGoodPlaylistsSnapshot = configured
            }
            if configured.isEmpty {
                isShowingStaleSnapshot = false
            }
        } else {
            applyVisibilityToPublishedPlaylists()
        }

        scheduleCoalescedPlaylistReload(reason: "source-configuration")
    }

    private func handleLibraryDataCleared() {
        coalescedReloadTask?.cancel()
        coalescedReloadTask = nil
        error = nil
        isLoading = false
        isRefreshingFromServer = false
        clearLocalPlaylistCache(resetLastGoodSnapshot: true)
    }

    private func awaitCreatedPlaylistMaterialization(title: String, serverSourceKey: String) async {
        for _ in 0..<20 {
            await reloadPlaylists(showLoading: false)
            let hasPending = optimisticCreatingPlaylists.contains(where: {
                normalizedTitle($0.title) == normalizedTitle(title) &&
                $0.sourceCompositeKey == serverSourceKey
            })
            if !hasPending {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func addOptimisticCreatingPlaylist(title: String, serverSourceKey: String) {
        let placeholder = Playlist(
            id: "\(Self.optimisticCreatePrefix)\(UUID().uuidString)",
            key: "/playlists/pending",
            title: title,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            dateAdded: Date(),
            dateModified: Date(),
            sourceCompositeKey: serverSourceKey
        )
        optimisticCreatingPlaylists.removeAll(where: { matchesPlaylistIdentity($0, placeholder) })
        optimisticCreatingPlaylists.append(placeholder)
        publishPlaylistsIfChanged(
            mergeWithOptimisticCreatingPlaylists(
                allPlaylists.filter { !Self.isOptimisticCreatingPlaylistID($0.id) }
            )
        )
    }

    private func removeOptimisticCreatingPlaylist(title: String, serverSourceKey: String) {
        optimisticCreatingPlaylists.removeAll {
            normalizedTitle($0.title) == normalizedTitle(title) &&
            $0.sourceCompositeKey == serverSourceKey
        }
    }

    private func mergeWithOptimisticCreatingPlaylists(_ serverPlaylists: [Playlist]) -> [Playlist] {
        let unresolvedOptimistic = optimisticCreatingPlaylists.filter { optimistic in
            !serverPlaylists.contains(where: { matchesPlaylistIdentity($0, optimistic) })
        }
        return serverPlaylists + unresolvedOptimistic
    }

    private func applyOptimisticRenames(to playlists: [Playlist]) -> [Playlist] {
        playlists.map { playlist in
            guard let optimisticTitle = optimisticRenamedPlaylistTitlesByIdentity[playlist.sourceScopedID] else {
                return playlist
            }
            return playlist.withTitle(optimisticTitle)
        }
    }

    public func applyOptimisticRename(for playlist: Playlist, newTitle: String) {
        applyOptimisticRename(forPlaylistIdentity: playlist.sourceScopedID, newTitle: newTitle)
    }

    public func applyOptimisticRename(forPlaylistIdentity playlistIdentity: String, newTitle: String) {
        optimisticRenamedPlaylistTitlesByIdentity[playlistIdentity] = newTitle
        publishPlaylistsIfChanged(applyOptimisticRenames(to: allPlaylists))
    }

    public func clearOptimisticRename(forPlaylistIdentity playlistIdentity: String) {
        optimisticRenamedPlaylistTitlesByIdentity.removeValue(forKey: playlistIdentity)
    }

    public func awaitRenamedPlaylistMaterialization(
        forPlaylistIdentity playlistIdentity: String,
        expectedTitle: String
    ) async {
        let normalizedExpectedTitle = normalizedTitle(expectedTitle)

        for _ in 0..<20 {
            do {
                let serverPlaylists = try await fetchCachedPlaylists()
                let hasMaterializedTitle = serverPlaylists.contains {
                    $0.sourceScopedID == playlistIdentity &&
                        normalizedTitle($0.title) == normalizedExpectedTitle
                }

                if hasMaterializedTitle {
                    clearOptimisticRename(forPlaylistIdentity: playlistIdentity)
                    publishPlaylistsIfChanged(
                        mergeWithOptimisticCreatingPlaylists(applyOptimisticRenames(to: serverPlaylists))
                    )
                    return
                }

                publishPlaylistsIfChanged(
                    mergeWithOptimisticCreatingPlaylists(applyOptimisticRenames(to: serverPlaylists))
                )
            } catch {
                self.error = error.localizedDescription
                return
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        clearOptimisticRename(forPlaylistIdentity: playlistIdentity)
        await reloadPlaylists(showLoading: false)
    }

    private static func isOptimisticCreatingPlaylistID(_ id: String) -> Bool {
        id.hasPrefix(optimisticCreatePrefix)
    }

    private func matchesPlaylistIdentity(_ lhs: Playlist, _ rhs: Playlist) -> Bool {
        normalizedTitle(lhs.title) == normalizedTitle(rhs.title) &&
        lhs.sourceCompositeKey == rhs.sourceCompositeKey
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func fetchCachedPlaylists() async throws -> [Playlist] {
        guard let accountManager else {
            return try await playlistRepository.fetchPlaylists().map { Playlist(from: $0) }
        }

        let configuration = accountManager.sourceConfigurationSnapshot
        let cachedPlaylists: [Playlist]
        if configuration.isAuthoritative &&
            (configuration.hasAnySources || !preservesAuthoritativeEmptySourceSnapshot) {
            var sourceKeys = configuration.enabledSourceKeys
            sourceKeys.formUnion(configuration.enabledSources.map { MediaSourceIdentity.serverSourceKey(for: $0) })
            guard !sourceKeys.isEmpty else { return [] }
            cachedPlaylists = try await playlistRepository.fetchPlaylists(sourceCompositeKeys: sourceKeys)
                .map(Playlist.init(from:))
        } else {
            cachedPlaylists = try await playlistRepository.fetchPlaylists().map(Playlist.init(from:))
        }

        return filterPlaylistsForSourceConfiguration(
            cachedPlaylists,
            configuration: accountManager.sourceConfigurationSnapshot
        )
    }

    private func filterPlaylistsForSourceConfiguration(
        _ playlists: [Playlist],
        configuration: SourceConfigurationSnapshot? = nil
    ) -> [Playlist] {
        guard let accountManager else {
            return playlists
        }

        let configuration = configuration ?? accountManager.sourceConfigurationSnapshot
        let sourceFilter = configuration.hasAnySources ||
            !configuration.isAuthoritative ||
            !preservesAuthoritativeEmptySourceSnapshot
            ? configuration
            : nil
        return LibraryVisibilityFiltering.visibleItems(
            playlists,
            hiddenSourceCompositeKeys: [],
            sourceConfiguration: sourceFilter
        )
    }
}

// MARK: - Playlist Detail ViewModel

@MainActor
public final class PlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var playlist: Playlist
    @Published public private(set) var tracks: [Track] = [] {
        didSet { updateDerivedTrackState() }
    }
    @Published public private(set) var playlistItems: [PlaylistItem] = []
    @Published public private(set) var availableGenres: [String] = []
    @Published public private(set) var filteredTracks: [Track] = []
    @Published public private(set) var totalDuration: String = "0 min"
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoadedTracks = false
    @Published public private(set) var hasUnavailableTracks = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions {
        didSet { updateDerivedTrackState() }
    }

    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private let hiddenMediaStore: HiddenMediaStore
    private let includesHidden: Bool
    private var cancellables = Set<AnyCancellable>()
    private var shouldSkipNextLoadAfterLocalEdit = false

    public init(
        playlist: Playlist,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        initialTracks: [Track]? = nil,
        initialItems: [PlaylistItem]? = nil,
        observesExternalChanges: Bool = true,
        hiddenMediaStore: HiddenMediaStore? = nil,
        includesHidden: Bool = false
    ) {
        let hiddenMediaStore = hiddenMediaStore ?? .shared
        self.playlist = playlist
        if let initialItems {
            self.playlistItems = initialItems
            self.tracks = initialItems.map(\.track)
            self.hasUnavailableTracks = initialItems.contains { !$0.isAvailable }
            self.hasLoadedTracks = true
        } else if let initialTracks {
            self.tracks = initialTracks
            self.hasLoadedTracks = true
        } else {
            self.isLoading = true
        }
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.hiddenMediaStore = hiddenMediaStore
        self.includesHidden = includesHidden
        self.filterOptions = FilterPersistence.load(for: "PlaylistDetail-\(playlist.id)")
        updateDerivedTrackState()
        hiddenMediaStore.$snapshot.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.updateDerivedTrackState()
        }.store(in: &cancellables)

        // Save filter options when they change
        setupFilterPersistence()

        if observesExternalChanges {
            // Re-fetch tracks when download, metadata, or playlist state changes.
            observeReloadTriggers()
            observePlaylistRefresh()
        }
    }

    private func setupFilterPersistence() {
        let playlistId = playlist.id
        FilterPersistence.observe($filterOptions, key: "PlaylistDetail-\(playlistId)", storingIn: &cancellables)
    }

    /// Reload tracks when playlists are refreshed (e.g. after adding/removing tracks via mutation).
    private func observePlaylistRefresh() {
        ViewModelNotificationObserver.observePlaylistRefresh(storingIn: &cancellables) { [weak self] in
            EnsembleLogger.debug("📋 PlaylistDetailViewModel: playlistsDidRefresh — reloading tracks")
            await self?.loadTracks()
        }
    }

    private func observeReloadTriggers() {
        ViewModelNotificationObserver.observeDownloadAndMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    public func loadTracks() async {
        if shouldSkipNextLoadAfterLocalEdit {
            shouldSkipNextLoadAfterLocalEdit = false
            return
        }

        isLoading = true
        error = nil

        do {
            if let cachedPlaylist = try await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) {
                // Refresh playlist metadata from cache so title/count stays current after edits.
                let loadedItems = cachedPlaylist.playlistItemsArray.map(PlaylistItem.init(from:))
                let nextPlaylist = Playlist(from: cachedPlaylist)
                let nextTracks = loadedItems.map(\.track)
                if playlist != nextPlaylist { playlist = nextPlaylist }
                if hasUnavailableTracks != cachedPlaylist.hasUnavailableTracks {
                    hasUnavailableTracks = cachedPlaylist.hasUnavailableTracks
                }
                if shouldPublishTrackSnapshot(nextTracks, cachedTrackCount: Int(cachedPlaylist.trackCount)) {
                    if playlistItems != loadedItems { playlistItems = loadedItems }
                    if tracks != nextTracks { tracks = nextTracks }
                } else {
                    EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': preserving \(self.tracks.count) tracks during empty intermediate reload")
                }
                let ptCount = (cachedPlaylist.playlistTracks as? Set<AnyHashable>)?.count ?? -1
                EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': trackCount=\(cachedPlaylist.trackCount), playlistTracks=\(ptCount), items=\(loadedItems.count), tracks=\(tracks.count)")
            } else {
                hasUnavailableTracks = false
                #if os(iOS)
                if playlist.sourceType == .appleMusic, #available(iOS 18, *) {
                    let catalogTracks = try await syncCoordinator.getAppleMusicCatalogPlaylistTracks(
                        playlistID: playlist.id
                    )
                    let catalogItems = catalogTracks.enumerated().map { index, track in
                        PlaylistItem(id: "catalog:\(index):\(track.sourceScopedID)", playlistItemID: nil, track: track)
                    }
                    if playlistItems != catalogItems { playlistItems = catalogItems }
                    if tracks != catalogTracks { tracks = catalogTracks }
                } else if !tracks.isEmpty {
                    EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': preserving \(self.tracks.count) tracks while cached playlist is temporarily unavailable")
                }
                #else
                if !tracks.isEmpty {
                    EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': preserving \(self.tracks.count) tracks while cached playlist is temporarily unavailable")
                }
                #endif
            }
        } catch {
            self.error = error.localizedDescription
        }

        hasLoadedTracks = true
        isLoading = false
    }

    /// Sync this playlist's tracks from the server, then reload from cache.
    /// Uses a detached task to survive SwiftUI `.refreshable` cancellation.
    public func refreshFromServer() async {
        guard !syncCoordinator.isOffline else {
            await loadTracks()
            return
        }
        guard !syncCoordinator.isSyncing else {
            await loadTracks()
            return
        }

        error = nil

        // Run in a detached task so SwiftUI's .refreshable cancellation doesn't kill the sync
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncPlaylistsOnly()
                continuation.resume()
            }
        }

        await loadTracks()
    }

    // MARK: - Filtered Collections

    private func updateDerivedTrackState() {
        let visibleTracks = includesHidden ? tracks : hiddenMediaStore.snapshot.visibleTracks(tracks)
        PlaylistDetailTrackDerivation.make(tracks: visibleTracks, filterOptions: filterOptions)
            .publishChanges(
                filteredTracks: &filteredTracks,
                availableGenres: &availableGenres,
                totalDuration: &totalDuration
            )
    }

    private func shouldPublishTrackSnapshot(_ nextTracks: [Track], cachedTrackCount: Int) -> Bool {
        if !nextTracks.isEmpty || tracks.isEmpty {
            return true
        }

        // A zero-track playlist is valid only when the cached metadata agrees.
        // During playlist refreshes CoreData can briefly expose relationships
        // before tracks are wired, which should not blank an already visible list.
        return cachedTrackCount == 0
    }

    @discardableResult
    public func renamePlaylist(to newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Playlist name cannot be empty."
            return false
        }

        let previousPlaylist = playlist
        playlist = playlist.withTitle(trimmed, dateModified: Date())
        error = nil

        do {
            _ = try await mutationCoordinator.renamePlaylist(playlist, to: trimmed)
            // Keep the optimistic title. MutationCoordinator persists it and emits
            // a refresh notification after the cache update succeeds.
            return true
        } catch {
            playlist = previousPlaylist
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func renamePlaylist(
        toTrimmedTitle trimmed: String,
        using workflow: PlaylistMutationWorkflow,
        scope: PlaylistMutationToastScope = .playlist
    ) async throws -> PlaylistRenameWorkflowResult {
        let previousPlaylist = playlist
        playlist = playlist.withTitle(trimmed, dateModified: Date())
        error = nil

        do {
            let result = try await workflow.finishRename(
                playlist: playlist,
                trimmedTitle: trimmed,
                scope: scope
            )
            // Keep the optimistic title until the persisted refresh arrives.
            return result
        } catch {
            playlist = previousPlaylist
            self.error = error.localizedDescription
            throw error
        }
    }

    public func deletePlaylist() async -> Bool {
        do {
            try await mutationCoordinator.deletePlaylist(playlist)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public var canEditPlaylistItems: Bool {
        guard playlist.supportsPlaylistEditing, !playlistItems.isEmpty,
              let sourceType = playlist.sourceType else { return false }
        return !sourceType.capabilities.playlistEditsRequireItemIdentifiers
            || playlistItems.allSatisfy { $0.playlistItemID != nil }
    }

    @discardableResult
    public func removeTrackFromPlaylist(_ track: Track, displayIndex: Int? = nil) async -> Bool {
        guard playlist.supportsPlaylistEditing else {
            error = PlaylistMutationError.smartPlaylistReadOnly.localizedDescription
            return false
        }
        guard let removalIndex = playlistTrackIndex(for: track, displayIndex: displayIndex) else {
            error = "Track is no longer in this playlist."
            return false
        }

        guard playlistItems.indices.contains(removalIndex) else {
            error = "Track is no longer in this playlist."
            return false
        }
        let previousItems = playlistItems
        let previousHasUnavailableTracks = hasUnavailableTracks
        var editedItems = playlistItems
        editedItems.remove(at: removalIndex)
        applyItemSnapshot(editedItems, skipNextLoadAfterLocalEdit: true)

        do {
            try await mutationCoordinator.editPlaylistItems(
                playlist,
                originalItems: previousItems,
                editedItems: editedItems
            )
            Task {
                // Refresh from cache once post-mutation sync catches up.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
            return true
        } catch {
            applyItemSnapshot(previousItems, skipNextLoadAfterLocalEdit: false)
            hasUnavailableTracks = previousHasUnavailableTracks
            self.error = error.localizedDescription
            return false
        }
    }

    private func playlistTrackIndex(for track: Track, displayIndex: Int?) -> Int? {
        if let displayIndex,
           filteredTracks.indices.contains(displayIndex),
           sameTrackIdentity(filteredTracks[displayIndex], track) {
            let precedingVisibleMatches = filteredTracks[..<displayIndex]
                .filter { sameTrackIdentity($0, track) }
                .count
            var seenMatches = 0
            for (index, candidate) in tracks.enumerated() where sameTrackIdentity(candidate, track) {
                if seenMatches == precedingVisibleMatches {
                    return index
                }
                seenMatches += 1
            }
        }

        return tracks.firstIndex(where: { sameTrackIdentity($0, track) })
    }

    private func sameTrackIdentity(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.playbackIdentity == rhs.playbackIdentity
    }

    private func applyTrackSnapshot(_ editedTracks: [Track], skipNextLoadAfterLocalEdit: Bool) {
        shouldSkipNextLoadAfterLocalEdit = skipNextLoadAfterLocalEdit
        tracks = editedTracks
        playlist = playlist.withTracks(editedTracks)
    }

    private func applyItemSnapshot(_ editedItems: [PlaylistItem], skipNextLoadAfterLocalEdit: Bool) {
        playlistItems = editedItems
        hasUnavailableTracks = editedItems.contains { !$0.isAvailable }
        applyTrackSnapshot(editedItems.map(\.track), skipNextLoadAfterLocalEdit: skipNextLoadAfterLocalEdit)
    }

    public func saveEditedItems(_ editedItems: [PlaylistItem]) async {
        let previousItems = playlistItems
        let previousHasUnavailableTracks = hasUnavailableTracks
        // Apply immediately so playlist detail reflects edits before network roundtrip.
        applyItemSnapshot(editedItems, skipNextLoadAfterLocalEdit: true)

        do {
            try await mutationCoordinator.editPlaylistItems(
                playlist,
                originalItems: previousItems,
                editedItems: editedItems
            )
            Task {
                // Refresh from cache once post-mutation sync catches up.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
        } catch {
            applyItemSnapshot(previousItems, skipNextLoadAfterLocalEdit: false)
            hasUnavailableTracks = previousHasUnavailableTracks
            self.error = error.localizedDescription
        }
    }
}
