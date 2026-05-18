import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class PlaylistViewModel: ObservableObject {
    private static let optimisticCreatePrefix = "creating:"
    private static var lastGoodPlaylistsSnapshot: [Playlist] = []

    static func resetLastGoodSnapshotForTesting() {
        lastGoodPlaylistsSnapshot = []
    }

    @Published public private(set) var playlists: [Playlist] = []
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

    /// Whether cross-server playlist merging is enabled (persisted via SettingsManager)
    @Published public var isMergeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMergeEnabled, forKey: "playlistMergeEnabled")
        }
    }
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
    private var cancellables = Set<AnyCancellable>()
    private var optimisticCreatingPlaylists: [Playlist] = []
    private var optimisticRenamedPlaylistTitlesByID: [String: String] = [:]
    /// Suppresses observer-triggered reloads during pull-to-refresh so intermediate
    /// CoreData states (partial data while sync rebuilds records) don't clobber the list.
    /// Published so the view can freeze its cached list during refresh.
    @Published public private(set) var isRefreshingFromServer = false

    public init(
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        toastCenter: ToastCenter,
        accountManager: AccountManager? = nil
    ) {
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.toastCenter = toastCenter
        self.accountManager = accountManager
        self.isMergeEnabled = UserDefaults.standard.bool(forKey: "playlistMergeEnabled")
        let savedFilters = FilterPersistence.load(for: "Playlists")
        self.filterOptions = savedFilters

        // Load sort option from filters
        if let savedSort = PlaylistSortOption(rawValue: savedFilters.sortBy) {
            self.playlistSortOption = savedSort
        }

        seedFromLastGoodSnapshotIfAvailable()

        // Save filter options when they change
        setupFilterPersistence()

        // Cache sorted+filtered playlists so they aren't recomputed on every SwiftUI body access
        setupFilteredPlaylistsPipeline()
        setupSortedPlaylistsPipeline()

        // Merge-aware pipelines that group playlists into DisplayPlaylist entries
        setupDisplayPlaylistsPipeline()
        setupSortedDisplayPlaylistsPipeline()

        // Auto-reload when sync completes (skip during pull-to-refresh — it does its own reload)
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing, self?.isRefreshingFromServer != true {
                    Task { @MainActor in
                        await self?.loadPlaylists()
                    }
                }
            }
            .store(in: &cancellables)

        // Auto-reload when playlists are refreshed after a mutation (e.g. track counts changed)
        NotificationCenter.default.publisher(for: SyncCoordinator.playlistsDidRefresh)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] notification in
                guard self?.isRefreshingFromServer != true else { return }
                let serverKey = notification.userInfo?["serverSourceKey"] as? String ?? "unknown"
                EnsembleLogger.debug("📋 PlaylistViewModel: playlistsDidRefresh notification from \(serverKey)")
                Task { @MainActor in
                    await self?.loadPlaylists()
                }
            }
            .store(in: &cancellables)

    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Playlists") }
            .store(in: &cancellables)
    }

    public func loadPlaylists() async {
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
            let outcome = try await mutationCoordinator.deletePlaylist(playlist)
            if outcome == .queued {
                // Optimistically remove from list while queued
                playlists.removeAll { $0.id == playlist.id }
            }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func applyOptimisticDelete(for playlist: Playlist) {
        playlists.removeAll { $0.id == playlist.id }
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

    private static func sortPlaylists(_ playlists: [Playlist], by option: PlaylistSortOption, ascending asc: Bool) -> [Playlist] {
        switch option {
        case .title:
            // Pre-compute sort keys to avoid O(n log n) calls to sortingKey
            return sortByCachedKey(playlists, keyExtractor: { $0.title.sortingKey }, ascending: asc)
        case .trackCount:
            return playlists.sorted { asc ? $0.trackCount < $1.trackCount : $0.trackCount > $1.trackCount }
        case .duration:
            return playlists.sorted { asc ? $0.duration < $1.duration : $0.duration > $1.duration }
        case .dateAdded:
            return playlists.sorted { asc
                ? ($0.dateAdded ?? .distantPast) < ($1.dateAdded ?? .distantPast)
                : ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast)
            }
        case .dateModified:
            return playlists.sorted { asc
                ? ($0.dateModified ?? .distantPast) < ($1.dateModified ?? .distantPast)
                : ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast)
            }
        case .lastPlayed:
            return playlists.sorted { asc
                ? ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast)
                : ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast)
            }
        }
    }

    /// Sort by pre-computed string keys — computes sortingKey once per element.
    /// Uses ID as tiebreaker for stable ordering (prevents flicker when items share the same sort key).
    private static func sortByCachedKey<T: Identifiable>(_ items: [T], keyExtractor: (T) -> String, ascending: Bool) -> [T] where T.ID == String {
        let keyed = items.map { ($0, keyExtractor($0)) }
        return keyed.sorted {
            let result = $0.1.localizedStandardCompare($1.1)
            if result == .orderedSame {
                return $0.0.id < $1.0.id
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map { $0.0 }
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
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.filteredPlaylists = $0 }
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
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.sortedPlaylists = $0 }
        .store(in: &cancellables)
    }

    // MARK: - Merge Pipelines

    /// Downstream pipeline: groups filteredPlaylists into DisplayPlaylist entries based on merge toggle
    private func setupDisplayPlaylistsPipeline() {
        Publishers.CombineLatest($filteredPlaylists, $isMergeEnabled)
            .debounce(for: .milliseconds(50), scheduler: Self.computeQueue)
            .map { playlists, merge -> [DisplayPlaylist] in
                DisplayPlaylist.group(playlists, merge: merge)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.displayPlaylists = $0 }
            .store(in: &cancellables)
    }

    /// Downstream pipeline: groups sortedPlaylists for the macOS sidebar
    private func setupSortedDisplayPlaylistsPipeline() {
        Publishers.CombineLatest($sortedPlaylists, $isMergeEnabled)
            .debounce(for: .milliseconds(50), scheduler: Self.computeQueue)
            .map { playlists, merge -> [DisplayPlaylist] in
                DisplayPlaylist.group(playlists, merge: merge)
            }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.sortedDisplayPlaylists = $0 }
            .store(in: &cancellables)
    }

    // MARK: - Merge Helpers

    /// Toggles the cross-server merge setting
    public func toggleMerge() {
        isMergeEnabled.toggle()
    }

    /// Whether a playlist title has name collisions across servers (for showing server chips)
    public func hasNameCollision(_ title: String) -> Bool {
        nameCollisionTitles.contains(title)
    }

    /// Checks if a DisplayPlaylist contains any pending-creation playlists
    public func isDisplayPlaylistPendingCreation(_ dp: DisplayPlaylist) -> Bool {
        dp.playlists.contains { Self.isOptimisticCreatingPlaylistID($0.id) }
    }

    /// Deletes all constituent playlists in a merged DisplayPlaylist
    public func deleteMergedPlaylist(_ dp: DisplayPlaylist) async -> Bool {
        var allSucceeded = true
        for playlist in dp.playlists {
            let success = await deletePlaylist(playlist)
            if !success { allSucceeded = false }
        }
        return allSucceeded
    }

    /// Applies optimistic rename to all constituents of a merged DisplayPlaylist
    public func applyOptimisticRenameForMerged(_ dp: DisplayPlaylist, newTitle: String) {
        for playlist in dp.playlists {
            applyOptimisticRename(forPlaylistID: playlist.id, newTitle: newTitle)
        }
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
            let merged = mergeWithOptimisticCreatingPlaylists(renamedApplied)

            // Never replace populated playlists with empty or degraded results.
            // CoreData can return empty mid-sync while records are being rebuilt,
            // or return partial records with empty titles before the full sync commits.
            let hasDegradedData = merged.contains { $0.title.isEmpty }
            if merged.isEmpty && shouldTreatEmptyPlaylistCacheAsAuthoritative {
                clearLocalPlaylistCache(resetLastGoodSnapshot: true)
            } else if (merged.isEmpty || hasDegradedData) && !playlists.isEmpty {
                EnsembleLogger.debug("📋 PlaylistViewModel: skipping degraded reload (\(merged.count) playlists, \(merged.filter { $0.title.isEmpty }.count) empty titles, preserving \(self.playlists.count) existing)")
            } else {
                publishPlaylistsIfChanged(merged)
                nameCollisionTitles = DisplayPlaylist.detectNameCollisions(merged)
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
        playlists = snapshot
        filteredPlaylists = Self.filterPlaylists(
            Self.sortPlaylists(
                snapshot,
                by: playlistSortOption,
                ascending: filterOptions.sortDirection == .ascending
            ),
            searchText: filterOptions.searchText
        )
        sortedPlaylists = Self.sortPlaylists(
            snapshot,
            by: playlistSortOption,
            ascending: filterOptions.sortDirection == .ascending
        )
        displayPlaylists = DisplayPlaylist.group(filteredPlaylists, merge: isMergeEnabled)
        sortedDisplayPlaylists = DisplayPlaylist.group(sortedPlaylists, merge: isMergeEnabled)
        nameCollisionTitles = DisplayPlaylist.detectNameCollisions(snapshot)
        isShowingStaleSnapshot = true
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

        return !accountManager.isAwaitingCloudSources && accountManager.enabledSources().isEmpty
    }

    private func clearLocalPlaylistCache(resetLastGoodSnapshot: Bool) {
        if resetLastGoodSnapshot {
            Self.lastGoodPlaylistsSnapshot = []
        }
        optimisticCreatingPlaylists = []
        optimisticRenamedPlaylistTitlesByID = [:]
        publishPlaylistsIfChanged([])
        filteredPlaylists = []
        sortedPlaylists = []
        displayPlaylists = []
        sortedDisplayPlaylists = []
        nameCollisionTitles = []
        isShowingStaleSnapshot = false
    }

    private func publishPlaylistsIfChanged(_ nextPlaylists: [Playlist]) {
        guard playlists != nextPlaylists else { return }
        playlists = nextPlaylists
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
        playlists = mergeWithOptimisticCreatingPlaylists(playlists.filter { !Self.isOptimisticCreatingPlaylistID($0.id) })
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
            guard let optimisticTitle = optimisticRenamedPlaylistTitlesByID[playlist.id] else {
                return playlist
            }
            return Playlist(
                id: playlist.id,
                key: playlist.key,
                title: optimisticTitle,
                summary: playlist.summary,
                isSmart: playlist.isSmart,
                trackCount: playlist.trackCount,
                duration: playlist.duration,
                compositePath: playlist.compositePath,
                dateAdded: playlist.dateAdded,
                dateModified: playlist.dateModified,
                lastPlayed: playlist.lastPlayed,
                sourceCompositeKey: playlist.sourceCompositeKey
            )
        }
    }

    public func applyOptimisticRename(for playlist: Playlist, newTitle: String) {
        applyOptimisticRename(forPlaylistID: playlist.id, newTitle: newTitle)
    }

    public func applyOptimisticRename(forPlaylistID playlistID: String, newTitle: String) {
        optimisticRenamedPlaylistTitlesByID[playlistID] = newTitle
        playlists = applyOptimisticRenames(to: playlists)
    }

    public func clearOptimisticRename(for playlistID: String) {
        optimisticRenamedPlaylistTitlesByID.removeValue(forKey: playlistID)
    }

    public func awaitRenamedPlaylistMaterialization(for playlistID: String, expectedTitle: String) async {
        let normalizedExpectedTitle = normalizedTitle(expectedTitle)

        for _ in 0..<20 {
            do {
                let serverPlaylists = try await fetchCachedPlaylists()
                let hasMaterializedTitle = serverPlaylists.contains {
                    $0.id == playlistID && normalizedTitle($0.title) == normalizedExpectedTitle
                }

                if hasMaterializedTitle {
                    clearOptimisticRename(for: playlistID)
                    playlists = mergeWithOptimisticCreatingPlaylists(serverPlaylists)
                    return
                }

                playlists = mergeWithOptimisticCreatingPlaylists(applyOptimisticRenames(to: serverPlaylists))
            } catch {
                self.error = error.localizedDescription
                return
            }

            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        clearOptimisticRename(for: playlistID)
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
        let cached = try await playlistRepository.fetchPlaylists()
        let playlists = cached.map { Playlist(from: $0) }
        guard let accountManager else {
            return playlists
        }

        let enabledSources = accountManager.enabledSources()
        guard !enabledSources.isEmpty else {
            return []
        }

        let enabledLibraryKeys = Set(enabledSources.map(\.compositeKey))
        let enabledServerKeys = Set(enabledSources.map { MediaSourceIdentity.serverSourceKey(for: $0) })
        return playlists.filter {
            Self.isPlaylistSourceEnabled(
                $0.sourceCompositeKey,
                enabledLibraryKeys: enabledLibraryKeys,
                enabledServerKeys: enabledServerKeys
            )
        }
    }

    private static func isPlaylistSourceEnabled(
        _ sourceCompositeKey: String?,
        enabledLibraryKeys: Set<String>,
        enabledServerKeys: Set<String>
    ) -> Bool {
        guard let sourceCompositeKey else { return false }
        if enabledLibraryKeys.contains(sourceCompositeKey) { return true }
        guard let serverKey = MediaSourceIdentity.serverSourceKey(from: sourceCompositeKey) else { return false }
        return enabledServerKeys.contains(serverKey)
    }
}

// MARK: - Playlist Detail ViewModel

@MainActor
public final class PlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var playlist: Playlist
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoadedTracks = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    private let playlistRepository: PlaylistRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var shouldSkipNextLoadAfterLocalEdit = false

    public init(
        playlist: Playlist,
        playlistRepository: PlaylistRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        initialTracks: [Track]? = nil
    ) {
        self.playlist = playlist
        if let initialTracks {
            self.tracks = initialTracks
            self.hasLoadedTracks = true
        }
        self.playlistRepository = playlistRepository
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.filterOptions = FilterPersistence.load(for: "PlaylistDetail-\(playlist.id)")

        // Save filter options when they change
        setupFilterPersistence()

        // Re-fetch tracks when download state changes so offline dimming is accurate
        observeDownloadChanges()

        // Re-fetch tracks when playlists are refreshed after a mutation (e.g. tracks added)
        observePlaylistRefresh()
        observeMetadataChanges()
    }

    private func setupFilterPersistence() {
        let playlistId = playlist.id
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "PlaylistDetail-\(playlistId)") }
            .store(in: &cancellables)
    }

    private func observeDownloadChanges() {
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)
    }

    /// Reload tracks when playlists are refreshed (e.g. after adding/removing tracks via mutation).
    private func observePlaylistRefresh() {
        NotificationCenter.default.publisher(for: SyncCoordinator.playlistsDidRefresh)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                EnsembleLogger.debug("📋 PlaylistDetailViewModel: playlistsDidRefresh — reloading tracks")
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)

    }

    private func observeMetadataChanges() {
        NotificationCenter.default.publisher(for: MetadataMutationService.metadataDidChange)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)
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
                let loadedTracks = cachedPlaylist.tracksArray
                let nextPlaylist = Playlist(from: cachedPlaylist)
                let nextTracks = loadedTracks.map { Track(from: $0) }
                playlist = nextPlaylist
                if shouldPublishTrackSnapshot(nextTracks, cachedTrackCount: Int(cachedPlaylist.trackCount)) {
                    tracks = nextTracks
                } else {
                    EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': preserving \(self.tracks.count) tracks during empty intermediate reload")
                }
                let ptCount = (cachedPlaylist.playlistTracks as? Set<AnyHashable>)?.count ?? -1
                EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': trackCount=\(cachedPlaylist.trackCount), playlistTracks=\(ptCount), tracksArray=\(loadedTracks.count), tracks=\(tracks.count)")
            } else {
                if tracks.isEmpty {
                    tracks = []
                } else {
                    EnsembleLogger.debug("📋 PlaylistDetailVM.loadTracks '\(playlist.title)': preserving \(self.tracks.count) tracks while cached playlist is temporarily unavailable")
                }
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

    /// Available genres for chip bar filtering (derived from playlist tracks)
    public var availableGenres: [String] {
        LibraryViewModel.extractUniqueGenres(from: tracks.flatMap(\.genres))
    }

    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
    }

    public var totalDuration: String {
        let total = filteredTracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(minutes) min"
    }
    
    // MARK: - Filter Application
    
    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        MediaFilterEngine.filterTracks(tracks, with: options, configuration: .playlistDetail)
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
        playlist = Playlist(
            id: playlist.id,
            key: playlist.key,
            title: trimmed,
            summary: playlist.summary,
            isSmart: playlist.isSmart,
            trackCount: playlist.trackCount,
            duration: playlist.duration,
            compositePath: playlist.compositePath,
            dateAdded: playlist.dateAdded,
            dateModified: Date(),
            lastPlayed: playlist.lastPlayed,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        error = nil

        do {
            let outcome = try await mutationCoordinator.renamePlaylist(playlist, to: trimmed)
            if outcome == .completed {
                await loadTracks()
            }
            // If queued, keep the optimistic rename and it will sync when back online
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
        playlist = Playlist(
            id: playlist.id,
            key: playlist.key,
            title: trimmed,
            summary: playlist.summary,
            isSmart: playlist.isSmart,
            trackCount: playlist.trackCount,
            duration: playlist.duration,
            compositePath: playlist.compositePath,
            dateAdded: playlist.dateAdded,
            dateModified: Date(),
            lastPlayed: playlist.lastPlayed,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        error = nil

        do {
            let result = try await workflow.finishRename(
                playlist: playlist,
                trimmedTitle: trimmed,
                scope: scope
            )
            if result.outcome == .completed {
                await loadTracks()
            }
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

    public func applyEditedTracksLocally(_ editedTracks: [Track]) {
        applyTrackSnapshot(editedTracks, skipNextLoadAfterLocalEdit: true)
    }

    @discardableResult
    public func removeTrackFromPlaylist(_ track: Track, displayIndex: Int? = nil) async -> Bool {
        guard !playlist.isSmart else {
            error = PlaylistMutationError.smartPlaylistReadOnly.localizedDescription
            return false
        }
        guard let removalIndex = playlistTrackIndex(for: track, displayIndex: displayIndex) else {
            error = "Track is no longer in this playlist."
            return false
        }

        let previousTracks = tracks
        var editedTracks = tracks
        editedTracks.remove(at: removalIndex)
        applyTrackSnapshot(editedTracks, skipNextLoadAfterLocalEdit: true)

        do {
            try await mutationCoordinator.replacePlaylistContents(playlist, with: editedTracks)
            Task {
                // Refresh from cache once post-mutation sync catches up.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
            return true
        } catch {
            applyTrackSnapshot(previousTracks, skipNextLoadAfterLocalEdit: false)
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
        playlist = Playlist(
            id: playlist.id,
            key: playlist.key,
            title: playlist.title,
            summary: playlist.summary,
            isSmart: playlist.isSmart,
            trackCount: editedTracks.count,
            duration: editedTracks.reduce(0) { $0 + $1.duration },
            compositePath: playlist.compositePath,
            dateAdded: playlist.dateAdded,
            dateModified: Date(),
            lastPlayed: playlist.lastPlayed,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
    }

    public func saveEditedTracks(_ editedTracks: [Track]) async {
        // Apply immediately so playlist detail reflects edits before network roundtrip.
        applyTrackSnapshot(editedTracks, skipNextLoadAfterLocalEdit: true)

        do {
            try await mutationCoordinator.replacePlaylistContents(playlist, with: editedTracks)
            Task {
                // Refresh from cache once post-mutation sync catches up.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
