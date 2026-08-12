import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

/// The user-visible result of syncing one configured music source.
public enum MusicSourceSyncOutcome: Sendable, Equatable {
    case success
    case failure(message: String)
}

public struct PlaylistMutationResult: Sendable {
    public let addedCount: Int
    public let skippedCount: Int

    public init(addedCount: Int, skippedCount: Int) {
        self.addedCount = addedCount
        self.skippedCount = skippedCount
    }
}

public struct SyncContentChange: Sendable, Equatable {
    public let source: MusicSourceIdentifier
    public let libraryResult: LibrarySyncResult?
    public let playlistResult: PlaylistSyncResult?
    public let syncedAt: Date

    public init(
        source: MusicSourceIdentifier,
        libraryResult: LibrarySyncResult? = nil,
        playlistResult: PlaylistSyncResult? = nil,
        syncedAt: Date
    ) {
        self.source = source
        self.libraryResult = libraryResult
        self.playlistResult = playlistResult
        self.syncedAt = syncedAt
    }

    public var affectsLibraryBrowse: Bool {
        libraryResult?.hasMaterialChanges == true
    }

    public var affectsPlaylists: Bool {
        playlistResult?.hasMaterialChanges == true
    }

    public var hasMaterialChanges: Bool {
        affectsLibraryBrowse || affectsPlaylists
    }
}

public enum PlaylistMutationError: LocalizedError, Equatable {
    case invalidSource
    case playlistNotFound
    case smartPlaylistReadOnly
    case emptySelection
    case duplicateName
    case incompletePlaylistContents

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Could not determine a valid music source for this action."
        case .playlistNotFound:
            return "Playlist not found."
        case .smartPlaylistReadOnly:
            return "Smart playlists are read-only."
        case .emptySelection:
            return "No compatible tracks were selected."
        case .duplicateName:
            return "A playlist with that name already exists in this source."
        case .incompletePlaylistContents:
            return "This playlist contains tracks from disabled libraries. Re-enable them before editing the playlist."
        }
    }
}

/// Coordinates syncing across all configured music sources
@MainActor
public final class SyncCoordinator: ObservableObject {
    public static let sourceCleanupDidComplete = Notification.Name("SyncCoordinatorSourceCleanupDidComplete")
    private struct ActiveSourceSync {
        let id: UUID
        let task: Task<MusicSourceSyncOutcome, Never>
    }

    private struct ActiveSourceLibraryAdd {
        let id: UUID
        let task: Task<MusicSourceLibraryAddOutcome, Error>
    }

    private struct ActiveSourcePersistenceWork {
        let registration: ConfiguredSourceProvider
        let lease: SourcePersistenceLease
    }

    private struct SourcePersistenceOperation {
        let work: [ActiveSourcePersistenceWork]

        var providers: [String: MusicSourceSyncProvider] {
            Dictionary(uniqueKeysWithValues: work.map {
                ($0.registration.provider.sourceIdentifier.compositeKey, $0.registration.provider)
            })
        }
    }

    /// Posted after server playlists are refreshed (e.g. after a mutation).
    /// The notification's `userInfo` contains `["serverSourceKey": String]`.
    public static let playlistsDidRefresh = Notification.Name("SyncCoordinatorPlaylistsDidRefresh")

    @Published public private(set) var sourceStatuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
    @Published public private(set) var isSyncing = false
    @Published public private(set) var isOffline = false
    @Published public private(set) var lastPlaylistTarget: LastPlaylistTarget?
    /// Published when health checks complete so dependent services can react.
    @Published public private(set) var lastHealthCheckCompletion: Date?
    /// Narrow sync output for consumers that care about actual data changes, not transport churn.
    @Published public private(set) var lastContentChange: SyncContentChange?
    /// Published after the launch-triggered sync finishes so browse surfaces can do a one-shot refresh.
    @Published public private(set) var lastStartupSyncCompletion: Date?

    public let accountManager: AccountManager
    public let networkMonitor: NetworkMonitor
    public let serverHealthChecker: ServerHealthChecker
    public let connectionRegistry: ServerConnectionRegistry?
    private let libraryRepository: LibraryRepositoryProtocol
    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCursorRepository: SyncCursorRepositoryProtocol?
    private let artworkDownloadManager: ArtworkDownloadManagerProtocol
    private let refreshOrchestrator: RefreshOrchestrator
    private let serverConnectionController: ServerConnectionController
    private let periodicSyncController: PeriodicSyncController
    private let playlistRefreshController: PlaylistRefreshController
    private let webSocketSyncController: WebSocketSyncController
    private let playbackReportingController: SyncPlaybackReportingController
    private let networkLifecycleController: NetworkLifecycleController
    private var syncProviders: [String: MusicSourceSyncProvider] = [:]  // keyed by compositeKey
    private var syncProviderRevisions: [String: SourceProviderRevision] = [:]
    private var providerRegistrationRevision: UInt64 = 0
    private var enforcesSourceConfigurationForProviders = true
    private let sourcePersistenceFence = SourcePersistenceFence()
    private var activeSourceSyncs: [String: ActiveSourceSync] = [:]
    private var activeSourceLibraryAdds: [String: ActiveSourceLibraryAdd] = [:]
    private var providerResolver: SyncProviderResolver {
        SyncProviderResolver(providers: syncProviders)
    }
    private var cancellables = Set<AnyCancellable>()
    private var isCheckingHealth = false
    private var isDownloadedPlaylistSyncing = false
    private var enabledServerKeysSnapshot = Set<String>()
    /// Timestamp of last sourceStatuses progress update per source — used to throttle
    /// @Published updates during sync so SwiftUI doesn't re-render on every item.
    private var lastProgressUpdateTime: [MusicSourceIdentifier: CFAbsoluteTime] = [:]
    private let progressThrottleInterval: CFAbsoluteTime = 0.2  // 200ms
    private static let lastPlaylistIdKey = "NowPlaying.LastPlaylist.ID"
    private static let lastPlaylistTitleKey = "NowPlaying.LastPlaylist.Title"
    private static let lastPlaylistSourceKey = "NowPlaying.LastPlaylist.SourceKey"
    private static let lastPlaylistTargetsByServerKey = "NowPlaying.LastPlaylist.ByServer"
    private var lastPlaylistTargetsByServer: [String: LastPlaylistTarget]
    internal var refreshServerPlaylistsHandlerForTesting: ((String) async -> Void)?
    internal var nowProviderForTesting: () -> Date = { Date() }
    /// Backoff for repeated playlist artwork failures to avoid retrying the same bad payload every sync.
    private var playlistArtworkRetryAfter: [String: Date] = [:]
    private let playlistArtworkFailureBackoff: TimeInterval = 5 * 60
    internal static let fullSizeArtworkCacheDimension = ArtworkSize.detail.rawValue

    /// Closure called when API client connections are refreshed (e.g., after network change).
    /// Used by ArtworkLoader to invalidate stale URL cache entries.
    public var onConnectionsRefreshed: (() async -> Void)? {
        didSet {
            serverConnectionController.onConnectionsRefreshed = onConnectionsRefreshed
        }
    }
    /// Signal fired when a server-level playlist refresh completes.
    public var onPlaylistRefreshCompleted: ((String) -> Void)?
    /// Supplies Plex servers that currently own at least one downloaded playlist.
    public var downloadedPlaylistServerSourceKeys: (() -> Set<String>)?
    /// Signal fired after a rating change so the favorites download target can reconcile.
    public var onFavoritesRatingChanged: (() async -> Void)?
    /// Optional load-aware gate for foreground health refreshes. DependencyContainer
    /// wires this to the download/playback stack so nonessential probes can defer
    /// while the app is actively protecting playback.
    public var shouldDeferForegroundHealthRefresh: (() -> Bool)?

    /// Called after sync when tracks have been reparented (album changed).
    /// Used by ArtworkLoader to invalidate stale artwork for affected albums.
    public var onTrackAlbumChanged: (([TrackReparentInfo]) async -> Void)?
    /// Called after sync when album or artist artwork metadata changed.
    public var onArtworkMetadataChanged: (([ArtworkInvalidationInfo]) async -> Void)?

    /// Worker that owns source-specific cache and file cleanup outside the coordinator's UI-facing actor.
    public var sourceCacheCleanupService: SourceCacheCleaning?
    internal var healthCheckRunnerForTesting: ((Bool, Set<String>) async -> ServerHealthChecker.CheckSummary)?
    internal var refreshAPIClientConnectionsRunnerForTesting: (() async -> Void)?
    internal var sourceLibraryAddHandlerForTesting: ((String) async throws -> MusicSourceLibraryAddOutcome)?
    internal var sourceLibraryAddDidCoalesceForTesting: (() -> Void)?

    internal func setSyncProvidersForTesting(
        _ providers: [String: MusicSourceSyncProvider],
        enforceSourceConfiguration: Bool = false
    ) {
        syncProviders = providers
        registerCurrentProviders(
            enforceSourceConfiguration: enforceSourceConfiguration,
            preserveUnchangedRevisions: false
        )
    }

    internal var configuredSourceProviders: [MusicSourceSyncProvider] {
        syncProviders.values.sorted {
            $0.sourceIdentifier.compositeKey < $1.sourceIdentifier.compositeKey
        }
    }

    internal var configuredSourceProviderRegistrations: [ConfiguredSourceProvider] {
        configuredSourceProviders.compactMap { provider in
            guard let revision = syncProviderRevisions[provider.sourceIdentifier.compositeKey] else {
                return nil
            }
            return ConfiguredSourceProvider(provider: provider, revision: revision)
        }
    }

    public init(
        accountManager: AccountManager,
        libraryRepository: LibraryRepositoryProtocol,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCursorRepository: SyncCursorRepositoryProtocol? = nil,
        artworkDownloadManager: ArtworkDownloadManagerProtocol,
        networkMonitor: NetworkMonitor,
        serverHealthChecker: ServerHealthChecker,
        connectionRegistry: ServerConnectionRegistry? = nil
    ) {
        self.accountManager = accountManager
        self.libraryRepository = libraryRepository
        self.playlistRepository = playlistRepository
        self.syncCursorRepository = syncCursorRepository
        self.artworkDownloadManager = artworkDownloadManager
        self.networkMonitor = networkMonitor
        self.serverHealthChecker = serverHealthChecker
        self.connectionRegistry = connectionRegistry
        self.refreshOrchestrator = RefreshOrchestrator()
        self.periodicSyncController = PeriodicSyncController()
        self.playlistRefreshController = PlaylistRefreshController()
        self.webSocketSyncController = WebSocketSyncController()
        self.playbackReportingController = SyncPlaybackReportingController()
        self.networkLifecycleController = NetworkLifecycleController(initialNetworkState: networkMonitor.networkState)
        self.serverConnectionController = ServerConnectionController(
            accountManager: accountManager,
            serverHealthChecker: serverHealthChecker,
            connectionRegistry: connectionRegistry
        )
        self.lastPlaylistTargetsByServer = Self.loadLastPlaylistTargetsByServer()
        self.lastPlaylistTarget = Self.loadLastPlaylistTarget()

        // Observe network state changes
        setupNetworkMonitoring()
        enabledServerKeysSnapshot = enabledServerKeysForHealthChecks()
        setupSourceConfigurationMonitoring()

        serverConnectionController.start()
    }

    /// Rebuild sync providers from current account configuration
    public func refreshProviders() {
        syncProviders.removeAll()

        #if os(iOS)
        if accountManager.isAppleMusicEnabled {
            if #available(iOS 18, *) {
                let provider = AppleMusicSourceProvider()
                syncProviders[MusicSourceIdentifier.appleMusic.compositeKey] = provider
                if sourceStatuses[.appleMusic] == nil {
                    sourceStatuses[.appleMusic] = MusicSourceStatus(connectionState: .connected(url: "music://local"))
                }
            }
        } else {
            sourceStatuses.removeValue(forKey: .appleMusic)
        }
        #endif

        for account in accountManager.plexAccounts {
            for server in account.servers {
                guard let apiClient = accountManager.makeAPIClient(accountId: account.id, serverId: server.id) else {
                    continue
                }

                for library in server.libraries where library.isEnabled {
                    let sourceId = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    )

                    let provider = PlexMusicSourceSyncProvider(
                        sourceIdentifier: sourceId,
                        apiClient: apiClient,
                        sectionKey: library.key,
                        enabledSectionKeys: server.libraries.filter(\.isEnabled).map(\.key),
                        syncCursorRepository: syncCursorRepository
                    )

                    syncProviders[sourceId.compositeKey] = provider

                    // Initialize status with last sync timestamp if available
                    if sourceStatuses[sourceId] == nil {
                        Task {
                            let syncStatus: MusicSourceStatus.SyncStatus
                            if let lastSyncDate = await loadLastSyncDate(for: sourceId) {
                                syncStatus = .lastSynced(lastSyncDate)
                            } else {
                                syncStatus = .idle
                            }
                            sourceStatuses[sourceId] = MusicSourceStatus(
                                syncStatus: syncStatus,
                                connectionState: .unknown
                            )
                        }
                    }
                }
            }
        }
        registerCurrentProviders(
            enforceSourceConfiguration: true,
            preserveUnchangedRevisions: true
        )
    }

    private func registerCurrentProviders(
        enforceSourceConfiguration: Bool,
        preserveUnchangedRevisions: Bool
    ) {
        let previousRevisions = syncProviderRevisions
        enforcesSourceConfigurationForProviders = enforceSourceConfiguration
        syncProviderRevisions = Dictionary(uniqueKeysWithValues: syncProviders.keys.sorted().map { sourceKey in
            let sourceConfigurationRevision = accountManager.sourceConfigurationRevision(forSourceKey: sourceKey)
            if preserveUnchangedRevisions,
               let previousRevision = previousRevisions[sourceKey],
               previousRevision.sourceConfiguration == sourceConfigurationRevision {
                return (sourceKey, previousRevision)
            }
            providerRegistrationRevision &+= 1
            return (
                sourceKey,
                SourceProviderRevision(
                    sourceConfiguration: sourceConfigurationRevision,
                    providerRegistration: providerRegistrationRevision
                )
            )
        })
    }

    private func isCurrentProviderRevision(
        _ revision: SourceProviderRevision,
        sourceKey: String
    ) -> Bool {
        guard syncProviderRevisions[sourceKey] == revision else { return false }
        guard enforcesSourceConfigurationForProviders else { return true }
        let sourceConfiguration = accountManager.sourceConfigurationSnapshot
        return sourceConfiguration.shouldPreserveSourceKey(sourceKey)
            && accountManager.sourceConfigurationRevision(forSourceKey: sourceKey) == revision.sourceConfiguration
    }

    internal func beginSourcePersistenceWork(
        sourceKey: String,
        revision: SourceProviderRevision
    ) -> SourcePersistenceLease? {
        guard isCurrentProviderRevision(revision, sourceKey: sourceKey) else { return nil }
        return sourcePersistenceFence.begin(sourceKey: sourceKey)
    }

    internal func isSourcePersistenceWorkCurrent(
        sourceKey: String,
        revision: SourceProviderRevision,
        lease: SourcePersistenceLease
    ) -> Bool {
        isCurrentProviderRevision(revision, sourceKey: sourceKey)
            && sourcePersistenceFence.isCurrent(lease)
    }

    internal func finishSourcePersistenceWork(_ lease: SourcePersistenceLease) {
        sourcePersistenceFence.finish(lease)
    }

    /// Joins non-sync persistence work to the current provider registration so
    /// explicit source cleanup waits for it before performing the final purge.
    internal func beginCurrentSourcePersistenceWork(
        sourceKey: String
    ) -> SourcePersistenceWorkHandle? {
        beginCurrentSourcePersistenceWork(sourceKeys: [sourceKey])
    }

    /// Joins one write to every source it references. Library keys require an
    /// exact current provider; only genuinely server-scoped providers may span
    /// their enabled libraries.
    internal func beginCurrentSourcePersistenceWork(
        sourceKeys: Set<String>
    ) -> SourcePersistenceWorkHandle? {
        guard !sourceKeys.isEmpty else { return nil }
        let registrations = configuredSourceProviderRegistrations
        var requiredRegistrations: [String: ConfiguredSourceProvider] = [:]
        var serverSourceKeys = Set<String>()

        for sourceKey in sourceKeys {
            guard let identity = MediaSourceIdentity.parse(sourceKey) else { return nil }
            if !identity.isServerScoped {
                guard let exactRegistration = registrations.first(where: {
                    $0.provider.sourceIdentifier.compositeKey == sourceKey
                }) else {
                    return nil
                }
                requiredRegistrations[sourceKey] = exactRegistration
                continue
            }

            guard identity.sourceType.capabilities.playlistsAreServerScoped else { return nil }
            let matchingRegistrations = registrations.filter {
                MediaSourceIdentity.isSameServer(
                    $0.provider.sourceIdentifier.compositeKey,
                    sourceKey
                )
            }
            guard !matchingRegistrations.isEmpty else { return nil }
            for registration in matchingRegistrations {
                requiredRegistrations[registration.provider.sourceIdentifier.compositeKey] = registration
            }
            serverSourceKeys.insert(sourceKey)
        }

        guard let operation = beginSourcePersistenceOperation(
            registrations: Array(requiredRegistrations.values)
        ) else {
            return nil
        }
        var leases = operation.work.map(\.lease)

        for sourceKey in serverSourceKeys.sorted() {
            guard let serverLease = sourcePersistenceFence.begin(sourceKey: sourceKey) else {
                leases.forEach(finishSourcePersistenceWork)
                return nil
            }
            leases.append(serverLease)
        }
        return SourcePersistenceWorkHandle(leases: leases)
    }

    internal func finishSourcePersistenceWork(_ handle: SourcePersistenceWorkHandle) {
        handle.leases.forEach(finishSourcePersistenceWork)
    }

    internal func isSourcePersistenceWorkCurrent(_ handle: SourcePersistenceWorkHandle) -> Bool {
        handle.leases.allSatisfy(sourcePersistenceFence.isCurrent)
    }

    private func beginSourcePersistenceOperation(
        sourceKey: String
    ) -> SourcePersistenceOperation? {
        let registrations = configuredSourceProviderRegistrations
        let exactMatches = registrations.filter {
            $0.provider.sourceIdentifier.compositeKey == sourceKey
        }
        let candidates: [ConfiguredSourceProvider]
        if !exactMatches.isEmpty {
            candidates = exactMatches
        } else {
            candidates = registrations.filter {
                MediaSourceIdentity.isSameServer(
                    $0.provider.sourceIdentifier.compositeKey,
                    sourceKey
                )
            }
        }
        return beginSourcePersistenceOperation(registrations: candidates)
    }

    private func beginSourcePersistenceOperation(
        registrations: [ConfiguredSourceProvider]
    ) -> SourcePersistenceOperation? {
        guard !registrations.isEmpty else { return nil }
        var activeWork: [ActiveSourcePersistenceWork] = []
        for registration in registrations {
            let sourceKey = registration.provider.sourceIdentifier.compositeKey
            guard let lease = beginSourcePersistenceWork(
                sourceKey: sourceKey,
                revision: registration.revision
            ) else {
                activeWork.forEach { finishSourcePersistenceWork($0.lease) }
                return nil
            }
            activeWork.append(ActiveSourcePersistenceWork(registration: registration, lease: lease))
        }
        return SourcePersistenceOperation(work: activeWork)
    }

    private func isSourcePersistenceOperationCurrent(_ operation: SourcePersistenceOperation) -> Bool {
        operation.work.allSatisfy { work in
            let sourceKey = work.registration.provider.sourceIdentifier.compositeKey
            return isSourcePersistenceWorkCurrent(
                sourceKey: sourceKey,
                revision: work.registration.revision,
                lease: work.lease
            )
        }
    }

    private func finishSourcePersistenceOperation(_ operation: SourcePersistenceOperation) {
        operation.work.forEach { finishSourcePersistenceWork($0.lease) }
    }

    /// Load the last sync date from CoreData
    private func loadLastSyncDate(for sourceId: MusicSourceIdentifier) async -> Date? {
        // Fetch from CoreData
        do {
            let sources = try await libraryRepository.fetchMusicSources()
            return sources.first(where: { $0.compositeKey == sourceId.compositeKey })?.lastSyncedAt
        } catch {
            return nil
        }
    }

    /// Sync all enabled sources
    public func syncAll() async {
        await syncExecutionController().syncAll(providers: syncProviders)
    }

    /// Sync a single source and report whether every required phase completed.
    @discardableResult
    public func sync(source: MusicSourceIdentifier) async -> MusicSourceSyncOutcome {
        await syncExecutionController().sync(source: source, providers: syncProviders)
    }

    private func runSourceSyncSingleFlight(
        source: MusicSourceIdentifier,
        operation: @escaping @MainActor () async -> MusicSourceSyncOutcome
    ) async -> MusicSourceSyncOutcome {
        let sourceKey = source.compositeKey
        if let activeSync = activeSourceSyncs[sourceKey] {
            return await activeSync.task.value
        }

        let id = UUID()
        let task = Task { @MainActor in
            guard !Task.isCancelled else {
                return MusicSourceSyncOutcome.failure(message: "Sync was cancelled.")
            }
            return await operation()
        }
        activeSourceSyncs[sourceKey] = ActiveSourceSync(id: id, task: task)

        let outcome = await task.value
        if activeSourceSyncs[sourceKey]?.id == id {
            if case .failure(let message) = outcome,
               let status = sourceStatuses[source],
               case .syncing = status.syncStatus,
               accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(sourceKey) {
                sourceStatuses[source] = MusicSourceStatus(
                    syncStatus: .error(message),
                    connectionState: effectiveConnectionState(for: status.connectionState)
                )
            }
            activeSourceSyncs.removeValue(forKey: sourceKey)
        }
        return outcome
    }

    private func cancelSourceSync(_ source: MusicSourceIdentifier) async {
        let sourceKey = source.compositeKey
        guard let activeSync = activeSourceSyncs[sourceKey] else { return }
        activeSync.task.cancel()
        _ = await activeSync.task.value
        if activeSourceSyncs[sourceKey]?.id == activeSync.id {
            activeSourceSyncs.removeValue(forKey: sourceKey)
        }
    }

    private func publishSourceSyncPreflightFailure(
        source: MusicSourceIdentifier,
        message: String
    ) {
        guard accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(source.compositeKey) else {
            return
        }
        let connectionState = sourceStatuses[source]?.connectionState ?? .unknown
        sourceStatuses[source] = MusicSourceStatus(
            syncStatus: .error(message),
            connectionState: effectiveConnectionState(for: connectionState)
        )
    }

    /// Sync a scoped set of sources while publishing one global sync lifecycle.
    public func sync(sources: [MusicSourceIdentifier]) async {
        await syncExecutionController().sync(sources: sources, providers: syncProviders)
    }

    private func syncErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.caseInsensitiveCompare("unknown") != .orderedSame else {
            return "Sync failed. Please try again."
        }
        return message
    }

    private func effectiveConnectionState(for fallback: ServerConnectionState) -> ServerConnectionState {
        isOffline ? .offline : fallback
    }

    private func restoreStatusAfterCancellation(
        for source: MusicSourceIdentifier,
        previousStatus: MusicSourceStatus?,
        fallbackConnectionState: ServerConnectionState
    ) {
        let restoredStatus = previousStatus?.syncStatus ?? .idle
        sourceStatuses[source] = MusicSourceStatus(
            syncStatus: restoredStatus,
            connectionState: effectiveConnectionState(for: fallbackConnectionState)
        )
        EnsembleLogger.debug("⏹️ SyncCoordinator: Cancelled sync for \(source.compositeKey) without surfacing an error")
    }

    private func publishContentChangeIfNeeded(
        for source: MusicSourceIdentifier,
        libraryResult: LibrarySyncResult? = nil,
        playlistResult: PlaylistSyncResult? = nil,
        syncedAt: Date
    ) {
        let contentChange = SyncContentChange(
            source: source,
            libraryResult: libraryResult,
            playlistResult: playlistResult,
            syncedAt: syncedAt
        )
        guard contentChange.hasMaterialChanges else { return }
        lastContentChange = contentChange
    }

    /// Throttles sourceStatuses progress updates to avoid flooding SwiftUI with per-item
    /// @Published changes during sync. Always publishes near-completion updates (≥99%).
    private func throttledProgressUpdate(for sourceId: MusicSourceIdentifier, mappedProgress: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let lastUpdate = lastProgressUpdateTime[sourceId] ?? 0

        // Always publish near-completion; otherwise respect throttle interval
        guard mappedProgress >= 0.99 || (now - lastUpdate) >= progressThrottleInterval else { return }
        lastProgressUpdateTime[sourceId] = now

        let connState = sourceStatuses[sourceId]?.connectionState ?? .unknown
        sourceStatuses[sourceId] = MusicSourceStatus(
            syncStatus: .syncing(progress: mappedProgress),
            connectionState: connState
        )
    }
    
    /// Sync all enabled sources incrementally (only fetch changes since last sync)
    public func syncAllIncremental(reconcileMissedPlexEvents: Bool = false) async {
        if reconcileMissedPlexEvents {
            await invalidatePlexReconciliationCursors()
        }
        await syncExecutionController().syncAllIncremental(providers: syncProviders)
    }
    
    /// Sync a single source incrementally (only fetch changes since last sync)
    public func syncIncremental(source: MusicSourceIdentifier) async {
        await syncExecutionController().syncIncremental(source: source, providers: syncProviders)
    }

    /// Sync only playlists incrementally (fast, no library sync)
    public func syncPlaylistsOnly() async {
        guard !isSyncing else { return }
        guard let persistenceOperation = beginSourcePersistenceOperation(
            registrations: configuredSourceProviderRegistrations
        ) else { return }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        isSyncing = true
        defer { isSyncing = false }

        let results = await playlistRefreshController.refreshAllServers(
            providers: persistenceOperation.providers,
            playlistRepository: playlistRepository,
            trigger: .playlistOnly,
            allowFullFallback: false
        )

        for result in results {
            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        }
    }

    // MARK: - Playlist Mutations

    /// Fetch playlists from local cache, optionally scoped to a specific server-level source key.
    public func fetchPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        let playlists = try await playlistRepository.fetchPlaylists(sourceCompositeKey: sourceKey)
        return playlists.map { Playlist(from: $0) }
    }

    private func playlistMutationController(
        persistenceOperation: SourcePersistenceOperation,
        baseProvider: MusicSourceSyncProvider
    ) -> PlaylistMutationController {
        PlaylistMutationController(
            dependencies: .init(
                fetchPlaylists: { [weak self] sourceKey in
                    guard let self else { return [] }
                    return try await self.fetchPlaylists(forServerSourceKey: sourceKey)
                },
                persistCreatedPlaylist: { [weak self] playlist, tracks in
                    guard let self else { return }
                    try await self.persistCreatedPlaylist(playlist, tracks: tracks)
                },
                persistOptimisticAdd: { [weak self] tracks, playlist in
                    guard let self else { return playlist.trackCount + tracks.count }
                    return try await self.persistOptimisticPlaylistAdd(tracks, playlist: playlist)
                },
                reconcileAcceptedAdd: { [weak self] mutator, playlist, tracks, minimumTrackCount in
                    guard let self, let sourceKey = playlist.sourceCompositeKey else { return }
                    guard let registration = persistenceOperation.work.first(where: {
                        $0.registration.provider.sourceIdentifier == baseProvider.sourceIdentifier
                    })?.registration else { return }

                    if let reconciler = mutator as? MusicSourcePlaylistReconciling {
                        Task { [weak self] in
                            await self?.reconcileProviderPlaylist(
                                reconciler,
                                providerSourceKey: baseProvider.sourceIdentifier.compositeKey,
                                sourceKey: sourceKey,
                                playlistID: playlist.id,
                                minimumTrackCount: minimumTrackCount,
                                requiredTracks: tracks,
                                expectedRevision: registration.revision
                            )
                        }
                    } else {
                        Task { [weak self] in
                            await self?.refreshPlaylistsAfterMutation(
                                sourceKey: sourceKey,
                                requiredTracks: tracks
                            )
                        }
                    }
                },
                persistLastPlaylistTarget: { [weak self] playlist in
                    self?.persistLastPlaylistTarget(from: playlist)
                },
                clearLastPlaylistTargetIfNeeded: { [weak self] playlist in
                    self?.clearLastPlaylistTargetIfNeeded(deletedPlaylist: playlist)
                },
                deletePlaylistArtwork: { [weak self] ratingKey, sourceCompositeKey in
                    self?.artworkDownloadManager.deleteArtwork(
                        ratingKey: ratingKey,
                        type: .playlist,
                        sourceCompositeKey: sourceCompositeKey
                    )
                },
                refreshPlaylists: { [weak self] sourceKey in
                    guard let self else { return }
                    if let refreshServerPlaylistsHandlerForTesting {
                        await refreshServerPlaylistsHandlerForTesting(sourceKey)
                    } else {
                        await self.refreshProviderPlaylists(
                            baseProvider,
                            sourceKey: sourceKey,
                            persistenceOperation: persistenceOperation
                        )
                    }
                },
                refreshPlaylistsAfterMutation: { [weak self] sourceKey, requiredTracks in
                    guard let self else { return }
                    if let refreshServerPlaylistsHandlerForTesting {
                        await refreshServerPlaylistsHandlerForTesting(sourceKey)
                    } else {
                        await self.refreshPlaylistsAfterMutation(
                            sourceKey: sourceKey,
                            requiredTracks: requiredTracks
                        )
                    }
                }
            )
        )
    }

    private func playlistMutationProvider(
        for sourceKey: String
    ) throws -> (provider: MusicSourceSyncProvider, capability: MusicSourcePlaylistMutating) {
        try providerResolver.requireCapabilityMatchingSourceScope(
            sourceKey: sourceKey,
            name: "playlist mutations",
            as: MusicSourcePlaylistMutating.self
        )
    }

    private func beginPlaylistMutationPersistenceWork(
        sourceKey: String,
        tracks: [Track]
    ) -> SourcePersistenceWorkHandle? {
        guard let sourceKeys = playlistMutationSourceKeys(sourceKey: sourceKey, tracks: tracks) else {
            return nil
        }
        return beginCurrentSourcePersistenceWork(sourceKeys: sourceKeys)
    }

    private func playlistMutationSourceKeys(
        sourceKey: String,
        tracks: [Track]
    ) -> Set<String>? {
        let compatibleTracks = PlaylistActionService().tracks(
            tracks,
            compatibleWithServerSourceKey: sourceKey
        )
        var sourceKeys: Set<String> = [sourceKey]
        for track in compatibleTracks {
            guard let trackSourceKey = track.sourceCompositeKey,
                  MusicSourceIdentifier(compositeKey: trackSourceKey) != nil else {
                return nil
            }
            sourceKeys.insert(trackSourceKey)
        }
        return sourceKeys
    }

    /// Create a new playlist and schedule provider-owned cache reconciliation.
    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        guard let inputPersistenceWork = beginPlaylistMutationPersistenceWork(
            sourceKey: serverSourceKey,
            tracks: tracks
        ) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceWork(inputPersistenceWork) }
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: serverSourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: serverSourceKey)
        let result = try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).createPlaylist(
            title: title,
            tracks: tracks,
            sourceKey: serverSourceKey,
            provider: provider.capability
        )
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
        return result
    }

    /// Add tracks to an existing playlist and reconcile its provider-owned cache.
    public func addTracksToPlaylist(_ tracks: [Track], playlist: Playlist) async throws -> PlaylistMutationResult {
        guard playlist.supportsPlaylistTrackAdds else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey,
              let inputPersistenceWork = beginPlaylistMutationPersistenceWork(
                  sourceKey: sourceKey,
                  tracks: tracks
              ) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceWork(inputPersistenceWork) }
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: sourceKey)
        let result = try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).addTracksToPlaylist(tracks, playlist: playlist, provider: provider.capability)
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
        return result
    }

    /// Rename a playlist and refresh server playlists.
    public func renamePlaylist(_ playlist: Playlist, to newTitle: String) async throws {
        guard playlist.supportsPlaylistEditing else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey,
              let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: sourceKey)
        try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).renamePlaylist(playlist, to: newTitle, provider: provider.capability)
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
    }

    /// Delete a playlist and refresh server playlists.
    public func deletePlaylist(_ playlist: Playlist) async throws {
        guard playlist.supportsPlaylistDeletion else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey,
              let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: sourceKey)
        try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).deletePlaylist(playlist, provider: provider.capability)
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
    }

    internal func persistCreatedPlaylist(
        _ playlist: Playlist,
        tracks: [Track]
    ) async throws {
        guard let sourceKey = playlist.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey) != nil else {
            throw PlaylistMutationError.invalidSource
        }
        let snapshots = tracks.compactMap {
            Self.playlistTrackSnapshot($0, playlistItemID: nil)
        }
        _ = try await playlistRepository.upsertPlaylist(
            PlaylistUpsertInput(
                ratingKey: playlist.id,
                key: playlist.key,
                title: playlist.title,
                summary: playlist.summary,
                compositePath: playlist.compositePath,
                isSmart: playlist.isSmart,
                duration: Int(playlist.duration * 1_000),
                trackCount: snapshots.count,
                dateAdded: playlist.dateAdded,
                dateModified: playlist.dateModified,
                lastPlayed: playlist.lastPlayed,
                actionCapabilities: playlist.actionCapabilities
            ),
            sourceCompositeKey: sourceKey
        )
        try await playlistRepository.setPlaylistTrackSnapshots(
            snapshots,
            forPlaylist: playlist.id,
            sourceCompositeKey: sourceKey
        )
        notifyPlaylistRefreshCompleted(serverSourceKey: sourceKey)
    }

    @discardableResult
    internal func persistOptimisticPlaylistAdd(
        _ tracks: [Track],
        playlist: Playlist
    ) async throws -> Int {
        guard let sourceKey = playlist.sourceCompositeKey else {
            throw PlaylistMutationError.invalidSource
        }
        guard let cachedPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: playlist.id,
            sourceCompositeKey: sourceKey
        ) else {
            return playlist.trackCount + tracks.count
        }

        let existingItems = cachedPlaylist.playlistItemsArray.map(PlaylistItem.init(from:))
        let newTracks = PlaylistActionService().tracks(
            tracks,
            excluding: existingItems.map(\.track)
        )
        guard !newTracks.isEmpty else { return existingItems.count }

        let snapshots = existingItems.compactMap {
            Self.playlistTrackSnapshot(
                $0.track,
                playlistItemID: $0.playlistItemID
            )
        } + newTracks.compactMap {
            Self.playlistTrackSnapshot(
                $0,
                playlistItemID: nil
            )
        }
        try await playlistRepository.setPlaylistTrackSnapshots(
            snapshots,
            forPlaylist: playlist.id,
            sourceCompositeKey: sourceKey
        )
        _ = try await playlistRepository.upsertPlaylist(
            ratingKey: cachedPlaylist.ratingKey,
            key: cachedPlaylist.key,
            title: cachedPlaylist.title,
            summary: cachedPlaylist.summary,
            compositePath: cachedPlaylist.compositePath,
            isSmart: cachedPlaylist.isSmart,
            duration: Int(snapshots.reduce(0) { $0 + $1.duration } * 1_000),
            trackCount: snapshots.count,
            dateAdded: cachedPlaylist.dateAdded,
            dateModified: cachedPlaylist.dateModified,
            lastPlayed: cachedPlaylist.lastPlayed,
            sourceCompositeKey: sourceKey
        )
        notifyPlaylistRefreshCompleted(serverSourceKey: sourceKey)
        EnsembleLogger.info(
            "Playlist optimistic cache updated source=\(sourceKey) playlist=\(playlist.id) tracks=\(snapshots.count)"
        )
        return snapshots.count
    }

    private static func playlistTrackSnapshot(
        _ track: Track,
        playlistItemID: String?
    ) -> PlaylistTrackSnapshot? {
        guard let sourceCompositeKey = track.sourceCompositeKey,
              MusicSourceIdentifier(compositeKey: sourceCompositeKey) != nil else { return nil }
        return PlaylistTrackSnapshot(
            ratingKey: track.id,
            playlistItemID: playlistItemID,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            duration: track.duration,
            thumbPath: track.thumbPath ?? track.fallbackThumbPath,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func refreshProviderPlaylists(
        _ provider: MusicSourceSyncProvider,
        sourceKey: String,
        persistenceOperation: SourcePersistenceOperation
    ) async {
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
        let result: PlaylistSyncResult
        do {
            result = try await provider.syncPlaylistsIncremental(
                to: playlistRepository,
                forceOrphanCheck: true,
                progressHandler: { _ in }
            )
        } catch is CancellationError {
            return
        } catch {
            do {
                result = try await provider.syncPlaylists(
                    to: playlistRepository,
                    progressHandler: { _ in }
                )
            } catch is CancellationError {
                return
            } catch {
                EnsembleLogger.error(
                    "Playlist refresh failed source=\(sourceKey): \(error.localizedDescription)"
                )
                return
            }
        }
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
        await cachePlaylistArtwork(sourceId: provider.sourceIdentifier, provider: provider)
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
        publishContentChangeIfNeeded(
            for: provider.sourceIdentifier,
            playlistResult: result,
            syncedAt: Date()
        )
        notifyPlaylistRefreshCompleted(serverSourceKey: sourceKey)
    }

    private func refreshPlaylistsAfterMutation(
        sourceKey: String,
        requiredTracks: [Track]
    ) async {
        guard let inputPersistenceWork = beginPlaylistMutationPersistenceWork(
            sourceKey: sourceKey,
            tracks: requiredTracks
        ) else {
            return
        }
        defer { finishSourcePersistenceWork(inputPersistenceWork) }
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            return
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }
        guard let provider = try? playlistMutationProvider(for: sourceKey) else { return }
        await refreshProviderPlaylists(
            provider.provider,
            sourceKey: sourceKey,
            persistenceOperation: persistenceOperation
        )
    }

    private func reconcileProviderPlaylist(
        _ provider: MusicSourcePlaylistReconciling,
        providerSourceKey: String,
        sourceKey: String,
        playlistID: String,
        minimumTrackCount: Int,
        requiredTracks: [Track],
        expectedRevision: SourceProviderRevision
    ) async {
        guard let sourceKeys = playlistMutationSourceKeys(
            sourceKey: sourceKey,
            tracks: requiredTracks
        ),
              let persistenceWork = beginCurrentSourcePersistenceWork(sourceKeys: sourceKeys),
              isCurrentProviderRevision(expectedRevision, sourceKey: providerSourceKey) else {
            return
        }
        defer { finishSourcePersistenceWork(persistenceWork) }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let retryDelays: [UInt64] = [0, 1, 2, 4, 8, 16]
        for (index, delay) in retryDelays.enumerated() {
            let attempt = index + 1
            do {
                if delay > 0 {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
                guard isCurrentProviderRevision(expectedRevision, sourceKey: providerSourceKey),
                      isSourcePersistenceWorkCurrent(persistenceWork) else { return }
                guard let trackCount = try await provider.reconcilePlaylist(
                    id: playlistID,
                    minimumTrackCount: minimumTrackCount,
                    requiredTracks: requiredTracks,
                    to: playlistRepository
                ) else { continue }
                guard isCurrentProviderRevision(expectedRevision, sourceKey: providerSourceKey),
                      isSourcePersistenceWorkCurrent(persistenceWork) else { return }
                notifyPlaylistRefreshCompleted(serverSourceKey: sourceKey)
                EnsembleLogger.info(
                    "Playlist reconciliation completed source=\(sourceKey) playlist=\(playlistID) tracks=\(trackCount) attempts=\(attempt) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
                )
                return
            } catch is CancellationError {
                return
            } catch {
                EnsembleLogger.error(
                    "Playlist reconciliation failed source=\(sourceKey) playlist=\(playlistID) attempt=\(attempt): \(error.localizedDescription)"
                )
            }
        }
        EnsembleLogger.error(
            "Playlist reconciliation did not converge source=\(sourceKey) playlist=\(playlistID) expectedTracks=\(minimumTrackCount) requiredTracks=\(requiredTracks.count) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000))"
        )
    }

    #if os(iOS)
    @available(iOS 18, *)
    public func getAppleMusicCatalogPlaylistTracks(playlistID: String) async throws -> [Track] {
        guard let provider = syncProviders[MusicSourceIdentifier.appleMusic.compositeKey] as? AppleMusicSourceProvider
        else { throw PlaylistMutationError.invalidSource }
        return try await provider.getCatalogPlaylistTracks(playlistID: playlistID)
    }
    #endif

    @discardableResult
    public func addTrackToLibrary(_ track: Track) async throws -> MusicSourceLibraryAddOutcome {
        guard track.canAddToSourceLibrary,
              let sourceKey = track.sourceCompositeKey,
              sourceKey == MusicSourceIdentifier.appleMusic.compositeKey,
              let catalogID = track.appleMusicCatalogID else {
            throw PlaylistMutationError.invalidSource
        }

        let operationKey = "\(sourceKey)|\(catalogID)"
        if let activeAdd = activeSourceLibraryAdds[operationKey] {
            sourceLibraryAddDidCoalesceForTesting?()
            EnsembleLogger.info(
                "Source library mutation coalesced operation=add source=\(sourceKey) catalogID=\(catalogID)"
            )
            return try await activeAdd.task.value
        }

        let addToLibrary: () async throws -> MusicSourceLibraryAddOutcome
        if let sourceLibraryAddHandlerForTesting {
            addToLibrary = { try await sourceLibraryAddHandlerForTesting(catalogID) }
        } else {
            #if os(iOS)
            guard #available(iOS 18, *),
                  let provider = syncProviders[sourceKey] as? AppleMusicSourceProvider else {
                throw PlaylistMutationError.invalidSource
            }
            addToLibrary = { try await provider.addToLibrary(catalogID: catalogID) }
            #else
            throw PlaylistMutationError.invalidSource
            #endif
        }

        let id = UUID()
        let task = Task { try await addToLibrary() }
        activeSourceLibraryAdds[operationKey] = ActiveSourceLibraryAdd(id: id, task: task)

        do {
            let outcome = try await task.value
            if activeSourceLibraryAdds[operationKey]?.id == id {
                activeSourceLibraryAdds.removeValue(forKey: operationKey)
                reconcileLibraryAddition(
                    source: .appleMusic,
                    catalogID: catalogID
                )
            }
            return outcome
        } catch {
            if activeSourceLibraryAdds[operationKey]?.id == id {
                activeSourceLibraryAdds.removeValue(forKey: operationKey)
            }
            throw error
        }
    }

    private func reconcileLibraryAddition(
        source: MusicSourceIdentifier,
        catalogID: String
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await sync(source: source)
            switch outcome {
            case .success:
                EnsembleLogger.info(
                    "Source library reconciliation completed source=\(source.compositeKey) catalogID=\(catalogID)"
                )
            case .failure(let message):
                EnsembleLogger.error(
                    "Source library reconciliation failed source=\(source.compositeKey) catalogID=\(catalogID) message=\(message)"
                )
            }
        }
    }

    /// Replace playlist contents in the provided order and refresh local cache.
    public func replacePlaylistContents(_ playlist: Playlist, with orderedTracks: [Track]) async throws {
        guard playlist.supportsPlaylistEditing else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey,
              let inputPersistenceWork = beginPlaylistMutationPersistenceWork(
                  sourceKey: sourceKey,
                  tracks: orderedTracks
              ) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceWork(inputPersistenceWork) }
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: sourceKey)
        try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).replacePlaylistContents(
            playlist,
            with: orderedTracks,
            provider: provider.capability
        )
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
    }

    /// Edit playlist memberships through the exact provider without clearing the playlist.
    public func editPlaylistItems(
        _ playlist: Playlist,
        originalItems: [PlaylistItem],
        editedItems: [PlaylistItem]
    ) async throws {
        guard playlist.supportsPlaylistEditing else {
            throw PlaylistMutationError.smartPlaylistReadOnly
        }
        guard let sourceKey = playlist.sourceCompositeKey else {
            throw PlaylistMutationError.invalidSource
        }
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: sourceKey) else {
            throw PlaylistMutationError.invalidSource
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        let provider = try playlistMutationProvider(for: sourceKey)
        try await playlistMutationController(
            persistenceOperation: persistenceOperation,
            baseProvider: provider.provider
        ).editPlaylistItems(
            playlist,
            originalItems: originalItems,
            editedItems: editedItems,
            provider: provider.capability
        )
        guard isSourcePersistenceOperationCurrent(persistenceOperation) else {
            throw PlaylistMutationError.invalidSource
        }
    }

    /// Save queue snapshot tracks to a playlist.
    public func saveQueueSnapshot(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        try await addTracksToPlaylist(tracks, playlist: playlist)
    }

    /// Perform appropriate sync on app startup based on staleness
    /// - If last full sync > 24 hours: full sync
    /// - If last sync > 1 hour: incremental sync
    /// - Otherwise: skip (data is fresh enough)
    public func performStartupSync() async {
        await invalidatePlexReconciliationCursors()
        await syncExecutionController().performStartupSync(providers: syncProviders)
    }

    private func invalidatePlexReconciliationCursors() async {
        guard let syncCursorRepository else { return }

        var invalidatedServerKeys = Set<String>()
        for provider in syncProviders.values where provider.sourceIdentifier.type == .plex {
            do {
                try await syncCursorRepository.deleteCursor(
                    scopeKey: provider.sourceIdentifier.compositeKey,
                    scopeType: .plexLibrary
                )
            } catch {
                EnsembleLogger.error(
                    "Failed to prepare authoritative Plex reconciliation for \(provider.sourceIdentifier.compositeKey): \(error.localizedDescription)"
                )
            }

            let serverSourceKey = MediaSourceIdentity.serverSourceKey(for: provider.sourceIdentifier)
            guard invalidatedServerKeys.insert(serverSourceKey).inserted else { continue }
            UserDefaults.standard.removeObject(
                forKey: PlexMusicSourceSyncProvider.playlistOrphanCheckKey(for: serverSourceKey)
            )
            do {
                try await syncCursorRepository.invalidateInventorySync(
                    scopeKey: serverSourceKey,
                    scopeType: .serverPlaylists
                )
            } catch {
                EnsembleLogger.error(
                    "Failed to prepare authoritative Plex playlist reconciliation for \(serverSourceKey): \(error.localizedDescription)"
                )
            }
        }
    }

    /// Detect restored stores that have the genre catalog but not the per-item genre fields.
    /// Incremental sync cannot backfill those unchanged albums/tracks, so we force one full repair sync.
    private func sourceNeedsGenreMetadataRepair(_ sourceId: MusicSourceIdentifier) async -> Bool {
        do {
            guard let stats = try await libraryRepository.fetchGenreCoverageStats(forSource: sourceId.compositeKey) else {
                return false
            }

            guard Self.shouldRepairSparseGenreMetadata(stats) else {
                return false
            }

            EnsembleLogger.debug(
                "🧩 Genre coverage repair check for \(sourceId.compositeKey): " +
                "albums=\(stats.albumsWithGenreNames)/\(stats.albumCount), " +
                "tracks=\(stats.tracksWithGenreNames)/\(stats.trackCount), " +
                "genreCatalog=\(stats.genreCatalogCount)"
            )
            return true
        } catch {
            EnsembleLogger.error("Failed to inspect genre coverage for \(sourceId.compositeKey): \(error.localizedDescription)")
            return false
        }
    }

    internal static func shouldRepairSparseGenreMetadata(_ stats: GenreCoverageStats) -> Bool {
        guard stats.genreCatalogCount >= 3 else { return false }
        guard stats.albumCount >= 10 || stats.trackCount >= 50 else { return false }

        let albumCoverage = stats.albumCount > 0
            ? Double(stats.albumsWithGenreNames) / Double(stats.albumCount)
            : 1.0
        let trackCoverage = stats.trackCount > 0
            ? Double(stats.tracksWithGenreNames) / Double(stats.trackCount)
            : 1.0

        return albumCoverage < 0.10 || trackCoverage < 0.10
    }

    private func processReparentedTracks() async {
        let reparentedTracks = libraryRepository.drainTrackReparentInfo()
        if !reparentedTracks.isEmpty {
            EnsembleLogger.debug("[Sync] \(reparentedTracks.count) track(s) reparented — invalidating artwork")
            await onTrackAlbumChanged?(reparentedTracks)
        }
    }

    private func processArtworkInvalidations() async {
        let invalidations = libraryRepository.drainArtworkInvalidationInfo()
            + playlistRepository.drainArtworkInvalidationInfo()
        guard !invalidations.isEmpty else { return }

        EnsembleLogger.debug("[Sync] \(invalidations.count) artwork item(s) changed — invalidating cache")
        await onArtworkMetadataChanged?(invalidations)
    }

    private func syncExecutionController() -> SyncExecutionController {
        let providerRevisions = syncProviderRevisions
        return SyncExecutionController(
            dependencies: .init(
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                isSyncing: { self.isSyncing },
                setIsSyncing: { self.isSyncing = $0 },
                isOffline: { self.isOffline },
                statusForSource: { self.sourceStatuses[$0] },
                setStatus: { self.sourceStatuses[$0] = $1 },
                loadLastSyncDate: { await self.loadLastSyncDate(for: $0) },
                removeDuplicatePlaylists: { try? await self.playlistRepository.removeDuplicatePlaylists() },
                publishProgress: { self.throttledProgressUpdate(for: $0, mappedProgress: $1) },
                processReparentedTracks: { await self.processReparentedTracks() },
                processArtworkInvalidations: { await self.processArtworkInvalidations() },
                cacheArtworkForSource: { await self.cacheArtworkForSource(sourceId: $0, provider: $1) },
                cacheAlbumArtwork: { await self.cacheAlbumArtwork(sourceId: $0, provider: $1) },
                cacheArtistArtwork: { await self.cacheArtistArtwork(sourceId: $0, provider: $1) },
                cachePlaylistArtwork: { await self.cachePlaylistArtwork(sourceId: $0, provider: $1) },
                notifyPlaylistRefreshCompleted: { self.notifyPlaylistRefreshCompleted(serverSourceKey: $0) },
                connectionStateAfterSuccessfulSync: {
                    await self.serverConnectionController.connectionStateAfterSuccessfulSync(for: $0, fallback: $1)
                },
                markSourceSyncCompleted: { source in
                    guard source == .appleMusic else { return }
                    self.accountManager.markAppleMusicInitialSyncCompleted()
                },
                publishContentChange: { self.publishContentChangeIfNeeded(for: $0, libraryResult: $1, playlistResult: $2, syncedAt: $3) },
                restoreStatusAfterCancellation: { self.restoreStatusAfterCancellation(for: $0, previousStatus: $1, fallbackConnectionState: $2) },
                syncErrorMessage: { self.syncErrorMessage(for: $0) },
                effectiveConnectionState: { self.effectiveConnectionState(for: $0) },
                postSiriRebuildRequest: { SiriMediaIndexNotifications.postRebuildRequest(reason: "sync_completed") },
                sourceNeedsGenreMetadataRepair: { await self.sourceNeedsGenreMetadataRepair($0) },
                runStartupHealthChecksIfNeeded: { await self.runStartupHealthChecksIfNeeded(reason: $0, completionMessage: $1) },
                enabledServerKeysForHealthChecks: { self.enabledServerKeysForHealthChecks() },
                isCheckingHealth: { self.isCheckingHealth },
                lastHealthCheckCompletion: { self.lastHealthCheckCompletion },
                updateSourceConnectionStates: { self.updateSourceConnectionStates() },
                setLastStartupSyncCompletion: { self.lastStartupSyncCompletion = $0 },
                providerRevision: { providerRevisions[$0.compositeKey] },
                beginSourcePersistenceWork: {
                    self.beginSourcePersistenceWork(sourceKey: $0.compositeKey, revision: $1)
                },
                isSourcePersistenceWorkCurrent: {
                    self.isSourcePersistenceWorkCurrent(
                        sourceKey: $0.compositeKey,
                        revision: $1,
                        lease: $2
                    )
                },
                finishSourcePersistenceWork: { self.finishSourcePersistenceWork($0) },
                runSourceSync: { source, operation in
                    await self.runSourceSyncSingleFlight(source: source, operation: operation)
                },
                publishPreflightFailure: { source, message in
                    self.publishSourceSyncPreflightFailure(source: source, message: message)
                }
            )
        )
    }

    /// Ensure the server connection is ready for a given track
    /// This ensures we have a working connection URL before attempting playback
    public func ensureServerConnection(for track: Track) async throws {
        guard let sourceKey = resolvedTrackSourceCompositeKey(for: track) else {
            throw PlexAPIError.noServerSelected
        }
        try await serverConnectionController.ensureServerConnection(sourceKey: sourceKey)
    }

    public func serverFailureMessage(for track: Track) async -> String? {
        guard let sourceKey = resolvedTrackSourceCompositeKey(for: track) else {
            return nil
        }
        return serverConnectionController.serverFailureMessage(sourceKey: sourceKey)
    }

    /// Proactively refreshes Plex server connections across configured accounts.
    /// Playback retry paths use this to recover from transient connection failures.
    public func refreshConnection() async throws {
        try await serverConnectionController.refreshConnections()
    }

    /// Get the stream URL for a track, routing to the correct provider
    /// - Parameters:
    ///   - track: The track to stream
    ///   - quality: Streaming quality preference (default: original)
    public func getStreamURL(for track: Track, quality: StreamingQuality = .original) async throws -> StreamResolution {
        EnsembleLogger.debug("🔍 Getting stream URL for track: \(track.title) [quality: \(quality.rawValue)]")
        EnsembleLogger.debug("🔍 Track sourceKey: \(track.sourceCompositeKey ?? "nil")")
        EnsembleLogger.debug("🔍 Track streamKey: \(track.streamKey ?? "nil")")
        EnsembleLogger.debug("🔍 Available providers: \(syncProviders.keys.joined(separator: ", "))")

        let (provider, resolution) = try await resolveTrackCapability(
            for: track,
            capability: "streaming",
            as: MusicSourcePlaybackResolving.self
        )
        logStreamProviderResolution(resolution)
        return try await provider.getStreamURL(
            for: track.id,
            trackStreamKey: track.streamKey,
            quality: quality,
            metadataDurationSeconds: track.duration
        )
    }

    // MARK: - Two-Phase Stream Resolution

    /// Phase 1: Make a streaming decision for a track without embedding the server endpoint URL.
    /// The returned `StreamDecision` can be cached across network transitions — it captures
    /// codec, quality, and session parameters that don't change when the endpoint changes.
    public func makeStreamDecision(
        for track: Track,
        quality: StreamingQuality = .original,
        startTime: TimeInterval = 0
    ) async throws -> StreamDecision {
        let (provider, _) = try await resolveTrackCapability(
            for: track,
            capability: "streaming",
            as: MusicSourceTwoPhasePlaybackResolving.self
        )
        return try await provider.makeStreamDecision(
            for: track.id,
            trackStreamKey: track.streamKey,
            quality: quality,
            metadataDurationSeconds: track.duration,
            startTime: startTime
        )
    }

    /// Phase 2: Assemble a `StreamResolution` from a cached `StreamDecision` using the
    /// current server endpoint. Call this at download start time for a fresh URL.
    /// This is a lightweight operation (no network calls) — the endpoint is read from
    /// `ServerConnectionRegistry` at assembly time.
    public func assembleStreamResolution(for track: Track, from decision: StreamDecision) async throws -> StreamResolution {
        let (provider, _) = try await resolveTrackCapability(
            for: track,
            capability: "streaming",
            as: MusicSourceTwoPhasePlaybackResolving.self
        )
        return try await provider.assembleStreamResolution(from: decision)
    }

    /// Get a download URL for offline use, skipping the transcode decision endpoint.
    /// Routes through the provider's dedicated download path which avoids the unnecessary
    /// HTTP roundtrip that the streaming path requires for AVPlayer session warmup.
    public func getDownloadURL(for track: Track, quality: StreamingQuality = .original) async throws -> URL {
        let (provider, _) = try await resolveTrackCapability(
            for: track,
            capability: "downloads",
            as: MusicSourceTwoPhasePlaybackResolving.self
        )
        return try await provider.getDownloadURL(
            for: track.id,
            trackStreamKey: track.streamKey,
            quality: quality
        )
    }

    /// Get a quality-aware universal stream URL for offline downloading.
    /// Playback should continue using direct stream URLs for AVPlayer compatibility.
    public func getOfflineDownloadURL(for track: Track, quality: StreamingQuality) async throws -> URL {
        let apiClient = try await apiClientForTrack(track)

        guard let plexTrack = try await apiClient.getTrack(trackKey: track.id) else {
            throw PlexAPIError.invalidResponse
        }

        return try await apiClient.getUniversalStreamURL(for: plexTrack, quality: quality)
    }

    /// Download a complete quality-specific Plex file for export.
    public func downloadUniversalStreamToFile(
        for track: Track,
        quality: StreamingQuality
    ) async throws -> URL {
        let apiClient = try await apiClientForTrack(track)
        return try await apiClient.downloadUniversalStreamToFile(
            ratingKey: track.id,
            quality: quality
        )
    }

    /// Attempt a server-primed offline transcode through the download queue API.
    /// Returns media payload and optional suggested filename when successful.
    public func getOfflineDownloadQueueMedia(
        for track: Track,
        quality: StreamingQuality
    ) async throws -> (data: Data, suggestedFilename: String?, mimeType: String?) {
        let apiClient = try await apiClientForTrack(track)

        return try await apiClient.downloadTranscodedMediaViaQueue(
            trackRatingKey: track.id,
            quality: quality
        )
    }

    /// Get a quality-aware fallback URL for offline downloading using Plex's audio transcode endpoint.
    /// This is used when universal offline URLs are rejected by certain server configurations.
    public func getOfflineDownloadFallbackURL(
        for track: Track,
        quality: StreamingQuality,
        preferStreamKeyPath: Bool = false,
        useAbsolutePathParameter: Bool = false,
        useAudioEndpoint: Bool = false,
        useStartWithoutExtension: Bool = false
    ) async throws -> URL {
        let apiClient = try await apiClientForTrack(track)

        let transcodeTrackKey: String
        if preferStreamKeyPath,
           let streamKey = track.streamKey,
           !streamKey.isEmpty {
            // Some servers are stricter about path shape for transcode start and
            // only accept part paths instead of metadata paths.
            transcodeTrackKey = streamKey
        } else {
            transcodeTrackKey = "/library/metadata/\(track.id)"
        }

        return try await apiClient.getTranscodeStreamURL(
            trackKey: transcodeTrackKey,
            quality: quality,
            useAbsolutePathParameter: useAbsolutePathParameter,
            useAudioEndpoint: useAudioEndpoint,
            useStartWithoutExtension: useStartWithoutExtension
        )
    }

    private func apiClientForTrack(_ track: Track) async throws -> PlexAPIClient {
        let sourceKey = resolvedTrackSourceCompositeKey(for: track)
        return try serverConnectionController.requireAPIClient(sourceKey: sourceKey)
    }

    /// Get artwork URL, routing to the correct provider
    public func getArtworkURL(path: String?, sourceKey: String?, size: Int = 300) async throws -> URL? {
        guard let path = path else { return nil }

        if let resolution = providerResolver.resolve(sourceKey: sourceKey, allowServerScope: true) {
            return try await resolution.provider.getArtworkURL(path: path, size: size)
        }

        return nil
    }
    
    /// Rate a track, routing to the correct provider.
    /// After a successful rating change, triggers a debounced playlist sync so smart playlists
    /// reflect the updated rating state.
    public func rateTrack(track: Track, rating: Int?) async throws {
        guard let sourceKey = track.sourceCompositeKey else {
            throw MusicSourceRoutingError.invalidSourceKey(nil)
        }
        let ratingProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "ratings",
            as: MusicSourceRatingMutating.self
        )
        let effects = try await ratingProvider.rateTrack(track, rating: rating)

        // Trigger debounced playlist sync so smart playlists reflect the new rating
        if effects.shouldRefreshPlaylists {
            refreshOrchestrator.schedulePostRatingPlaylistSync(
                serverSourceKey: sourceKey,
                action: { [weak self] serverSourceKey in
                    await self?.refreshServerPlaylists(serverSourceKey: serverSourceKey)
                }
            )
        }

        // Trigger debounced favorites download reconciliation
        if effects.shouldReconcileFavoriteDownloads {
            refreshOrchestrator.schedulePostRatingFavoritesReconciliation(
                action: { [weak self] in
                    await self?.onFavoritesRatingChanged?()
                }
            )
        }
    }

    /// Report playback timeline to Plex server
    /// This updates the server with current playback state and position
    /// - Parameters:
    ///   - track: The currently playing track
    ///   - state: Playback state ("playing", "paused", or "stopped")
    ///   - time: Current playback time in seconds
    public func reportTimeline(track: Track, state: String, time: TimeInterval) async {
        try? await reportTimelineThrowing(track: track, state: state, time: time)
    }

    /// Throwing variant of reportTimeline that propagates errors to the caller.
    /// Used by PlaybackService for failure-aware backoff during offline periods.
    public func reportTimelineThrowing(track: Track, state: String, time: TimeInterval) async throws {
        try await playbackReportingController.reportTimeline(
            track: track,
            state: state,
            time: time,
            providers: syncProviders
        )
    }

    /// Scrobble a track (mark as played)
    /// This should be called when a track reaches ~90% completion
    /// - Parameter track: The track to scrobble
    public func scrobbleTrack(_ track: Track) async {
        do {
            try await scrobbleTrackThrowing(track)
        } catch {
            // Scrobbling is non-critical, just log the error
            EnsembleLogger.debug("⚠️ Failed to scrobble track: \(error.localizedDescription)")
        }
    }

    /// Scrobble a track, throwing on failure so MutationCoordinator can queue retries.
    public func scrobbleTrackThrowing(_ track: Track) async throws {
        try await playbackReportingController.scrobble(track: track, providers: syncProviders)
    }

    /// Get tracks for an album from the music source
    public func getAlbumTracks(albumId: String, sourceKey: String) async throws -> [Track] {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "album details",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getAlbumTracks(albumKey: albumId)
    }

    /// Get albums for an artist from the music source
    public func getArtistAlbums(artistId: String, sourceKey: String) async throws -> [Album] {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "artist details",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getArtistAlbums(artistKey: artistId)
    }

    /// Get all tracks for an artist from the music source
    public func getArtistTracks(artistId: String, sourceKey: String) async throws -> [Track] {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "artist details",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getArtistTracks(artistKey: artistId)
    }

    /// Get detailed artist metadata (genres, country, similar artists, styles) from the source
    public func getArtistDetail(artistId: String, sourceKey: String) async throws -> ArtistDetail? {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "artist details",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getArtistDetail(artistKey: artistId)
    }

    /// Get detailed album metadata (genres, styles, studio/label) from the source
    public func getAlbumDetail(albumId: String, sourceKey: String) async throws -> AlbumDetail? {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "album details",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getAlbumDetail(albumKey: albumId)
    }

    /// Get similar/related albums from Plex's recommendation engine
    public func getSimilarAlbums(albumId: String, sourceKey: String) async throws -> [Album] {
        let detailProvider = try providerResolver.requireCapability(
            sourceKey: sourceKey,
            name: "recommendations",
            as: MusicSourceDetailProviding.self
        )
        return try await detailProvider.getSimilarAlbums(albumKey: albumId)
    }

    /// Get source-owned audio metadata without exposing provider API models to callers.
    public func getAudioFileInfo(trackId: String, sourceKey: String?) async throws -> AudioFileInfo? {
        guard let provider = fileInfoProvider(for: sourceKey) else { return nil }
        return try await provider.getAudioFileInfo(trackID: trackId)
    }

    /// Get the source-owned common album folder when that concept is supported.
    public func getAlbumFolderPath(albumId: String, sourceKey: String?) async throws -> String? {
        guard let provider = fileInfoProvider(for: sourceKey) else { return nil }
        return try await provider.getAlbumFolderPath(albumID: albumId)
    }

    /// Delete all CoreData for a removed music source
    @discardableResult
    public func cleanupRemovedSource(_ sourceId: MusicSourceIdentifier) async -> Bool {
        if !accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(sourceId.compositeKey),
           syncProviders[sourceId.compositeKey] != nil {
            // Invalidate the provider registration before waiting so no new source work
            // can begin while cleanup drains an older operation.
            refreshProviders()
        }
        await cancelSourceSync(sourceId)
        await sourcePersistenceFence.beginCleanup(sourceKey: sourceId.compositeKey)
        var cleanupFenceFinished = false
        defer {
            if !cleanupFenceFinished {
                sourcePersistenceFence.finishCleanup(sourceKey: sourceId.compositeKey)
            }
        }

        if accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(sourceId.compositeKey) {
            sourcePersistenceFence.finishCleanup(sourceKey: sourceId.compositeKey)
            cleanupFenceFinished = true
            refreshProviders()
            EnsembleLogger.debug("Skipped cleanup for restored source: \(sourceId.compositeKey)")
            _ = await sync(source: sourceId)
            return true
        }

        libraryRepository.discardArtworkInvalidations(forSourceCompositeKey: sourceId.compositeKey)
        playlistRepository.discardArtworkInvalidations(forSourceCompositeKey: sourceId.compositeKey)

        if sourceId.type == .appleMusic {
            Playlist.clearAppleMusicPlaylistCapabilityCache()
            #if os(iOS)
            if #available(iOS 18, *) {
                AppleMusicSourceProvider.clearLibraryInventoryState()
            }
            #endif
            HomeHubLoader.removeFailedHubKey(forSourceCompositeKey: sourceId.compositeKey)
            clearLastPlaylistTargets(forServerSourceKey: sourceId.compositeKey)
        }

        do {
            EnsembleLogger.debug("🗑️ Cleaning up data for removed source: \(sourceId.compositeKey)")

            if let sourceCacheCleanupService {
                _ = try await sourceCacheCleanupService.cleanupSource(sourceId.compositeKey)
            } else {
                try await libraryRepository.deleteAllData(forSourceCompositeKey: sourceId.compositeKey)
            }
            if sourceId.type == .plex {
                try await syncCursorRepository?.deleteCursor(
                    scopeKey: sourceId.compositeKey,
                    scopeType: .plexLibrary
                )
            }

            if accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(sourceId.compositeKey) {
                sourcePersistenceFence.finishCleanup(sourceKey: sourceId.compositeKey)
                cleanupFenceFinished = true
                refreshProviders()
                EnsembleLogger.debug("Source restored during cleanup; rebuilding cache: \(sourceId.compositeKey)")
                _ = await sync(source: sourceId)
                return true
            }

            // Remove from status tracking
            sourceStatuses.removeValue(forKey: sourceId)

            // Clear API client cache for this source
            accountManager.clearAPIClientCache(accountId: sourceId.accountId, serverId: sourceId.serverId)

            NotificationCenter.default.post(
                name: Self.sourceCleanupDidComplete,
                object: self,
                userInfo: ["sourceCompositeKey": sourceId.compositeKey]
            )

            EnsembleLogger.debug("✅ Successfully cleaned up source: \(sourceId.compositeKey)")
            return true
        } catch {
            if accountManager.sourceConfigurationSnapshot.shouldPreserveSourceKey(sourceId.compositeKey) {
                sourcePersistenceFence.finishCleanup(sourceKey: sourceId.compositeKey)
                cleanupFenceFinished = true
                refreshProviders()
                EnsembleLogger.debug("Source restored after cleanup error; rebuilding cache: \(sourceId.compositeKey)")
                _ = await sync(source: sourceId)
                return true
            }
            EnsembleLogger.debug("❌ Failed to cleanup source \(sourceId.compositeKey): \(error)")
            return false
        }
    }

    /// Best-effort cleanup for removed/disabled sources that are still cached locally.
    /// Used by iCloud library-flag reconciliation to evict stale library data even when
    /// the remote flags match current account state (no transition event).
    public func cleanupRemovedSourcesIfPresent(_ sources: [MusicSourceIdentifier]) async {
        let uniqueSources = Array(Set(sources))
        guard !uniqueSources.isEmpty else { return }

        // The source row may not exist yet while an in-flight provider is writing its
        // first batch. Always enter the source fence, wait, and perform the final purge.
        for source in uniqueSources {
            await cleanupRemovedSource(source)
        }
    }

    /// Delete server-scoped playlists when no enabled libraries remain on that server.
    public func cleanupServerPlaylists(accountId: String, serverId: String) async {
        let serverSourceKey = "plex:\(accountId):\(serverId)"
        guard !hasEnabledLibrary(accountId: accountId, serverId: serverId) else {
            EnsembleLogger.debug("⏹️ Skipping stale playlist cleanup for re-enabled server: \(serverSourceKey)")
            return
        }
        await sourcePersistenceFence.beginCleanup(sourceKey: serverSourceKey)
        var cleanupFenceFinished = false
        defer {
            if !cleanupFenceFinished {
                sourcePersistenceFence.finishCleanup(sourceKey: serverSourceKey)
            }
        }
        do {
            // Collect playlist ratingKeys before deletion for artwork cleanup
            var playlistKeys = Set<String>()
            if let playlists = try? await playlistRepository.fetchPlaylists(sourceCompositeKey: serverSourceKey) {
                for playlist in playlists {
                    playlistKeys.insert(playlist.ratingKey)
                }
            }

            let restoredBeforeDeletion = enabledLibrarySources(accountId: accountId, serverId: serverId)
            if !restoredBeforeDeletion.isEmpty {
                sourcePersistenceFence.finishCleanup(sourceKey: serverSourceKey)
                cleanupFenceFinished = true
                refreshProviders()
                EnsembleLogger.debug("⏹️ Skipping stale playlist cleanup for re-enabled server: \(serverSourceKey)")
                await sync(sources: restoredBeforeDeletion)
                return
            }
            playlistRepository.discardArtworkInvalidations(forSourceCompositeKey: serverSourceKey)
            try await playlistRepository.deletePlaylists(sourceCompositeKey: serverSourceKey)
            clearLastPlaylistTargets(forServerSourceKey: serverSourceKey)
            let timestampKey = "lastPlaylistSyncAt_\(serverSourceKey)"
            UserDefaults.standard.removeObject(forKey: timestampKey)
            UserDefaults.standard.removeObject(forKey: PlexMusicSourceSyncProvider.playlistOrphanCheckKey(for: serverSourceKey))
            try await syncCursorRepository?.deleteCursor(
                scopeKey: serverSourceKey,
                scopeType: .serverPlaylists
            )
            if let sourceCacheCleanupService {
                _ = try await sourceCacheCleanupService.cleanupSource(serverSourceKey)
            }

            let restoredSources = enabledLibrarySources(accountId: accountId, serverId: serverId)
            if !restoredSources.isEmpty {
                sourcePersistenceFence.finishCleanup(sourceKey: serverSourceKey)
                cleanupFenceFinished = true
                refreshProviders()
                EnsembleLogger.debug("Server restored during playlist cleanup; rebuilding cache: \(serverSourceKey)")
                await sync(sources: restoredSources)
                return
            }

            // Delete cached playlist artwork files
            if !playlistKeys.isEmpty {
                artworkDownloadManager.deleteArtwork(
                    forRatingKeys: playlistKeys,
                    sourceCompositeKey: serverSourceKey
                )
                EnsembleLogger.debug("🗑️ Deleted \(playlistKeys.count) playlist artwork files for server: \(serverSourceKey)")
            }
        } catch {
            let restoredSources = enabledLibrarySources(accountId: accountId, serverId: serverId)
            if !restoredSources.isEmpty {
                sourcePersistenceFence.finishCleanup(sourceKey: serverSourceKey)
                cleanupFenceFinished = true
                refreshProviders()
                EnsembleLogger.debug("Server restored after cleanup error; rebuilding cache: \(serverSourceKey)")
                await sync(sources: restoredSources)
                return
            }
            EnsembleLogger.debug("❌ Failed to cleanup server playlists \(serverSourceKey): \(error)")
        }
    }

    private func hasEnabledLibrary(accountId: String, serverId: String) -> Bool {
        !enabledLibrarySources(accountId: accountId, serverId: serverId).isEmpty
    }

    private func enabledLibrarySources(accountId: String, serverId: String) -> [MusicSourceIdentifier] {
        let libraries = accountManager.plexAccounts
            .first(where: { $0.id == accountId })?
            .servers
            .first(where: { $0.id == serverId })?
            .libraries
            .filter(\.isEnabled) ?? []
        return libraries.map {
                MusicSourceIdentifier(
                    type: .plex,
                    accountId: accountId,
                    serverId: serverId,
                    libraryId: $0.key
                )
        }
    }
    
    // MARK: - Artwork Pre-Caching

    /// Cache artwork for all albums, artists, and playlists in a source.
    /// Each helper skips items already cached at detail size, so repeat calls are lightweight.
    private func cacheArtworkForSource(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        await cacheAlbumArtwork(sourceId: sourceId, provider: provider)
        await cacheArtistArtwork(sourceId: sourceId, provider: provider)
        await cachePlaylistArtwork(sourceId: sourceId, provider: provider)
    }

    /// Cache artwork for all albums belonging to a source.
    /// Lightweight — skips albums that already have detail-grade cached artwork on disk.
    private func cacheAlbumArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            let sourceAlbums = try await libraryRepository.fetchAlbums(forSource: sourceId.compositeKey)
            var cached = 0

            for album in sourceAlbums {
                if await artworkDownloadManager.localArtworkExists(
                    for: album,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    continue
                }

                guard let thumbPath = album.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: album.ratingKey,
                            type: .album,
                            sourcePath: thumbPath,
                            dateModified: album.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension,
                            sourceCompositeKey: sourceId.compositeKey
                        )
                    )
                    cached += 1
                } catch {
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for album \(album.title): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) albums (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch albums for artwork caching: \(error.localizedDescription)")
        }
    }

    /// Cache artwork for all artists belonging to a source.
    /// Lightweight — skips artists that already have detail-grade cached artwork on disk.
    private func cacheArtistArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            let sourceArtists = try await libraryRepository.fetchArtists(forSource: sourceId.compositeKey)
            var cached = 0

            for artist in sourceArtists {
                if await artworkDownloadManager.localArtworkExists(
                    for: artist,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    continue
                }

                guard let thumbPath = artist.thumbPath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: artist.ratingKey,
                            type: .artist,
                            sourcePath: thumbPath,
                            dateModified: artist.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension,
                            sourceCompositeKey: sourceId.compositeKey
                        )
                    )
                    cached += 1
                } catch {
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for artist \(artist.name): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) artists (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch artists for artwork caching: \(error.localizedDescription)")
        }
    }

    /// Cache composite artwork for all playlists belonging to a source.
    /// Lightweight — skips playlists that already have detail-grade cached artwork on disk.
    private func cachePlaylistArtwork(sourceId: MusicSourceIdentifier, provider: MusicSourceSyncProvider) async {
        do {
            let serverKey = MediaSourceIdentity.serverSourceKey(from: sourceId.compositeKey) ?? sourceId.compositeKey
            let playlists = try await playlistRepository.fetchPlaylists(
                sourceCompositeKeys: [serverKey, sourceId.compositeKey]
            )
            var cached = 0
            let now = nowProviderForTesting()

            for playlist in playlists {
                let artworkSourceKey = playlist.sourceCompositeKey ?? sourceId.compositeKey
                let retryKey = "\(artworkSourceKey)|\(playlist.ratingKey)"
                if await artworkDownloadManager.localArtworkExists(
                    for: playlist,
                    minimumPixelDimension: Self.fullSizeArtworkCacheDimension
                ) {
                    playlistArtworkRetryAfter.removeValue(forKey: retryKey)
                    continue
                }

                if let retryAfter = playlistArtworkRetryAfter[retryKey], retryAfter > now {
                    continue
                }

                guard let thumbPath = playlist.compositePath,
                      let artworkURL = try? await provider.getArtworkURL(
                        path: thumbPath,
                        size: Self.fullSizeArtworkCacheDimension
                      ) else {
                    continue
                }

                do {
                    try await artworkDownloadManager.downloadAndCacheArtwork(
                        from: artworkURL,
                        identity: ArtworkIdentity(
                            ratingKey: playlist.ratingKey,
                            type: .playlist,
                            sourcePath: thumbPath,
                            dateModified: playlist.dateModified,
                            requestedPixelDimension: Self.fullSizeArtworkCacheDimension,
                            sourceCompositeKey: artworkSourceKey
                        )
                    )
                    playlistArtworkRetryAfter.removeValue(forKey: retryKey)
                    cached += 1
                } catch {
                    playlistArtworkRetryAfter[retryKey] = now.addingTimeInterval(playlistArtworkFailureBackoff)
                    EnsembleLogger.debug("⚠️ Failed to cache artwork for playlist \(playlist.title): \(error.localizedDescription)")
                }
            }

            if cached > 0 {
                EnsembleLogger.debug("🖼️ Cached artwork for \(cached) playlists (\(sourceId.compositeKey))")
            }
        } catch {
            EnsembleLogger.debug("⚠️ Failed to fetch playlists for artwork caching: \(error.localizedDescription)")
        }
    }

    private func resolvedTrackSourceCompositeKey(for track: Track) -> String? {
        guard let sourceKey = track.sourceCompositeKey,
              MediaSourceIdentity.parse(sourceKey)?.libraryId != nil else {
            EnsembleLogger.debug("⚠️ Track has no valid library source key: \(track.id)")
            return nil
        }
        return sourceKey
    }

    private func resolveTrackCapability<Capability>(
        for track: Track,
        capability: String,
        as _: Capability.Type
    ) async throws -> (Capability, SyncProviderResolver.ProviderResolution) {
        guard let sourceKey = resolvedTrackSourceCompositeKey(for: track) else {
            throw MusicSourceRoutingError.invalidSourceKey(track.sourceCompositeKey)
        }
        let match = try providerResolver.requireCapabilityMatchingSourceScope(
            sourceKey: sourceKey,
            name: capability,
            as: Capability.self
        )
        let resolvedSourceKey = match.provider.sourceIdentifier.compositeKey
        return (
            match.capability,
            SyncProviderResolver.ProviderResolution(
                sourceKey: resolvedSourceKey,
                provider: match.provider,
                usedServerScope: resolvedSourceKey != sourceKey
            )
        )
    }

    private func logStreamProviderResolution(_ resolution: SyncProviderResolver.ProviderResolution) {
        guard !resolution.usedServerScope else {
            EnsembleLogger.debug("🔍 Using provider for server-scoped source")
            return
        }

        guard let sourceKey = resolution.sourceKey else {
            EnsembleLogger.debug("🔍 Using provider without source key")
            return
        }

        guard let identity = MediaSourceIdentity.parse(sourceKey),
              let libraryId = identity.libraryId else {
            EnsembleLogger.debug("🔍 Using provider for sourceKey: \(sourceKey)")
            return
        }

        if let account = accountManager.plexAccounts.first(where: { $0.id == identity.accountId }),
           let server = account.servers.first(where: { $0.id == identity.serverId }) {
            EnsembleLogger.debug("🔍 Using provider for server: \(server.name) (ID: \(identity.serverId), Library: \(libraryId))")
        } else {
            EnsembleLogger.debug("🔍 Using provider for sourceKey: \(sourceKey)")
        }
    }

    /// Refresh playlists for a specific server after a mutation so CoreData stays in sync.
    private func refreshServerPlaylists(
        serverSourceKey: String,
        trigger: PlaylistRefreshController.Trigger = .mutationRefresh,
        allowFullFallback: Bool = true
    ) async {
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: serverSourceKey) else {
            return
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        do {
            guard let result = try await playlistRefreshController.refreshServer(
                serverSourceKey: serverSourceKey,
                providers: persistenceOperation.providers,
                playlistRepository: playlistRepository,
                trigger: trigger,
                allowFullFallback: allowFullFallback
            ) else {
                return
            }

            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            if case .downloadedPlaylist = trigger,
               !result.playlistResult.hasMaterialChanges {
                return
            }
            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        } catch is CancellationError {
            EnsembleLogger.debug("⏹️ SyncCoordinator: Playlist refresh cancelled for \(serverSourceKey)")
        } catch {
            EnsembleLogger.debug("⚠️ SyncCoordinator: Playlist refresh failed for \(serverSourceKey): \(error.localizedDescription)")
        }
    }

    private func persistLastPlaylistTarget(from playlist: Playlist) {
        let previousTarget = lastPlaylistTarget(forServerSourceKey: playlist.sourceCompositeKey)
        let title = playlist.title.isEmpty && previousTarget?.id == playlist.id
            ? previousTarget?.title ?? ""
            : playlist.title
        let target = LastPlaylistTarget(
            id: playlist.id,
            title: title,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
        if let serverSourceKey = playlist.sourceCompositeKey {
            lastPlaylistTargetsByServer[serverSourceKey] = target
            Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)
        }
        Self.saveLastPlaylistTarget(target)
        lastPlaylistTarget = target
    }

    public func rememberLastPlaylistTarget(_ playlist: Playlist) {
        persistLastPlaylistTarget(from: playlist)
    }

    private func clearLastPlaylistTargetIfNeeded(deletedPlaylist: Playlist) {
        guard let deletedSourceKey = deletedPlaylist.sourceCompositeKey else { return }

        lastPlaylistTargetsByServer = lastPlaylistTargetsByServer.filter { sourceKey, target in
            !(sourceKey == deletedSourceKey && target.id == deletedPlaylist.id)
        }
        Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)

        if let lastPlaylistTarget,
           lastPlaylistTarget.id == deletedPlaylist.id,
           lastPlaylistTarget.sourceCompositeKey == deletedSourceKey {
            self.lastPlaylistTarget = nil
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    private func clearLastPlaylistTargets(forServerSourceKey serverSourceKey: String) {
        lastPlaylistTargetsByServer.removeValue(forKey: serverSourceKey)
        Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)

        if let lastPlaylistTarget,
           lastPlaylistTarget.sourceCompositeKey == serverSourceKey {
            self.lastPlaylistTarget = nil
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    public func lastPlaylistTarget(forServerSourceKey serverSourceKey: String?) -> LastPlaylistTarget? {
        guard let serverSourceKey else { return lastPlaylistTarget }
        if let target = lastPlaylistTargetsByServer[serverSourceKey] {
            return target
        }
        if let lastPlaylistTarget, lastPlaylistTarget.sourceCompositeKey == serverSourceKey {
            return lastPlaylistTarget
        }
        return nil
    }

    internal func setLastPlaylistTargetForTesting(_ target: LastPlaylistTarget?, serverSourceKey: String?) {
        if let serverSourceKey {
            if let target {
                lastPlaylistTargetsByServer[serverSourceKey] = target
            } else {
                lastPlaylistTargetsByServer.removeValue(forKey: serverSourceKey)
            }
            Self.saveLastPlaylistTargetsByServer(lastPlaylistTargetsByServer)
        }

        lastPlaylistTarget = target
        let defaults = UserDefaults.standard
        if let target {
            defaults.set(target.id, forKey: Self.lastPlaylistIdKey)
            defaults.set(target.title, forKey: Self.lastPlaylistTitleKey)
            defaults.set(target.sourceCompositeKey, forKey: Self.lastPlaylistSourceKey)
        } else {
            defaults.removeObject(forKey: Self.lastPlaylistIdKey)
            defaults.removeObject(forKey: Self.lastPlaylistTitleKey)
            defaults.removeObject(forKey: Self.lastPlaylistSourceKey)
        }
    }

    private static func saveLastPlaylistTarget(_ target: LastPlaylistTarget) {
        let defaults = UserDefaults.standard
        defaults.set(target.id, forKey: lastPlaylistIdKey)
        defaults.set(target.title, forKey: lastPlaylistTitleKey)
        defaults.set(target.sourceCompositeKey, forKey: lastPlaylistSourceKey)
    }

    private static func loadLastPlaylistTarget() -> LastPlaylistTarget? {
        let defaults = UserDefaults.standard
        guard
            let id = defaults.string(forKey: lastPlaylistIdKey),
            let title = defaults.string(forKey: lastPlaylistTitleKey)
        else {
            return nil
        }
        return LastPlaylistTarget(
            id: id,
            title: title,
            sourceCompositeKey: defaults.string(forKey: lastPlaylistSourceKey)
        )
    }

    private static func saveLastPlaylistTargetsByServer(_ targets: [String: LastPlaylistTarget]) {
        let defaults = UserDefaults.standard
        guard let data = try? JSONEncoder().encode(targets) else { return }
        defaults.set(data, forKey: lastPlaylistTargetsByServerKey)
    }

    private static func loadLastPlaylistTargetsByServer() -> [String: LastPlaylistTarget] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: lastPlaylistTargetsByServerKey),
              let decoded = try? JSONDecoder().decode([String: LastPlaylistTarget].self, from: data) else {
            return [:]
        }
        return decoded
    }
    
    // MARK: - Network Monitoring
    
    /// Set up observation of network state changes
    private func setupNetworkMonitoring() {
        networkMonitor.$networkState
            .dropFirst()
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    await self?.handleObservedNetworkState(state)
                }
            }
            .store(in: &cancellables)
    }

    private func setupSourceConfigurationMonitoring() {
        accountManager.sourceConfigurationPublisher
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshHealthForNewlyEnabledServers()
                }
            }
            .store(in: &cancellables)
    }

    private func refreshHealthForNewlyEnabledServers() {
        let enabledServerKeys = enabledServerKeysForHealthChecks()
        let newlyEnabledServerKeys = enabledServerKeys.subtracting(enabledServerKeysSnapshot)
        enabledServerKeysSnapshot = enabledServerKeys

        guard !newlyEnabledServerKeys.isEmpty else { return }
        serverHealthChecker.prepopulateUnknownStates()
        scheduleHealthRefresh(reason: .accountInventoryRefresh, forceServerRefresh: true)
    }

    /// Runs or joins an authoritative server health refresh and publishes its dependent state.
    public func refreshServerHealthStates() async {
        scheduleHealthRefresh(reason: .accountInventoryRefresh, forceServerRefresh: true)
        await refreshOrchestrator.waitForActiveHealthRefresh()
    }

    public func handleAppWillEnterForeground() async {
        if accountManager.enforceAuthTokenPolicy() {
            refreshProviders()
        }

        let currentState = networkMonitor.networkState

        EnsembleLogger.debug("🌐 SyncCoordinator: App entering foreground with state \(currentState.description)")
        UserJourneyLogger.log(
            context: "network",
            event: "appForeground",
            details: ["state": currentState.description]
        )

        let decision = networkLifecycleController.foregroundDecision(for: currentState)
        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Foreground decision \(decision.diagnosticSummary)"
        )
        applyOfflineDecision(decision.offlineValue)

        if let request = decision.healthRefreshRequest {
            EnsembleLogger.debug(
                "🌐 SyncCoordinator: Scheduling foreground health refresh force=\(request.forceServerRefresh)"
            )
            scheduleHealthRefresh(reason: request.reason, forceServerRefresh: request.forceServerRefresh)
        } else if decision.offlineValue == true {
            EnsembleLogger.debug("🌐 SyncCoordinator: Foreground health refresh skipped because app is offline")
            updateSourceConnectionStates()
        }
    }

    private func handleObservedNetworkState(_ state: NetworkState) async {
        let decision = networkLifecycleController.observeNetworkState(state)

        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Network transition \(decision.diagnosticSummary)"
        )
        UserJourneyLogger.log(
            context: "network",
            event: "stateChanged",
            details: [
                "from": decision.previousState?.description ?? "nil",
                "to": state.description,
                "transition": decision.transition.logDescription
            ]
        )
        if case .interfaceSwitch(let from, let to) = decision.transition {
            EnsembleLogger.debug("🌐 SyncCoordinator: Detected interface switch \(from.description) -> \(to.description)")
        }

        applyOfflineDecision(decision.offlineValue)
        if decision.offlineValue == true {
            updateSourceConnectionStates()
        }

        if decision.skippedAsInitialTransition {
            return
        }

        if decision.shouldInvalidateConnectionHealth {
            // Invalidate connection health caches on reconnect.
            // Stale endpoints from before the network went down may no longer work
            // (e.g. if IP addresses changed or TLS state is corrupted).
            await serverHealthChecker.invalidateConnectionHealth()
        }

        if decision.shouldInvalidateArtworkConnections {
            // Immediately invalidate artwork URL cache on reconnect.
            // This prevents stale artwork requests that use old endpoint URLs while
            // health checks are still running.
            EnsembleLogger.debug("🖼️ SyncCoordinator: Early artwork cache invalidation for network transition")
            await onConnectionsRefreshed?()
        }

        if let request = decision.healthRefreshRequest {
            scheduleHealthRefresh(reason: request.reason, forceServerRefresh: request.forceServerRefresh)
        }
    }

    private func applyOfflineDecision(_ offlineValue: Bool?) {
        guard let offlineValue else { return }

        if offlineValue {
            if !isOffline { isOffline = true }
        } else if isOffline {
            isOffline = false
        }
    }

    private func scheduleHealthRefresh(reason: RefreshOrchestrator.HealthRefreshReason, forceServerRefresh: Bool) {
        let request = RefreshOrchestrator.HealthRefreshRequest(
            reason: reason,
            forceServerRefresh: forceServerRefresh
        )

        let didSchedule = refreshOrchestrator.scheduleHealthRefresh(
            request: request,
            now: nowProviderForTesting,
            shouldDeferForegroundHealthRefresh: shouldDeferForegroundHealthRefresh,
            eligibleServerKeysProvider: { self.enabledServerKeysForHealthChecks() },
            runRefresh: { [weak self] request, eligibleServerKeys, startedAt in
                guard let self else { return }

                // Capture pre-check states to detect unknown→connected transitions.
                let preCheckStates = self.serverHealthChecker.serverStates

                let summary = await self.runHealthChecks(
                    forceServerRefresh: request.forceServerRefresh,
                    eligibleServerKeys: eligibleServerKeys
                )
                await self.completeHealthRefresh(
                    preCheckStates: preCheckStates,
                    reasonDescription: request.reason.description,
                    summary: summary,
                    startedAt: startedAt,
                    completionMessage: "🌐 SyncCoordinator: Health refresh complete"
                )
            },
            didComplete: { [weak self] completionTime in
                guard let self else { return }
                self.isCheckingHealth = self.refreshOrchestrator.hasScheduledHealthRefresh
                self.lastHealthCheckCompletion = completionTime
            }
        )

        if didSchedule {
            isCheckingHealth = true
        }
        EnsembleLogger.debug(
            "🌐 SyncCoordinator: Health refresh request reason=\(reason.description) force=\(forceServerRefresh) scheduled=\(didSchedule)"
        )
    }

    private func enabledServerKeysForHealthChecks() -> Set<String> {
        var keys = Set<String>()

        for account in accountManager.plexAccounts {
            for server in account.servers where server.libraries.contains(where: \.isEnabled) {
                keys.insert("\(account.id):\(server.id)")
            }
        }

        return keys
    }

    private func runHealthChecks(
        forceServerRefresh: Bool,
        eligibleServerKeys: Set<String>
    ) async -> ServerHealthChecker.CheckSummary {
        if let healthCheckRunnerForTesting {
            return await healthCheckRunnerForTesting(forceServerRefresh, eligibleServerKeys)
        }

        return await serverHealthChecker.checkAllServers(
            forceRefresh: forceServerRefresh,
            eligibleServerKeys: eligibleServerKeys
        )
    }

    private func runAPIClientConnectionRefresh() async {
        if let refreshAPIClientConnectionsRunnerForTesting {
            await refreshAPIClientConnectionsRunnerForTesting()
            return
        }

        await serverConnectionController.refreshAPIClientConnections()
    }

    // MARK: - Targeted Server Health Checks

    /// Trigger a health check for a specific server identified by sourceCompositeKey.
    /// Called by PlaybackService when a playback failure indicates the server may be unreachable.
    /// Updates serverStates and source connection states so TrackAvailabilityResolver reacts.
    public func triggerServerHealthCheck(sourceKey: String) async {
        guard let server = MediaSourceIdentity.parse(sourceKey) else { return }

        EnsembleLogger.debug("🏥 SyncCoordinator: Targeted health check for server \(server.accountId):\(server.serverId)")

        let state = await serverHealthChecker.checkServer(
            accountId: server.accountId,
            serverId: server.serverId
        )
        updateSourceConnectionStates()

        EnsembleLogger.debug("🏥 SyncCoordinator: Targeted health check result: \(state)")
    }

    /// Check whether a server is known to be available based on cached health state.
    /// Returns false if the server is offline, degraded-offline, or has no cached state.
    public func isServerAvailable(sourceKey: String?) -> Bool {
        guard let server = MediaSourceIdentity.parse(sourceKey) else {
            return true // Assume available if we can't determine the server
        }
        let serverKey = "\(server.accountId):\(server.serverId)"
        guard let state = serverHealthChecker.serverStates[serverKey] else {
            return true // No cached state means we haven't checked — assume available
        }
        return state.isAvailable
    }

    /// Optimistic availability check for preflight operations like queue filtering and artwork loading.
    /// Returns true if the server is available OR if health checks haven't completed yet
    /// (.unknown/.connecting). This avoids premature local-file fallback during startup
    /// when health checks are still in flight. The actual request remains authoritative.
    public func isServerPossiblyAvailable(sourceKey: String?) -> Bool {
        guard let server = MediaSourceIdentity.parse(sourceKey) else {
            return true
        }
        let serverKey = "\(server.accountId):\(server.serverId)"
        guard let state = serverHealthChecker.serverStates[serverKey] else {
            return true
        }
        switch state {
        case .connected, .degraded, .unknown, .connecting:
            return true
        case .offline:
            return false
        }
    }

    internal func handleObservedNetworkStateForTesting(_ state: NetworkState) async {
        await handleObservedNetworkState(state)
    }

    internal func awaitHealthRefreshForTesting() async {
        await refreshOrchestrator.awaitHealthRefreshForTesting()
    }

    internal func awaitSourceConfigurationHealthRefreshForTesting() async {
        await Task.yield()
        await refreshOrchestrator.awaitHealthRefreshForTesting()
    }

    internal func setLastHealthRefreshForTesting(_ date: Date?) {
        refreshOrchestrator.setLastHealthRefreshForTesting(date)
    }

    internal func installSyncProviderForTesting(
        _ provider: MusicSourceSyncProvider,
        status: MusicSourceStatus? = nil
    ) {
        let source = provider.sourceIdentifier
        syncProviders[source.compositeKey] = provider
        registerCurrentProviders(
            enforceSourceConfiguration: false,
            preserveUnchangedRevisions: false
        )
        if let status {
            sourceStatuses[source] = status
        } else if sourceStatuses[source] == nil {
            sourceStatuses[source] = MusicSourceStatus()
        }
    }

    /// Update all API clients with the latest working connection URLs from health checks.
    /// When a `ServerConnectionRegistry` is active, most updates flow reactively through
    /// `ServerConnectionController`. This method remains as a fallback for tests and
    /// the non-registry path.
    public func refreshAPIClientConnections() async {
        await serverConnectionController.refreshAPIClientConnections()
    }

    /// Run early health checks at startup and update source connection states.
    /// Routes through the same cooldown tracking as `scheduleHealthRefresh` so
    /// the initial Unknown→Online network transition won't trigger a duplicate pass.
    public func performStartupHealthChecks() async {
        let didRun = await runStartupHealthChecksIfNeeded(
            reason: "early health checks",
            completionMessage: "🏥 SyncCoordinator: Startup health checks complete"
        )
        if !didRun {
            EnsembleLogger.debug("🏥 SyncCoordinator: Skipping early health checks — startup sync already handling them")
        }
    }

    /// Public entry point for callers outside SyncCoordinator (e.g. AppDelegate)
    /// that need to push health-check results into sourceStatuses.
    public func updateSourceConnectionStatesFromAppDelegate() {
        updateSourceConnectionStates()
    }

    /// Update source statuses with current connection states from health checker
    private func updateSourceConnectionStates() {
        for account in accountManager.plexAccounts {
            for server in account.servers {
                for library in server.libraries where library.isEnabled {
                    let sourceId = MusicSourceIdentifier(
                        type: .plex,
                        accountId: account.id,
                        serverId: server.id,
                        libraryId: library.key
                    )
                    
                    // Get connection state from health checker
                    let connectionState = serverHealthChecker.getServerState(
                        accountId: account.id,
                        serverId: server.id
                    )
                    
                    // Update status preserving sync state
                    if let currentStatus = sourceStatuses[sourceId] {
                        sourceStatuses[sourceId] = MusicSourceStatus(
                            syncStatus: currentStatus.syncStatus,
                            connectionState: connectionState
                        )
                    } else {
                        sourceStatuses[sourceId] = MusicSourceStatus(
                            syncStatus: .idle,
                            connectionState: connectionState
                        )
                    }
                }
            }
        }
    }

    // MARK: - Provider Access

    /// Returns normalized lyrics access for the exact configured source.
    public func lyricsProvider(for sourceCompositeKey: String?) -> MusicSourceLyricsProviding? {
        providerResolver.resolve(
            sourceKey: sourceCompositeKey,
            allowServerScope: false
        )?.provider as? MusicSourceLyricsProviding
    }

    private func fileInfoProvider(for sourceCompositeKey: String?) -> MusicSourceFileInfoProviding? {
        providerResolver.resolve(
            sourceKey: sourceCompositeKey,
            allowServerScope: false
        )?.provider as? MusicSourceFileInfoProviding
    }

    // MARK: - Radio Provider Factory

    /// Create a radio provider for a specific music source
    /// Returns nil if the source doesn't support radio or isn't configured
    /// - Parameter sourceKey: The music source composite key
    public func makeRadioProvider(for sourceKey: String) -> MusicSourceRadioProviding? {
        providerResolver.resolve(sourceKey: sourceKey, allowServerScope: true)?.provider
            as? MusicSourceRadioProviding
    }
    
    // MARK: - Periodic Sync During Active Use
    
    /// Start periodic incremental sync while app is active (every 1 hour)
    public func startPeriodicSync() {
        EnsembleLogger.debug("⏰ Starting periodic sync timer (every 1 hour)")
        periodicSyncController.start(
            action: { [weak self] in
                await self?.performPeriodicSync()
            },
            downloadedPlaylistAction: { [weak self] in
                await self?.performDownloadedPlaylistSync()
            }
        )
    }
    
    /// Stop periodic sync
    public func stopPeriodicSync() {
        periodicSyncController.stop()
        EnsembleLogger.debug("🛑 Stopped periodic sync timer")
    }
    
    /// Perform periodic incremental sync (called by timer)
    private func performPeriodicSync() async {
        EnsembleLogger.debug("⏰ Periodic sync triggered")
        
        // Don't sync if offline
        guard !isOffline else {
            EnsembleLogger.debug("📴 Offline - skipping periodic sync")
            return
        }
        
        // Don't sync if already syncing
        guard !isSyncing else {
            EnsembleLogger.debug("⏳ Sync already in progress - skipping periodic sync")
            return
        }
        
        // Check network connectivity - only sync when connected
        #if os(iOS)
        if !networkMonitor.isConnected {
            EnsembleLogger.debug("📡 Not connected - skipping periodic sync")
            return
        }
        #endif
        
        EnsembleLogger.debug("🔄 Performing periodic incremental sync...")
        await syncAllIncremental()
        EnsembleLogger.debug("✅ Periodic sync complete")
    }

    private func performDownloadedPlaylistSync() async {
        guard !isOffline, !isSyncing, !isDownloadedPlaylistSyncing else { return }
        #if os(iOS)
        guard networkMonitor.isConnected else { return }
        #endif
        guard let serverSourceKeys = downloadedPlaylistServerSourceKeys?(),
              !serverSourceKeys.isEmpty else { return }

        isDownloadedPlaylistSyncing = true
        defer { isDownloadedPlaylistSyncing = false }

        EnsembleLogger.debug("⏰ Refreshing downloaded playlists on \(serverSourceKeys.count) server(s)")
        for serverSourceKey in serverSourceKeys.sorted() {
            await refreshServerPlaylists(
                serverSourceKey: serverSourceKey,
                trigger: .downloadedPlaylist,
                allowFullFallback: false
            )
        }
    }

    // MARK: - WebSocket-Triggered Sync

    /// Trigger an incremental sync for a specific library section.
    /// Called by `PlexWebSocketCoordinator` when a library update notification arrives.
    public func syncSectionIncremental(sectionKey: String, serverKey: String) async {
        await syncSectionIncremental(sectionKey: sectionKey, serverKey: serverKey, changes: [])
    }

    func syncSectionIncremental(
        sectionKey: String,
        serverKey: String,
        changes: Set<PlexLibraryChange>
    ) async {
        guard !isOffline else {
            EnsembleLogger.debug("🔌 SyncCoordinator: Skipping WebSocket-triggered sync for section \(sectionKey) while offline")
            return
        }

        let resolutions = webSocketSyncController.resolveSections(
            sectionKey: sectionKey,
            serverKey: serverKey,
            providers: syncProviders,
            knownSources: Set(sourceStatuses.keys)
        )
        guard !resolutions.isEmpty else {
            EnsembleLogger.error("🔌 SyncCoordinator: No provider found for server \(serverKey) section \(sectionKey) — providers: \(syncProviders.keys.joined(separator: ", "))")
            return
        }

        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered incremental sync for section \(sectionKey) (sources=\(resolutions.count), items=\(changes.count))")

        for resolution in resolutions {
            let targetedReconciliationSucceeded = await reconcilePlexLibraryChanges(
                changes,
                resolution: resolution
            )
            let requiresInventory = changes.isEmpty || changes.contains(where: { $0.isDeletion }) || !targetedReconciliationSucceeded
            if requiresInventory {
                do {
                    try await syncCursorRepository?.invalidateInventorySync(
                        scopeKey: resolution.sourceId.compositeKey,
                        scopeType: .plexLibrary
                    )
                } catch {
                    EnsembleLogger.error(
                        "🔌 SyncCoordinator: Failed to invalidate library inventory cursor for \(resolution.compositeKey): \(error.localizedDescription)"
                    )
                }
            }
            await syncIncremental(source: resolution.sourceId)
            EnsembleLogger.debug("🔌 SyncCoordinator: Incremental sync completed for section \(sectionKey) (source=\(resolution.compositeKey))")
        }
    }

    private func reconcilePlexLibraryChanges(
        _ changes: Set<PlexLibraryChange>,
        resolution: WebSocketSyncController.SectionResolution
    ) async -> Bool {
        guard changes.contains(where: { !$0.isDeletion }) else { return true }

        if let activeSync = activeSourceSyncs[resolution.sourceId.compositeKey] {
            _ = await activeSync.task.value
        }

        guard let operation = beginSourcePersistenceOperation(sourceKey: resolution.sourceId.compositeKey) else {
            return false
        }
        defer { finishSourcePersistenceOperation(operation) }
        guard let provider = operation.providers[resolution.sourceId.compositeKey] as? PlexMusicSourceSyncProvider else {
            return false
        }

        do {
            let result = try await provider.reconcileLibraryChanges(changes, to: libraryRepository)
            guard isSourcePersistenceOperationCurrent(operation) else { return false }
            await processReparentedTracks()
            guard isSourcePersistenceOperationCurrent(operation) else { return false }
            await processArtworkInvalidations()
            guard isSourcePersistenceOperationCurrent(operation) else { return false }
            publishContentChangeIfNeeded(
                for: resolution.sourceId,
                libraryResult: result,
                syncedAt: Date()
            )
            if result.hasMaterialChanges {
                SiriMediaIndexNotifications.postRebuildRequest(reason: "plex_targeted_reconciliation")
            }
            return true
        } catch {
            EnsembleLogger.error(
                "🔌 SyncCoordinator: Targeted Plex reconciliation failed for \(resolution.compositeKey): \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Trigger a playlist-only sync for a specific server.
    /// Called by `PlexWebSocketCoordinator` when a playlist update notification arrives.
    /// Does not depend on `isSyncing` so it can run alongside library sync.
    public func syncServerPlaylistsIncremental(serverKey: String) async {
        EnsembleLogger.debug("🔌 SyncCoordinator: WebSocket-triggered playlist sync for server \(serverKey)")
        let serverSourceKey = "plex:\(serverKey)"
        guard let persistenceOperation = beginSourcePersistenceOperation(sourceKey: serverSourceKey) else {
            return
        }
        defer { finishSourcePersistenceOperation(persistenceOperation) }

        do {
            guard let result = try await webSocketSyncController.refreshServerPlaylists(
                serverKey: serverKey,
                providers: persistenceOperation.providers,
                playlistRepository: playlistRepository,
                playlistRefreshController: playlistRefreshController
            ) else {
                EnsembleLogger.error("🔌 SyncCoordinator: No playlist refresh result for server \(serverKey)")
                return
            }
            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            await cachePlaylistArtwork(sourceId: result.sourceId, provider: result.provider)
            guard isSourcePersistenceOperationCurrent(persistenceOperation) else { return }
            publishContentChangeIfNeeded(
                for: result.sourceId,
                playlistResult: result.playlistResult,
                syncedAt: Date()
            )
            EnsembleLogger.debug("🔌 SyncCoordinator: Playlist sync completed for server \(serverKey), posting notification")
            notifyPlaylistRefreshCompleted(serverSourceKey: result.serverSourceKey)
        } catch is CancellationError {
            EnsembleLogger.debug("⏹️ SyncCoordinator: Playlist sync cancelled for server \(serverKey)")
        } catch {
            EnsembleLogger.error("🔌 SyncCoordinator: Playlist sync failed for server \(serverKey): \(error.localizedDescription)")
        }
    }

    /// Adjust periodic sync intervals based on WebSocket availability.
    /// When WebSocket is active for servers, polling can be relaxed since updates arrive in real-time.
    public func adjustTimersForWebSocket(hasActiveWebSocket: Bool) {
        periodicSyncController.adjustForWebSocket(hasActiveWebSocket: hasActiveWebSocket) { [weak self] in
            await self?.performPeriodicSync()
        }
        if hasActiveWebSocket {
            EnsembleLogger.debug("⏰ SyncCoordinator: WebSocket active — relaxed periodic sync to 4h")
        } else {
            EnsembleLogger.debug("⏰ SyncCoordinator: No WebSocket — using default 1h periodic sync")
        }
    }

    private func notifyPlaylistRefreshCompleted(serverSourceKey: String) {
        onPlaylistRefreshCompleted?(serverSourceKey)
        NotificationCenter.default.post(
            name: Self.playlistsDidRefresh,
            object: nil,
            userInfo: ["serverSourceKey": serverSourceKey]
        )
    }

    private func runStartupHealthChecksIfNeeded(
        reason: String,
        completionMessage: String
    ) async -> Bool {
        let eligibleServers = enabledServerKeysForHealthChecks()
        guard !eligibleServers.isEmpty else { return false }
        isCheckingHealth = true

        let didRun = await refreshOrchestrator.runStartupHealthChecksIfNeeded(
            now: nowProviderForTesting,
            runRefresh: { [weak self] in
                guard let self else { return }
                let healthCheckStart = self.nowProviderForTesting()
                EnsembleLogger.debug("🏥 SyncCoordinator: Running \(reason) for \(eligibleServers.count) server(s)...")

                let preCheckStates = self.serverHealthChecker.serverStates
                let summary = await self.runHealthChecks(
                    forceServerRefresh: false,
                    eligibleServerKeys: eligibleServers
                )
                await self.completeHealthRefresh(
                    preCheckStates: preCheckStates,
                    reasonDescription: reason,
                    summary: summary,
                    startedAt: healthCheckStart,
                    completionMessage: completionMessage
                )
            },
            didComplete: { [weak self] completionTime in
                guard let self else { return }
                self.isCheckingHealth = self.refreshOrchestrator.hasScheduledHealthRefresh
                self.lastHealthCheckCompletion = completionTime
            }
        )
        if !didRun {
            isCheckingHealth = false
        }
        return didRun
    }

    private func completeHealthRefresh(
        preCheckStates: [String: ServerConnectionState],
        reasonDescription: String,
        summary: ServerHealthChecker.CheckSummary,
        startedAt: Date,
        completionMessage: String
    ) async {
        updateSourceConnectionStates()
        await runAPIClientConnectionRefresh()

        let postCheckStates = serverHealthChecker.serverStates
        let anyBecameAvailable = preCheckStates.contains { key, preState in
            guard !preState.isAvailable else { return false }
            return postCheckStates[key]?.isAvailable == true
        }
        if anyBecameAvailable {
            NotificationCenter.default.post(name: ArtworkLoader.serversBecameAvailable, object: nil)
        }

        let duration = nowProviderForTesting().timeIntervalSince(startedAt)
        EnsembleLogger.debug(
            "\(completionMessage) in \(String(format: "%.2f", duration))s — checked=\(summary.checkedCount), skipped=\(summary.skippedCount), reason=\(reasonDescription)"
        )
    }
}
