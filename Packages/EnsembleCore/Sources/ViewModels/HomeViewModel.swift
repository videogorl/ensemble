import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// ViewModel for the Home screen that displays dynamic content hubs from Plex servers
@MainActor
public final class HomeViewModel: ObservableObject {
    enum AutoRefreshReason: String, Hashable {
        case accountChange
        case contentChange
        case periodicTimer
    }

    @Published public private(set) var hubs: [Hub] = []
    @Published public private(set) var isLoading = true
    @Published public private(set) var error: String?
    @Published public private(set) var hasConfiguredAccounts = false
    @Published public private(set) var hasEnabledLibraries = false
    @Published public private(set) var isRestoringCloudSources = false
    @Published public private(set) var readinessSnapshot = AppReadinessSnapshot()
    @Published public private(set) var isFeedCacheStale = false
    @Published public private(set) var lastFeedCacheRefreshDate: Date?
    
    // Edit mode state
    @Published public var isEditingOrder = false
    @Published public var editableHubs: [Hub] = []
    @Published public private(set) var currentSourceName: String = ""
    
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let hubLoader: HomeHubLoaderProtocol
    private let hubOrderManager: HubOrderManager
    private let visibilityStore: LibraryVisibilityStore
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let appReadinessCoordinator: AppReadinessCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTriggerCancellables = Set<AnyCancellable>()
    private var cachedSnapshotRestoreTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var contentGeneration: UInt64 = 0
    private var lastLoadTime: Date?
    private var isViewVisible = false
    private var pendingAutoRefreshReasons = Set<AutoRefreshReason>()
    private var unfilteredHubs: [Hub] = []
    private var lastConfiguredSourceKeys = Set<String>()
    private var lastEnabledSourceKeys = Set<String>()
    private var lastSourceConfigurationHadSources = false
    private var preservesAuthoritativeEmptySourceSnapshot = true

    // Startup suppression: the explicit .task load IS the startup load;
    // auto-refresh should not fire additional loads until it completes.
    private var initialLoadCompleted = false

    // Tracks when the last network hub fetch completed, so Feed can render
    // cached content on navigation without reloading until the refresh window.
    private var lastNetworkHubFetchTime: Date?
    private var lastAutomaticHubRefreshAttemptTime: Date?

    // Automatic Feed refresh cadence. Manual pull-to-refresh bypasses this.
    private var hubRefreshTimer: Timer?
    private let hubRefreshInterval: TimeInterval = 10 * 60  // 10 minutes
    
    // Debounce interval to prevent rapid successive loads
    private let debounceInterval: TimeInterval = 2.0
    private let startupHealthCheckPollNanoseconds: UInt64 = 100_000_000
    private let startupHealthCheckWaitTimeout: TimeInterval = 12.0
    private let feedCacheStaleInterval: TimeInterval = 6 * 60 * 60

    // Rotating count for hub requests — different counts cause PMS to select
    // different dynamic hub content (e.g. "More by...", "More in..." sections)
    private var refreshCount: Int = 0
    private static let hubCountOptions = [12, 15, 18, 20]

    /// Returns a count parameter that rotates on each pull-to-refresh,
    /// encouraging PMS to pick different dynamic hub content
    private var currentHubCount: String {
        let index = refreshCount % Self.hubCountOptions.count
        return String(Self.hubCountOptions[index])
    }
    internal var autoRefreshRunnerForTesting: ((AutoRefreshReason) async -> Void)?
    internal var loadHubsRunnerForTesting: ((Bool) async -> Void)?
    internal var waitForStartupHealthChecksRunnerForTesting: (() async -> Void)?
    
    public init(
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        hubLoader: HomeHubLoaderProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        hubOrderManager: HubOrderManager = HubOrderManager(),
        visibilityStore: LibraryVisibilityStore? = nil,
        appReadinessCoordinator: AppReadinessCoordinator? = nil
    ) {
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.hubLoader = hubLoader
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.hubOrderManager = hubOrderManager
        self.visibilityStore = visibilityStore ?? .shared
        self.appReadinessCoordinator = appReadinessCoordinator
        self.readinessSnapshot = appReadinessCoordinator?.snapshot ?? AppReadinessSnapshot()
        let initialSourceConfiguration = accountManager.sourceConfigurationSnapshot
        self.lastConfiguredSourceKeys = Set(initialSourceConfiguration.configuredSources.map(\.compositeKey))
        self.lastEnabledSourceKeys = initialSourceConfiguration.enabledSourceKeys
        self.lastSourceConfigurationHadSources = initialSourceConfiguration.hasAnySources
        updateSourceAvailability(initialSourceConfiguration)

        appReadinessCoordinator?.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                self.readinessSnapshot = snapshot
                self.hasConfiguredAccounts = snapshot.hasConfiguredAccounts
                self.hasEnabledLibraries = snapshot.hasEnabledLibraries
                self.isRestoringCloudSources = snapshot.isRestoringCloudSources
            }
            .store(in: &cancellables)

        accountManager.$isAwaitingCloudSources
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRestoringCloudSources)

        accountManager.sourceConfigurationPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] configuration in
                self?.handleSourceConfigurationChange(configuration)
            }
            .store(in: &cancellables)

        syncCoordinator.$isOffline
            .removeDuplicates()
            .dropFirst()
            .filter { !$0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.flushDeferredAutoRefreshIfVisible()
            }
            .store(in: &cancellables)
        
        // Load cached hubs immediately for offline-first experience.
        let cacheRestoreGeneration = contentGeneration
        cachedSnapshotRestoreTask = Task { @MainActor [weak self] in
            await self?.restoreCachedHubs(generation: cacheRestoreGeneration)
        }
        
        self.visibilityStore.$profiles
            .combineLatest(self.visibilityStore.$activeProfileID)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.applyVisibilityToPublishedHubs()
            }
            .store(in: &cancellables)

        // Safety timeout: if the initial .task load never completes (e.g. no
        // configured accounts), unblock auto-refresh after 15 seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard let self, !self.initialLoadCompleted else { return }
            self.markInitialLoadCompleted()
            self.appReadinessCoordinator?.markBootstrapSettled()
            EnsembleLogger.debug("🏠 Home initial load safety timeout — unblocking auto-refresh")
        }

        ViewModelNotificationObserver.observeLibraryDataCleared(storingIn: &cancellables) { [weak self] in
            self?.handleLibraryDataCleared()
        }
        ViewModelNotificationObserver.observeSourceCleanupCompleted(storingIn: &cancellables) { [weak self] in
            self?.handleSourceCleanupCompleted()
        }
    }
    
    deinit {
        // Invalidate timer directly without calling @MainActor method from nonisolated deinit
        hubRefreshTimer?.invalidate()
        refreshTriggerCancellables.removeAll()
    }
    
    /// Load the Feed when the current app session has no fresh network snapshot.
    /// Cached hubs are shown immediately from init; this only controls whether
    /// entering Feed should revalidate them with Plex.
    public func loadHubsIfNeeded(applySavedOrder: Bool = true) async {
        updateSourceAvailability()
        guard hasEnabledLibraries else {
            clearHubContentIfUnavailableSourcesAreSettled()
            return
        }

        await cachedSnapshotRestoreTask?.value

        if !hubs.isEmpty, !shouldRefreshHubsForAutomaticLoad {
            markInitialLoadCompleted()
            isLoading = false
            EnsembleLogger.debug("🏠 Feed automatic load skipped detail=freshCachedContent")
            return
        }

        guard shouldRefreshHubsForAutomaticLoad else {
            EnsembleLogger.debug("🏠 Feed automatic load skipped detail=fresh")
            return
        }

        lastAutomaticHubRefreshAttemptTime = Date()
        await loadHubs(applySavedOrder: applySavedOrder)
    }

    /// Load hubs from all configured accounts with debouncing and offline-first caching
    public func loadHubs(applySavedOrder: Bool = true) async {
        updateSourceAvailability()
        guard hasEnabledLibraries else {
            clearHubContentIfUnavailableSourcesAreSettled()
            return
        }

        await waitForStartupHealthChecksIfNeeded()
        guard !Task.isCancelled else { return }

        // Check if we should debounce
        if let lastLoad = lastLoadTime,
           Date().timeIntervalSince(lastLoad) < debounceInterval {
            return
        }
        
        // Invalidate any response that started before this load. Providers may
        // complete work after cancellation, so cancellation alone is insufficient.
        contentGeneration &+= 1
        let generation = contentGeneration
        loadTask?.cancel()
        
        // Record load time for debouncing
        lastLoadTime = Date()

        if let loadHubsRunnerForTesting {
            await loadHubsRunnerForTesting(applySavedOrder)
            return
        }

        let task = Task { @MainActor in
            isLoading = true
            error = nil

            let snapshot = await hubLoader.loadSnapshot(
                applySavedOrder: applySavedOrder,
                hubCount: self.currentHubCount
            )
            guard generation == contentGeneration, !Task.isCancelled else { return }

            guard let snapshot else {
                if hubs.isEmpty {
                    appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: false)
                    loadTask = nil
                    clearHubContentIfUnavailableSourcesAreSettled()
                    markInitialLoadCompleted()
                } else {
                    isLoading = false
                    isFeedCacheStale = true
                    loadTask = nil
                    markInitialLoadCompleted()
                    EnsembleLogger.debug("🏠 Feed preserving cached hubs after unavailable network snapshot")
                }
                return
            }

            guard !snapshot.orderedHubs.isEmpty else {
                if hubs.isEmpty {
                    appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: false)
                    loadTask = nil
                    clearHubContentIfUnavailableSourcesAreSettled()
                    markInitialLoadCompleted()
                } else {
                    isLoading = false
                    isFeedCacheStale = true
                    loadTask = nil
                    markInitialLoadCompleted()
                    EnsembleLogger.debug("🏠 Feed preserving cached hubs after empty network snapshot")
                }
                return
            }

            currentSourceName = snapshot.metadata.currentSourceName
            appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: true)
            if isViewVisible || hubs.isEmpty {
                await applyHubSnapshot(
                    snapshot.orderedHubs,
                    source: "network",
                    generation: generation
                )
            } else {
                EnsembleLogger.debug("🏠 Feed preserving visible hubs after hidden network refresh")
            }
            guard generation == contentGeneration, !Task.isCancelled else { return }

            isLoading = false
            lastNetworkHubFetchTime = snapshot.metadata.networkFetchCompletedAt
            lastFeedCacheRefreshDate = snapshot.metadata.networkFetchCompletedAt
            isFeedCacheStale = false
            loadTask = nil
            markInitialLoadCompleted()
        }
        loadTask = task

        await task.value
    }

    /// Prevent the first Feed network fetch from racing ahead of startup
    /// health checks, which can force a stale server URL to burn a full
    /// request timeout before connection failover has a working endpoint.
    private func waitForStartupHealthChecksIfNeeded() async {
        guard !initialLoadCompleted else { return }

        if let waitForStartupHealthChecksRunnerForTesting {
            await waitForStartupHealthChecksRunnerForTesting()
            return
        }

        guard syncCoordinator.lastHealthCheckCompletion == nil else { return }
        guard !syncCoordinator.isOffline else { return }

        EnsembleLogger.debug("🏠 Waiting for startup health checks before initial Feed network fetch")

        let waitStart = Date()
        while syncCoordinator.lastHealthCheckCompletion == nil && !syncCoordinator.isOffline {
            guard !Task.isCancelled else { return }

            let elapsed = Date().timeIntervalSince(waitStart)
            if elapsed >= startupHealthCheckWaitTimeout {
                EnsembleLogger.debug(
                    "🏠 Startup health check wait timed out after \(String(format: "%.1f", elapsed))s; proceeding with Feed fetch"
                )
                return
            }

            try? await Task.sleep(nanoseconds: startupHealthCheckPollNanoseconds)
        }

        let elapsed = Date().timeIntervalSince(waitStart)
        let reason = syncCoordinator.lastHealthCheckCompletion != nil ? "healthChecksCompleted" : "offline"
        EnsembleLogger.debug(
            "🏠 Initial Feed network fetch unblocked reason=\(reason) elapsed=\(String(format: "%.1f", elapsed))s"
        )
    }

    private func restoreCachedHubs(generation: UInt64) async {
        do {
            let cachedSnapshot = try await hubLoader.loadCachedSnapshot()
            guard generation == contentGeneration, !Task.isCancelled else { return }
            currentSourceName = cachedSnapshot.metadata.currentSourceName
            lastFeedCacheRefreshDate = cachedSnapshot.metadata.cacheFetchedAt
            let cacheIsStale = isCachedFeedStale(cachedSnapshot.metadata)
            isFeedCacheStale = cacheIsStale
            lastNetworkHubFetchTime = cacheIsStale ? nil : cachedSnapshot.metadata.cacheFetchedAt

            if !cachedSnapshot.orderedHubs.isEmpty {
                appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: true)
                let availableHubs = await filterHubsForLocalAvailability(cachedSnapshot.orderedHubs)
                guard generation == contentGeneration, !Task.isCancelled else { return }
                unfilteredHubs = availableHubs
                hubs = Self.filterHubsForVisibility(
                    availableHubs,
                    hiddenSourceCompositeKeys: visibilityStore.hiddenSourceCompositeKeys,
                    sourceConfiguration: accountManager.sourceConfigurationSnapshot,
                    preservesAuthoritativeEmptySourceSnapshot: preservesAuthoritativeEmptySourceSnapshot
                )
                EnsembleStartupTiming.logTTFMP(milestone: "Cached hubs visible (\(hubs.count) hubs)")
            } else {
                appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: false)
                clearHubContentIfUnavailableSourcesAreSettled()
            }
        } catch {
            guard generation == contentGeneration, !Task.isCancelled else { return }
            EnsembleLogger.debug("[HomeViewModel] Failed to load cached hubs: \(error.localizedDescription)")
        }
    }
    
    /// Refresh hubs (clears debounce to force immediate reload)
    /// Uses a rotated count to encourage PMS to pick different dynamic hub content
    /// (e.g. different "More by...", "More in..." selections)
    public func refresh() async {
        lastLoadTime = nil
        refreshCount += 1
        hubLoader.clearFailedHubKeys()
        await loadHubs()
    }

    /// Retries macOS Keychain hydration and resumes Feed loading if sources become available.
    public func retryCredentialLoad() async {
        await accountManager.loadAccountsAsync()
        updateSourceAvailability()
        await loadHubsIfNeeded()
    }

    public func handleViewVisibilityChange(isVisible: Bool) {
        guard isViewVisible != isVisible else { return }
        isViewVisible = isVisible
        EnsembleLogger.debug("🏠 Feed visibility changed visible=\(isVisible)")

        if isVisible {
            startRefreshTriggerObservation()
            startPeriodicRefresh()
            flushDeferredAutoRefreshIfVisible()
        } else {
            stopRefreshTriggerObservation()
            stopPeriodicRefresh()
            pendingAutoRefreshReasons = pendingAutoRefreshReasons.filter { $0 == .accountChange }
        }
    }

    private func requestAutoRefresh(reason: AutoRefreshReason) {
        guard hasEnabledLibraries else {
            clearHubContentIfUnavailableSourcesAreSettled()
            return
        }

        // Suppress auto-refresh until the initial .task load completes.
        // The explicit loadHubs() from HomeView.task IS the startup load.
        guard initialLoadCompleted else {
            retainAccountRefreshIfNeeded(reason)
            EnsembleLogger.debug("🏠 Home auto-refresh deferred reason=\(reason.rawValue) detail=initialLoadInFlight")
            return
        }

        guard !syncCoordinator.isOffline else {
            retainAccountRefreshIfNeeded(reason)
            EnsembleLogger.debug("🏠 Home auto-refresh deferred reason=\(reason.rawValue) detail=offline")
            return
        }

        if reason != .accountChange, !shouldRefreshHubsForAutomaticLoad {
            EnsembleLogger.debug(
                "🏠 Home auto-refresh skipped reason=\(reason.rawValue) detail=fresh"
            )
            return
        }

        if !isViewVisible {
            _ = pendingAutoRefreshReasons.insert(reason)
            EnsembleLogger.debug(
                "🏠 Home auto-refresh deferred reason=\(reason.rawValue), visible=false, pending=\(pendingAutoRefreshReasons.count)"
            )
            return
        }

        // Coalesce immediate refreshes: if a load is already in progress, skip
        guard loadTask == nil else {
            retainAccountRefreshIfNeeded(reason)
            EnsembleLogger.debug("🏠 Home auto-refresh coalesced (load in progress) reason=\(reason.rawValue)")
            return
        }

        EnsembleLogger.debug("🏠 Home auto-refresh scheduled reason=\(reason.rawValue)")
        pendingAutoRefreshReasons.removeAll()

        Task { @MainActor [weak self] in
            await self?.performAutoRefresh(triggeringReason: reason)
        }
    }

    private func performAutoRefresh(triggeringReason reason: AutoRefreshReason) async {
        if let autoRefreshRunnerForTesting {
            await autoRefreshRunnerForTesting(reason)
            return
        }

        EnsembleLogger.debug("🏠 Home auto-refresh executing reason=\(reason.rawValue)")
        lastAutomaticHubRefreshAttemptTime = Date()
        await loadHubs()
    }

    private func flushDeferredAutoRefreshIfVisible() {
        guard isViewVisible, !pendingAutoRefreshReasons.isEmpty else { return }
        let reason: AutoRefreshReason = pendingAutoRefreshReasons.contains(.accountChange)
            ? .accountChange
            : pendingAutoRefreshReasons.first ?? .periodicTimer
        requestAutoRefresh(reason: reason)
    }

    private func retainAccountRefreshIfNeeded(_ reason: AutoRefreshReason) {
        guard reason == .accountChange else { return }
        pendingAutoRefreshReasons.insert(reason)
    }

    private func markInitialLoadCompleted() {
        initialLoadCompleted = true
        flushDeferredAutoRefreshIfVisible()
    }

    private func applyHubSnapshot(
        _ snapshot: [Hub],
        source: String,
        generation: UInt64
    ) async {
        let availableSnapshot = await filterHubsForLocalAvailability(snapshot)
        guard generation == contentGeneration, !Task.isCancelled else { return }
        unfilteredHubs = availableSnapshot
        let visibleSnapshot = Self.filterHubsForVisibility(
            availableSnapshot,
            hiddenSourceCompositeKeys: visibilityStore.hiddenSourceCompositeKeys,
            sourceConfiguration: accountManager.sourceConfigurationSnapshot,
            preservesAuthoritativeEmptySourceSnapshot: preservesAuthoritativeEmptySourceSnapshot
        )

        EnsembleLogger.debug("🏠 Applying hub snapshot source=\(source) count=\(visibleSnapshot.count)")
        hubs = visibleSnapshot
        // Don't overwrite editableHubs — user may be actively reordering
    }

    private func applyVisibilityToPublishedHubs() {
        let visibleHubs = Self.filterHubsForVisibility(
            unfilteredHubs,
            hiddenSourceCompositeKeys: visibilityStore.hiddenSourceCompositeKeys,
            sourceConfiguration: accountManager.sourceConfigurationSnapshot,
            preservesAuthoritativeEmptySourceSnapshot: preservesAuthoritativeEmptySourceSnapshot
        )

        hubs = visibleHubs
        // Don't overwrite editableHubs — user may be actively reordering
    }

    internal var hasPendingAutoRefreshForTesting: Bool {
        !pendingAutoRefreshReasons.isEmpty
    }

    internal func requestAutoRefreshForTesting(reason: AutoRefreshReason) {
        requestAutoRefresh(reason: reason)
    }

    internal func clearPendingAutoRefreshForTesting() {
        pendingAutoRefreshReasons.removeAll()
    }

    /// Mark the initial load as complete so auto-refresh tests can proceed
    internal func markInitialLoadCompletedForTesting() {
        markInitialLoadCompleted()
    }

    internal func seedHubsForTesting(_ hubs: [Hub]) {
        unfilteredHubs = hubs
        self.hubs = hubs
    }

    internal func seedLastNetworkHubFetchTimeForTesting(_ date: Date?) {
        lastNetworkHubFetchTime = date
    }

    private var shouldRefreshHubsForAutomaticLoad: Bool {
        guard !hubs.isEmpty else { return true }
        let lastAutomaticRefresh = [lastNetworkHubFetchTime, lastAutomaticHubRefreshAttemptTime]
            .compactMap { $0 }
            .max()
        guard let lastAutomaticRefresh else { return true }
        return Date().timeIntervalSince(lastAutomaticRefresh) >= hubRefreshInterval
    }

    private func startRefreshTriggerObservation() {
        guard refreshTriggerCancellables.isEmpty else { return }

        // Feed reloads only follow actual library/playlist mutations.
        // Transport, health, and progress churn stays on sourceStatuses.
        syncCoordinator.$lastContentChange
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .filter(\.hasMaterialChanges)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] change in
                EnsembleLogger.debug("🏠 Home auto-refresh content change source=\(change.source.compositeKey)")
                self?.requestAutoRefresh(reason: .contentChange)
            }
            .store(in: &refreshTriggerCancellables)
    }

    private func stopRefreshTriggerObservation() {
        guard !refreshTriggerCancellables.isEmpty else { return }
        refreshTriggerCancellables.removeAll()
    }

    internal static func filterHubsForVisibility(
        _ hubs: [Hub],
        hiddenSourceCompositeKeys: Set<String>,
        sourceConfiguration: SourceConfigurationSnapshot? = nil,
        preservesAuthoritativeEmptySourceSnapshot: Bool = true
    ) -> [Hub] {
        // A fully authoritative empty credential snapshot does not prove that
        // last-good browse data was deleted. Explicit source cleanup owns that.
        let sourceConfiguration = sourceConfiguration.flatMap { configuration in
            configuration.hasAnySources ||
                !configuration.isAuthoritative ||
                !preservesAuthoritativeEmptySourceSnapshot ? configuration : nil
        }
        return hubs.compactMap { hub in
            let visibleItems = hub.items.filter { item in
                MediaSourceIdentity.parse(item.sourceCompositeKey) != nil &&
                    (sourceConfiguration?.shouldPreserveSourceKey(item.sourceCompositeKey) ?? true) &&
                    !hiddenSourceCompositeKeys.contains(item.sourceCompositeKey)
            }

            guard !visibleItems.isEmpty else { return nil }
            return Hub(
                id: hub.id,
                title: hub.title,
                type: hub.type,
                items: visibleItems,
                context: hub.context,
                semanticKind: hub.semanticKind,
                sourceScope: hub.sourceScope
            )
        }
    }

    internal static func filterHubsForLocalAvailability(
        _ hubs: [Hub],
        itemExists: @escaping @Sendable (HubItem) async throws -> Bool
    ) async rethrows -> [Hub] {
        try await filterHubsForLocalAvailability(hubs) { item in
            try await itemExists(item) ? item : nil
        }
    }

    internal static func filterHubsForLocalAvailability(
        _ hubs: [Hub],
        resolvedItem: @escaping @Sendable (HubItem) async throws -> HubItem?
    ) async rethrows -> [Hub] {
        var filteredHubs: [Hub] = []
        filteredHubs.reserveCapacity(hubs.count)

        for hub in hubs {
            var availableItems: [HubItem] = []
            availableItems.reserveCapacity(hub.items.count)

            for item in hub.items {
                if let resolved = try await resolvedItem(item) {
                    availableItems.append(resolved)
                } else if Self.retainsHubItemWithoutLocalCache(item) {
                    availableItems.append(item)
                }
            }

            guard !availableItems.isEmpty else { continue }
            filteredHubs.append(
                Hub(
                    id: hub.id,
                    title: hub.title,
                    type: hub.type,
                    items: availableItems,
                    context: hub.context,
                    semanticKind: hub.semanticKind,
                    sourceScope: hub.sourceScope
                )
            )
        }

        return filteredHubs
    }

    private nonisolated static func retainsHubItemWithoutLocalCache(_ item: HubItem) -> Bool {
        guard let sourceType = MediaSourceIdentity.parse(item.sourceCompositeKey)?.sourceType else {
            return false
        }
        return sourceType.capabilities.retainsHubItemsWithoutLocalCache
    }

    private func filterHubsForLocalAvailability(_ hubs: [Hub]) async -> [Hub] {
        do {
            async let albumsByKeyTask = libraryRepository.fetchAlbums(
                forReferences: Self.sourceScopedReferences(in: hubs, itemType: "album")
            )
            async let artistsByKeyTask = libraryRepository.fetchArtists(
                forReferences: Self.sourceScopedReferences(in: hubs, itemType: "artist")
            )
            async let playlistsByKeyTask = playlistRepository.fetchPlaylistHeaders(
                forReferences: Self.sourceScopedReferences(in: hubs, itemType: "playlist")
            )
            async let tracksByKeyTask = libraryRepository.fetchTracksBatch(
                forReferences: Self.trackReferences(in: hubs)
            )

            let lookup = try await LocalHubItemLookup(
                albumsByKey: albumsByKeyTask.mapValues(Album.init(from:)),
                artistsByKey: artistsByKeyTask.mapValues(Artist.init(from:)),
                playlistsByKey: playlistsByKeyTask.mapValues(Playlist.init(from:)),
                tracksByKey: tracksByKeyTask.mapValues(Track.init(from:))
            )
            let filteredHubs = await Self.filterHubsForLocalAvailability(hubs) { item in
                Self.resolveHubItemFromLocalLibrary(item, lookup: lookup)
            }

            let filteredItemCount = filteredHubs.reduce(into: 0) { $0 += $1.items.count }
            let rawItemCount = hubs.reduce(into: 0) { $0 += $1.items.count }
            if filteredItemCount != rawItemCount {
                EnsembleLogger.debug(
                    "🏠 Feed local availability filtered hiddenItems=\(rawItemCount - filteredItemCount) visibleItems=\(filteredItemCount)"
                )
            }

            return filteredHubs
        } catch {
            EnsembleLogger.debug("🏠 Feed local availability filter failed: \(error.localizedDescription)")
            return []
        }
    }

    private struct LocalHubItemLookup {
        let albumsByKey: [String: Album]
        let artistsByKey: [String: Artist]
        let playlistsByKey: [String: Playlist]
        let tracksByKey: [String: Track]
    }

    private nonisolated static func sourceScopedReferences(
        in hubs: [Hub],
        itemType: String
    ) -> [SourceScopedArtworkReference] {
        Array(Set(hubs.flatMap(\.items).compactMap { item in
            guard item.type == itemType else { return nil }
            return SourceScopedArtworkReference(
                ratingKey: item.id,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }))
    }

    private nonisolated static func trackReferences(in hubs: [Hub]) -> [OfflineTrackReference] {
        Array(Set(hubs.flatMap(\.items).compactMap { item in
            guard item.type == "track" else { return nil }
            return OfflineTrackReference(
                trackRatingKey: item.id,
                trackSourceCompositeKey: item.sourceCompositeKey
            )
        }))
    }

    private nonisolated static func resolveHubItemFromLocalLibrary(
        _ item: HubItem,
        lookup: LocalHubItemLookup
    ) -> HubItem? {
        switch item.type {
        case "album":
            let lookupKey = SourceScopedArtworkReference(
                ratingKey: item.id,
                sourceCompositeKey: item.sourceCompositeKey
            ).lookupKey
            guard let album = lookup.albumsByKey[lookupKey] else { return nil }
            return HubItem(
                id: item.id,
                type: item.type,
                title: album.title,
                subtitle: album.artistName ?? item.subtitle,
                thumbPath: album.thumbPath ?? item.thumbPath,
                year: album.year ?? item.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: album,
                track: item.track,
                artist: item.artist,
                playlist: item.playlist
            )
        case "artist":
            let lookupKey = SourceScopedArtworkReference(
                ratingKey: item.id,
                sourceCompositeKey: item.sourceCompositeKey
            ).lookupKey
            guard let artist = lookup.artistsByKey[lookupKey] else { return nil }
            return HubItem(
                id: item.id,
                type: item.type,
                title: artist.name,
                subtitle: item.subtitle,
                thumbPath: artist.thumbPath ?? artist.fallbackThumbPath ?? item.thumbPath,
                year: item.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: item.album,
                track: item.track,
                artist: artist,
                playlist: item.playlist
            )
        case "playlist":
            let lookupKey = SourceScopedArtworkReference(
                ratingKey: item.id,
                sourceCompositeKey: item.sourceCompositeKey
            ).lookupKey
            guard let playlist = lookup.playlistsByKey[lookupKey] else { return nil }
            return HubItem(
                id: item.id,
                type: item.type,
                title: playlist.title,
                subtitle: item.subtitle,
                thumbPath: playlist.compositePath ?? item.thumbPath,
                year: item.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: item.album,
                track: item.track,
                artist: item.artist,
                playlist: playlist
            )
        case "track":
            let lookupKey = OfflineTrackReference(
                trackRatingKey: item.id,
                trackSourceCompositeKey: item.sourceCompositeKey
            ).membershipID
            guard let track = lookup.tracksByKey[lookupKey] else { return nil }
            return HubItem(
                id: item.id,
                type: item.type,
                title: track.title,
                subtitle: track.artistName ?? item.subtitle,
                thumbPath: track.thumbPath ?? track.fallbackThumbPath ?? item.thumbPath,
                year: item.year,
                sourceCompositeKey: item.sourceCompositeKey,
                album: item.album,
                track: track,
                artist: item.artist,
                playlist: item.playlist
            )
        default:
            return nil
        }
    }

    // MARK: - Edit Mode

    /// Use one ordering scope for the combined Feed shown by the editor.
    private func updateCurrentSource() {
        currentSourceName = "Editing Music"
    }

    private func updateSourceAvailability(
        _ configuration: SourceConfigurationSnapshot? = nil
    ) {
        let configuration = configuration ?? accountManager.sourceConfigurationSnapshot
        hasConfiguredAccounts = configuration.hasAnySources
        hasEnabledLibraries = !configuration.enabledSources.isEmpty
    }

    private func handleSourceConfigurationChange(_ configuration: SourceConfigurationSnapshot) {
        updateSourceAvailability(configuration)
        let configuredSourceKeys = Set(configuration.configuredSources.map(\.compositeKey))
        let removedEnabledSources = lastEnabledSourceKeys.subtracting(configuration.enabledSourceKeys)
        if configuration.hasAnySources {
            preservesAuthoritativeEmptySourceSnapshot = true
        } else if !removedEnabledSources.isEmpty || lastSourceConfigurationHadSources {
            preservesAuthoritativeEmptySourceSnapshot = false
        }
        let changedSourceKeys = lastConfiguredSourceKeys
            .symmetricDifference(configuredSourceKeys)
            .union(lastEnabledSourceKeys.symmetricDifference(configuration.enabledSourceKeys))
        lastConfiguredSourceKeys = configuredSourceKeys
        lastEnabledSourceKeys = configuration.enabledSourceKeys
        lastSourceConfigurationHadSources = configuration.hasAnySources
        applyVisibilityToPublishedHubs()
        let hasAuthoritativeProviderChange = changedSourceKeys.contains { sourceKey in
            guard let sourceType = MediaSourceIdentity.sourceType(from: sourceKey) else {
                return configuration.isAuthoritative
            }
            return configuration.authoritativeSourceTypes.contains(sourceType)
        }
        guard configuration.isAuthoritative || hasAuthoritativeProviderChange else {
            EnsembleLogger.debug("🏠 Home source refresh deferred detail=configurationUnresolved")
            return
        }
        hubLoader.clearFailedHubKeys()
        lastLoadTime = nil
        lastNetworkHubFetchTime = nil
        lastAutomaticHubRefreshAttemptTime = nil
        if !hubs.isEmpty && !isFeedCacheStale {
            isFeedCacheStale = true
        }

        guard hasEnabledLibraries else {
            pendingAutoRefreshReasons.remove(.accountChange)
            clearHubContentIfUnavailableSourcesAreSettled()
            return
        }
        requestAutoRefresh(reason: .accountChange)
    }

    private func clearHubContentForUnavailableSources() {
        contentGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        error = nil
        isFeedCacheStale = false
        lastFeedCacheRefreshDate = nil
        lastNetworkHubFetchTime = nil
        lastAutomaticHubRefreshAttemptTime = nil
        unfilteredHubs = []
        hubs = []
        editableHubs = []
        isEditingOrder = false
    }

    private func handleLibraryDataCleared() {
        cachedSnapshotRestoreTask?.cancel()
        cachedSnapshotRestoreTask = nil
        appReadinessCoordinator?.updateCachedFeedReadiness(hasContent: false)
        currentSourceName = ""
        hubLoader.clearFailedHubKeys()
        clearHubContentForUnavailableSources()
        markInitialLoadCompleted()
    }

    private func handleSourceCleanupCompleted() {
        guard accountManager.hasAnySources else {
            handleLibraryDataCleared()
            return
        }
        applyVisibilityToPublishedHubs()
    }

    private func clearHubContentIfUnavailableSourcesAreSettled() {
        guard accountManager.isSourceConfigurationAuthoritative,
              accountManager.hasAnySources,
              readinessSnapshot.isBootstrapSettled,
              !readinessSnapshot.isRestoringCloudSources else {
            isLoading = false
            markInitialLoadCompleted()
            return
        }
        clearHubContentForUnavailableSources()
    }

    private func isCachedFeedStale(_ metadata: HomeHubSnapshotMetadata) -> Bool {
        if metadata.freshnessState == .stale || metadata.freshnessState == .failed {
            return true
        }

        guard let fetchedAt = metadata.cacheFetchedAt else {
            return !metadata.currentSourceName.isEmpty
        }
        return Date().timeIntervalSince(fetchedAt) > feedCacheStaleInterval
    }
    
    /// Look up the library title for a hub based on its ID.
    /// Hub IDs contain the account, server, and library key: "plex:{acct}:{srv}:{lib}:{hubType}".
    /// Matches on both server ID and library key to avoid cross-server collisions
    /// (different servers can have the same library key for different libraries).
    /// Returns nil for merged hubs or if the library isn't found.
    public func libraryName(forHubId hubId: String) -> String? {
        let components = hubId.split(separator: ":")
        // Merged hubs don't have a library key
        guard components.count >= 5, components[3] != "merged" else { return nil }
        let serverId = String(components[2])
        let libraryKey = String(components[3])

        for account in accountManager.plexAccounts {
            for server in account.servers where server.id == serverId {
                if let library = server.libraries.first(where: { $0.key == libraryKey }) {
                    return library.title
                }
            }
        }
        return nil
    }

    /// Enter edit mode - prepare the hub list for reordering
    public func enterEditMode() {
        updateCurrentSource()
        editableHubs = hubs
    }
    
    /// Exit edit mode - either save the reordered hubs or discard changes
    public func exitEditMode(save: Bool) {
        guard save, !editableHubs.isEmpty else {
            editableHubs = []
            isEditingOrder = false
            return
        }
        
        // Save the new order and apply it to the displayed hubs
        Task {
            await saveHubOrder(editableHubs)
            hubs = editableHubs
            editableHubs = []
            isEditingOrder = false
        }
    }
    
    /// Save the order of the combined Feed.
    private func saveHubOrder(_ orderedHubs: [Hub]) async {
        hubOrderManager.saveOrder(orderedHubs.map(\.id), for: HomeHubLoader.feedOrderKey)
    }
    
    /// Reset the combined Feed to Plex's default order.
    public func resetOrder() {
        updateCurrentSource()
        EnsembleLogger.debug("[HubOrder] Reset requested for sourceKey=\(HomeHubLoader.feedOrderKey)")
        hubOrderManager.resetOrder(for: HomeHubLoader.feedOrderKey)

        // Apply cached default order immediately
        EnsembleLogger.debug("[HubOrder] Applying default order to \(unfilteredHubs.count) Feed hubs")
        let orderedSnapshot = hubOrderManager.applyDefaultOrder(
            to: unfilteredHubs,
            for: HomeHubLoader.feedOrderKey
        )
        let generation = contentGeneration
        Task { @MainActor [weak self] in
            await self?.applyHubSnapshot(
                orderedSnapshot,
                source: "resetOrder",
                generation: generation
            )
        }

        // Clear debounce and reload hubs to show the reset order
        lastLoadTime = nil
        
        // Reload hubs to get fresh data from server
        EnsembleLogger.debug("[HubOrder] Triggering background refresh from server")
        Task {
            await loadHubs(applySavedOrder: false)
            if isEditingOrder {
                editableHubs = hubs
            }
        }
    }
    
    // MARK: - Periodic Refresh
    
    /// Start periodic hub refresh (every 10 minutes while app is active)
    public func startPeriodicRefresh() {
        guard isViewVisible else { return }
        guard hubRefreshTimer == nil else { return }
        
        EnsembleLogger.debug("⏰ Starting periodic hub refresh (every 10 minutes)")
        hubRefreshTimer = Timer.scheduledTimer(withTimeInterval: hubRefreshInterval, repeats: true) { [weak self] _ in
            // No [weak self] here — the outer Timer closure already captures self weakly
            Task { @MainActor in
                guard let self = self else { return }
                
                // Don't refresh if offline
                guard !self.syncCoordinator.isOffline else {
                    EnsembleLogger.debug("📴 Offline - skipping periodic hub refresh")
                    return
                }

                guard self.isViewVisible else { return }
                
                EnsembleLogger.debug("⏰ Periodic hub refresh triggered")
                self.requestAutoRefresh(reason: .periodicTimer)
            }
        }
    }
    
    /// Stop periodic hub refresh
    public func stopPeriodicRefresh() {
        guard hubRefreshTimer != nil else { return }
        hubRefreshTimer?.invalidate()
        hubRefreshTimer = nil
        EnsembleLogger.debug("🛑 Stopped periodic hub refresh")
    }
}
