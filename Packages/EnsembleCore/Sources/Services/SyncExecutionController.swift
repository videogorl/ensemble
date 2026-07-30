import EnsemblePersistence
import Foundation

struct SourceProviderRevision: Equatable, Sendable {
    let sourceConfiguration: UInt64
    let providerRegistration: UInt64
}

struct ConfiguredSourceProvider: Sendable {
    let provider: MusicSourceSyncProvider
    let revision: SourceProviderRevision
}

struct SourcePersistenceLease: Hashable, Sendable {
    let sourceKey: String
    fileprivate let id: UUID
}

/// Opaque access to the shared source fence for persistence work that lives
/// outside sync execution, such as detached durable artwork writes.
struct SourcePersistenceWorkHandle: Sendable {
    let leases: [SourcePersistenceLease]
}

/// Keeps source cleanup ordered after every provider write that was already in flight.
/// A cleanup fence also rejects new work until its final purge completes.
@MainActor
final class SourcePersistenceFence {
    private var activeLeaseIDs: [String: Set<UUID>] = [:]
    private var cleanupDepth: [String: Int] = [:]
    private var idleWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func begin(sourceKey: String) -> SourcePersistenceLease? {
        let scopeKeys = persistenceScopeKeys(for: sourceKey)
        guard scopeKeys.allSatisfy({ cleanupDepth[$0] == nil }) else { return nil }
        let lease = SourcePersistenceLease(sourceKey: sourceKey, id: UUID())
        for scopeKey in scopeKeys {
            activeLeaseIDs[scopeKey, default: []].insert(lease.id)
        }
        return lease
    }

    func isCurrent(_ lease: SourcePersistenceLease) -> Bool {
        persistenceScopeKeys(for: lease.sourceKey).allSatisfy {
            cleanupDepth[$0] == nil && activeLeaseIDs[$0]?.contains(lease.id) == true
        }
    }

    func finish(_ lease: SourcePersistenceLease) {
        for scopeKey in persistenceScopeKeys(for: lease.sourceKey) {
            activeLeaseIDs[scopeKey]?.remove(lease.id)
            guard activeLeaseIDs[scopeKey]?.isEmpty != false else { continue }
            activeLeaseIDs.removeValue(forKey: scopeKey)
            let waiters = idleWaiters.removeValue(forKey: scopeKey) ?? []
            waiters.forEach { $0.resume() }
        }
    }

    func beginCleanup(sourceKey: String) async {
        await beginCleanup(sourceKeys: [sourceKey])
    }

    func beginCleanup(sourceKeys: Set<String>) async {
        let orderedKeys = sourceKeys.sorted()
        for sourceKey in orderedKeys {
            cleanupDepth[sourceKey, default: 0] += 1
        }
        for sourceKey in orderedKeys where activeLeaseIDs[sourceKey]?.isEmpty == false {
            await withCheckedContinuation { continuation in
                idleWaiters[sourceKey, default: []].append(continuation)
            }
        }
    }

    func finishCleanup(sourceKey: String) {
        finishCleanup(sourceKeys: [sourceKey])
    }

    func finishCleanup(sourceKeys: Set<String>) {
        for sourceKey in sourceKeys {
            finishSingleCleanup(sourceKey: sourceKey)
        }
    }

    private func finishSingleCleanup(sourceKey: String) {
        guard let depth = cleanupDepth[sourceKey] else { return }
        if depth > 1 {
            cleanupDepth[sourceKey] = depth - 1
        } else {
            cleanupDepth.removeValue(forKey: sourceKey)
        }
    }

    private func persistenceScopeKeys(for sourceKey: String) -> Set<String> {
        guard let identity = MediaSourceIdentity.parse(sourceKey),
              !identity.isServerScoped,
              identity.sourceType.capabilities.playlistsAreServerScoped else {
            return [sourceKey]
        }
        return [sourceKey, identity.serverSourceKey]
    }
}

/// Owns full/incremental/startup sync execution while the facade keeps
/// published state, health-check coordination, and transport-facing helpers.
@MainActor
final class SyncExecutionController {
    struct Dependencies {
        let libraryRepository: LibraryRepositoryProtocol
        let playlistRepository: PlaylistRepositoryProtocol
        let isSyncing: () -> Bool
        let setIsSyncing: (Bool) -> Void
        let isOffline: () -> Bool
        let statusForSource: (MusicSourceIdentifier) -> MusicSourceStatus?
        let setStatus: (MusicSourceIdentifier, MusicSourceStatus) -> Void
        let loadLastSyncDate: (MusicSourceIdentifier) async -> Date?
        let removeDuplicatePlaylists: () async -> Void
        let publishProgress: (MusicSourceIdentifier, Double) -> Void
        let processReparentedTracks: () async -> Void
        let processArtworkInvalidations: () async -> Void
        let cacheArtworkForSource: (MusicSourceIdentifier, MusicSourceSyncProvider) async -> Void
        let cacheAlbumArtwork: (MusicSourceIdentifier, MusicSourceSyncProvider) async -> Void
        let cacheArtistArtwork: (MusicSourceIdentifier, MusicSourceSyncProvider) async -> Void
        let cachePlaylistArtwork: (MusicSourceIdentifier, MusicSourceSyncProvider) async -> Void
        let notifyPlaylistRefreshCompleted: (String) -> Void
        let connectionStateAfterSuccessfulSync: (MusicSourceIdentifier, ServerConnectionState) async -> ServerConnectionState
        let markSourceSyncCompleted: (MusicSourceIdentifier) -> Void
        let publishContentChange: (MusicSourceIdentifier, LibrarySyncResult?, PlaylistSyncResult?, Date) -> Void
        let restoreStatusAfterCancellation: (MusicSourceIdentifier, MusicSourceStatus?, ServerConnectionState) -> Void
        let syncErrorMessage: (Error) -> String
        let effectiveConnectionState: (ServerConnectionState) -> ServerConnectionState
        let postSiriRebuildRequest: () -> Void
        let sourceNeedsGenreMetadataRepair: (MusicSourceIdentifier) async -> Bool
        let runStartupHealthChecksIfNeeded: (String, String) async -> Bool
        let enabledServerKeysForHealthChecks: () -> Set<String>
        let isCheckingHealth: () -> Bool
        let lastHealthCheckCompletion: () -> Date?
        let updateSourceConnectionStates: () -> Void
        let setLastStartupSyncCompletion: (Date) -> Void
        let providerRevision: (MusicSourceIdentifier) -> SourceProviderRevision?
        let beginSourcePersistenceWork: (MusicSourceIdentifier, SourceProviderRevision) -> SourcePersistenceLease?
        let isSourcePersistenceWorkCurrent: (MusicSourceIdentifier, SourceProviderRevision, SourcePersistenceLease) -> Bool
        let finishSourcePersistenceWork: (SourcePersistenceLease) -> Void
        let runSourceSync: (
            MusicSourceIdentifier,
            @escaping @MainActor () async -> MusicSourceSyncOutcome
        ) async -> MusicSourceSyncOutcome
        let publishPreflightFailure: (MusicSourceIdentifier, String) -> Void
    }

    private let dependencies: Dependencies
    private let startupHealthCheckPollNanoseconds: UInt64 = 100_000_000
    private let startupHealthCheckWaitTimeout: TimeInterval = 12.0

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func syncAll(providers: [String: MusicSourceSyncProvider]) async {
        guard !dependencies.isSyncing() else { return }
        dependencies.setIsSyncing(true)
        defer { dependencies.setIsSyncing(false) }

        await dependencies.removeDuplicatePlaylists()

        var syncedServerKeys = Set<String>()
        for (_, provider) in providers {
            let source = provider.sourceIdentifier
            let shouldSyncPlaylists = syncedServerKeys.insert(serverSourceKey(for: source)).inserted
            _ = await dependencies.runSourceSync(source) {
                await self.syncFullSource(
                    provider,
                    source: source,
                    shouldSyncPlaylists: shouldSyncPlaylists,
                    publishGlobalSyncState: false,
                    libraryProgressWeight: 0.7,
                    playlistProgressBase: 0.8,
                    playlistProgressWeight: 0.2,
                    cacheArtworkAfterLibrarySync: true
                )
            }
        }
    }

    @discardableResult
    func sync(
        source: MusicSourceIdentifier,
        providers: [String: MusicSourceSyncProvider]
    ) async -> MusicSourceSyncOutcome {
        await syncSingleSource(source, providers: providers, publishGlobalSyncState: true)
    }

    func sync(
        sources: [MusicSourceIdentifier],
        providers: [String: MusicSourceSyncProvider]
    ) async {
        var uniqueSources: [MusicSourceIdentifier] = []
        var seenCompositeKeys = Set<String>()
        for source in sources where seenCompositeKeys.insert(source.compositeKey).inserted {
            uniqueSources.append(source)
        }
        guard !uniqueSources.isEmpty else { return }

        let shouldPublishGlobalSyncState = !dependencies.isSyncing()
        if shouldPublishGlobalSyncState {
            dependencies.setIsSyncing(true)
        }
        defer {
            if shouldPublishGlobalSyncState {
                dependencies.setIsSyncing(false)
            }
        }

        for source in uniqueSources {
            _ = await syncSingleSource(source, providers: providers, publishGlobalSyncState: false)
        }
    }

    func syncAllIncremental(providers: [String: MusicSourceSyncProvider]) async {
        guard !dependencies.isSyncing() else {
            EnsembleLogger.debug("⏳ syncAllIncremental: Already syncing, skipping")
            return
        }
        dependencies.setIsSyncing(true)
        defer { dependencies.setIsSyncing(false) }
        EnsembleLogger.debug("🔄 syncAllIncremental: Starting...")

        var syncedServerKeys = Set<String>()
        for (_, provider) in providers {
            let source = provider.sourceIdentifier
            let shouldSyncPlaylists = syncedServerKeys.insert(serverSourceKey(for: source)).inserted
            guard let lastSyncDate = await dependencies.loadLastSyncDate(source) else {
                EnsembleLogger.debug("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
                _ = await dependencies.runSourceSync(source) {
                    await self.syncFullSource(
                        provider,
                        source: source,
                        shouldSyncPlaylists: shouldSyncPlaylists,
                        publishGlobalSyncState: false,
                        libraryProgressWeight: 0.9,
                        playlistProgressBase: 0.9,
                        playlistProgressWeight: 0.1,
                        cacheArtworkAfterLibrarySync: false
                    )
                }
                continue
            }

            _ = await dependencies.runSourceSync(source) {
                await self.syncIncrementalSource(
                    provider,
                    source: source,
                    lastSyncDate: lastSyncDate,
                    shouldSyncPlaylists: shouldSyncPlaylists,
                    publishGlobalSyncState: false,
                    logTimings: false,
                    cacheArtworkAfterSync: false,
                    notifyPlaylistRefreshAfterSync: true
                )
            }
        }
    }

    func syncIncremental(
        source: MusicSourceIdentifier,
        providers: [String: MusicSourceSyncProvider]
    ) async {
        guard let provider = providers[source.compositeKey] else { return }
        guard let lastSyncDate = await dependencies.loadLastSyncDate(source) else {
            EnsembleLogger.debug("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
            await sync(source: source, providers: providers)
            return
        }

        _ = await dependencies.runSourceSync(source) {
            await self.syncIncrementalSource(
                provider,
                source: source,
                lastSyncDate: lastSyncDate,
                shouldSyncPlaylists: true,
                publishGlobalSyncState: false,
                logTimings: true,
                cacheArtworkAfterSync: true,
                notifyPlaylistRefreshAfterSync: true
            )
        }
    }

    func performStartupSync(providers: [String: MusicSourceSyncProvider]) async {
        EnsembleLogger.debug("🚀 Performing startup sync...")

        guard !dependencies.isOffline() else {
            EnsembleLogger.debug("📴 Offline - skipping startup sync")
            return
        }

        guard !dependencies.isSyncing() else {
            EnsembleLogger.debug("⏳ Sync already in progress - skipping startup sync")
            return
        }

        guard !providers.isEmpty else {
            EnsembleLogger.debug("ℹ️ No sync providers configured - skipping startup sync")
            return
        }

        await waitForStartupHealthChecksIfNeeded()

        let ranStartupHealthChecks = await dependencies.runStartupHealthChecksIfNeeded(
            "startup sync",
            "🏥 Startup health checks complete"
        )
        if !dependencies.enabledServerKeysForHealthChecks().isEmpty && !ranStartupHealthChecks {
            EnsembleLogger.debug("🏥 Skipping startup sync health checks — already handled by the early startup path")
            dependencies.updateSourceConnectionStates()
        }

        var needsFullSync = false
        for (_, provider) in providers {
            let source = provider.sourceIdentifier

            if await dependencies.sourceNeedsGenreMetadataRepair(source) {
                EnsembleLogger.info("🧩 Source \(source.compositeKey) has sparse restored genre metadata - forcing full sync repair")
                needsFullSync = true
                break
            }

            if let lastSyncDate = await dependencies.loadLastSyncDate(source) {
                let hoursSinceSync = Date().timeIntervalSince(lastSyncDate) / 3600
                if hoursSinceSync > 24 {
                    EnsembleLogger.debug("⏰ Source \(source.compositeKey) last synced \(Int(hoursSinceSync)) hours ago - needs full sync")
                    needsFullSync = true
                    break
                }
            } else {
                EnsembleLogger.debug("⏰ Source \(source.compositeKey) has never been synced - needs full sync")
                needsFullSync = true
                break
            }
        }

        if needsFullSync {
            EnsembleLogger.debug("🔄 Starting full sync on startup...")
            await syncAll(providers: providers)
        } else {
            EnsembleLogger.debug("🔄 Starting incremental sync on startup...")
            await syncAllIncremental(providers: providers)
        }

        dependencies.setLastStartupSyncCompletion(Date())
    }

    private func waitForStartupHealthChecksIfNeeded() async {
        guard dependencies.lastHealthCheckCompletion() == nil,
              dependencies.isCheckingHealth() else {
            return
        }

        let waitStart = Date()
        EnsembleLogger.debug("🏥 SyncExecutionController: Waiting for in-flight startup health checks before sync")

        while dependencies.lastHealthCheckCompletion() == nil,
              dependencies.isCheckingHealth(),
              Date().timeIntervalSince(waitStart) < startupHealthCheckWaitTimeout {
            try? await Task.sleep(nanoseconds: startupHealthCheckPollNanoseconds)
        }

        if let completion = dependencies.lastHealthCheckCompletion() {
            let elapsed = completion.timeIntervalSince(waitStart)
            EnsembleLogger.debug(
                "🏥 SyncExecutionController: Startup sync unblocked after health checks in \(String(format: "%.2f", max(elapsed, 0)))s"
            )
        } else if dependencies.isCheckingHealth() {
            EnsembleLogger.debug(
                "🏥 SyncExecutionController: Timed out waiting for startup health checks after \(String(format: "%.2f", startupHealthCheckWaitTimeout))s"
            )
        }
    }

    private func syncSingleSource(
        _ source: MusicSourceIdentifier,
        providers: [String: MusicSourceSyncProvider],
        publishGlobalSyncState: Bool
    ) async -> MusicSourceSyncOutcome {
        return await dependencies.runSourceSync(source) {
            guard let provider = providers[source.compositeKey] else {
                let message = "The music source is unavailable. Please try again."
                EnsembleLogger.error("Sync failed for \(source.compositeKey): \(message)")
                self.dependencies.publishPreflightFailure(source, message)
                return .failure(message: message)
            }
            return await self.syncFullSource(
                provider,
                source: source,
                shouldSyncPlaylists: true,
                publishGlobalSyncState: publishGlobalSyncState,
                libraryProgressWeight: 0.8,
                playlistProgressBase: 0.8,
                playlistProgressWeight: 0.2,
                cacheArtworkAfterLibrarySync: false
            )
        }
    }

    @discardableResult
    private func syncFullSource(
        _ provider: MusicSourceSyncProvider,
        source: MusicSourceIdentifier,
        shouldSyncPlaylists: Bool,
        publishGlobalSyncState: Bool,
        libraryProgressWeight: Double,
        playlistProgressBase: Double,
        playlistProgressWeight: Double,
        cacheArtworkAfterLibrarySync: Bool
    ) async -> MusicSourceSyncOutcome {
        guard let sourceWork = beginSourcePersistenceWork(for: source) else {
            return staleSourceOutcome(for: source, publishFailure: true)
        }
        defer { dependencies.finishSourcePersistenceWork(sourceWork.lease) }

        let shouldPublishGlobalSyncState = publishGlobalSyncState && !dependencies.isSyncing()
        if shouldPublishGlobalSyncState {
            dependencies.setIsSyncing(true)
        }
        defer {
            if shouldPublishGlobalSyncState {
                dependencies.setIsSyncing(false)
            }
        }

        let currentConnectionState = dependencies.statusForSource(source)?.connectionState ?? .unknown
        let previousStatus = dependencies.statusForSource(source)
        var libraryResult: LibrarySyncResult?
        dependencies.setStatus(
            source,
            MusicSourceStatus(syncStatus: .syncing(progress: 0), connectionState: currentConnectionState)
        )

        do {
            libraryResult = try await provider.syncLibrary(
                to: dependencies.libraryRepository,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        guard dependencies.isSourcePersistenceWorkCurrent(
                            source,
                            sourceWork.revision,
                            sourceWork.lease
                        ) else { return }
                        dependencies.publishProgress(source, progress * libraryProgressWeight)
                    }
                }
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            await dependencies.processReparentedTracks()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            await dependencies.processArtworkInvalidations()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            if cacheArtworkAfterLibrarySync {
                await dependencies.cacheArtworkForSource(source, provider)
                guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                    return staleSourceOutcome(for: source)
                }
            }

            let playlistResult = try await syncPlaylistsIfNeeded(
                provider: provider,
                source: source,
                enabled: shouldSyncPlaylists,
                incremental: false,
                progressBase: playlistProgressBase,
                progressWeight: playlistProgressWeight,
                sourceWork: sourceWork
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            await dependencies.processArtworkInvalidations()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            if cacheArtworkAfterLibrarySync, playlistResult != nil {
                await dependencies.cachePlaylistArtwork(source, provider)
                guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                    return staleSourceOutcome(for: source)
                }
            }

            let syncedAt = Date()
            let resolvedConnectionState = await dependencies.connectionStateAfterSuccessfulSync(
                source,
                currentConnectionState
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            dependencies.markSourceSyncCompleted(source)
            dependencies.setStatus(
                source,
                MusicSourceStatus(syncStatus: .lastSynced(syncedAt), connectionState: resolvedConnectionState)
            )
            dependencies.publishContentChange(source, libraryResult, playlistResult, syncedAt)
            dependencies.postSiriRebuildRequest()
            return .success
        } catch is CancellationError {
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            publishCommittedLibraryChangesIfNeeded(libraryResult, source: source)
            dependencies.restoreStatusAfterCancellation(source, previousStatus, currentConnectionState)
            return .failure(message: "Sync was cancelled.")
        } catch {
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            publishCommittedLibraryChangesIfNeeded(libraryResult, source: source)
            let message = dependencies.syncErrorMessage(error)
            EnsembleLogger.error("Sync failed for \(source.compositeKey): \(message)")
            dependencies.setStatus(
                source,
                MusicSourceStatus(
                    syncStatus: .error(message),
                    connectionState: dependencies.effectiveConnectionState(currentConnectionState)
                )
            )
            return .failure(message: message)
        }
    }

    private func publishCommittedLibraryChangesIfNeeded(
        _ libraryResult: LibrarySyncResult?,
        source: MusicSourceIdentifier
    ) {
        guard libraryResult?.hasMaterialChanges == true else { return }
        dependencies.publishContentChange(source, libraryResult, nil, Date())
        dependencies.postSiriRebuildRequest()
    }

    private func syncIncrementalSource(
        _ provider: MusicSourceSyncProvider,
        source: MusicSourceIdentifier,
        lastSyncDate: Date,
        shouldSyncPlaylists: Bool,
        publishGlobalSyncState: Bool,
        logTimings: Bool,
        cacheArtworkAfterSync: Bool,
        notifyPlaylistRefreshAfterSync: Bool
    ) async -> MusicSourceSyncOutcome {
        guard let sourceWork = beginSourcePersistenceWork(for: source) else {
            return staleSourceOutcome(for: source, publishFailure: true)
        }
        defer { dependencies.finishSourcePersistenceWork(sourceWork.lease) }

        let shouldPublishGlobalSyncState = publishGlobalSyncState && !dependencies.isSyncing()
        if shouldPublishGlobalSyncState {
            dependencies.setIsSyncing(true)
        }
        defer {
            if shouldPublishGlobalSyncState {
                dependencies.setIsSyncing(false)
            }
        }

        let overallStart = CFAbsoluteTimeGetCurrent()
        let currentConnectionState = dependencies.statusForSource(source)?.connectionState ?? .unknown
        let previousStatus = dependencies.statusForSource(source)
        var libraryResult: LibrarySyncResult?
        dependencies.setStatus(
            source,
            MusicSourceStatus(syncStatus: .syncing(progress: 0), connectionState: currentConnectionState)
        )

        do {
            let timestamp = lastSyncDate.timeIntervalSince1970 - 5
            libraryResult = try await provider.syncLibraryIncremental(
                since: timestamp,
                to: dependencies.libraryRepository,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        guard dependencies.isSourcePersistenceWorkCurrent(
                            source,
                            sourceWork.revision,
                            sourceWork.lease
                        ) else { return }
                        dependencies.publishProgress(source, progress * 0.9)
                    }
                }
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            await dependencies.processReparentedTracks()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            await dependencies.processArtworkInvalidations()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            let playlistPhaseStart = CFAbsoluteTimeGetCurrent()
            let playlistResult = try await syncPlaylistsIfNeeded(
                provider: provider,
                source: source,
                enabled: shouldSyncPlaylists,
                incremental: true,
                progressBase: 0.9,
                progressWeight: 0.1,
                sourceWork: sourceWork
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            if logTimings, playlistResult != nil {
                EnsembleLogger.debug(
                    "⏱️ SyncCoordinator: playlist phase took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistPhaseStart))s"
                )
            }

            await dependencies.processArtworkInvalidations()
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }

            if cacheArtworkAfterSync {
                await dependencies.cacheAlbumArtwork(source, provider)
                guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                    return staleSourceOutcome(for: source)
                }
                await dependencies.cacheArtistArtwork(source, provider)
                guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                    return staleSourceOutcome(for: source)
                }
                await dependencies.cachePlaylistArtwork(source, provider)
                guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                    return staleSourceOutcome(for: source)
                }
            }

            if notifyPlaylistRefreshAfterSync, playlistResult != nil {
                dependencies.notifyPlaylistRefreshCompleted(serverSourceKey(for: source))
            }

            if logTimings {
                EnsembleLogger.debug(
                    "⏱️ SyncCoordinator: incremental sync total \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - overallStart))s for \(source.compositeKey)"
                )
            }

            let syncedAt = Date()
            let resolvedConnectionState = await dependencies.connectionStateAfterSuccessfulSync(
                source,
                currentConnectionState
            )
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            dependencies.markSourceSyncCompleted(source)
            dependencies.setStatus(
                source,
                MusicSourceStatus(syncStatus: .lastSynced(syncedAt), connectionState: resolvedConnectionState)
            )
            dependencies.publishContentChange(source, libraryResult, playlistResult, syncedAt)
            dependencies.postSiriRebuildRequest()
            return .success
        } catch is CancellationError {
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            publishCommittedLibraryChangesIfNeeded(libraryResult, source: source)
            dependencies.restoreStatusAfterCancellation(source, previousStatus, currentConnectionState)
            return .failure(message: "Sync was cancelled.")
        } catch {
            guard isSourcePersistenceWorkCurrent(sourceWork, for: source) else {
                return staleSourceOutcome(for: source)
            }
            publishCommittedLibraryChangesIfNeeded(libraryResult, source: source)
            let message = dependencies.syncErrorMessage(error)
            dependencies.setStatus(
                source,
                MusicSourceStatus(
                    syncStatus: .error(message),
                    connectionState: dependencies.effectiveConnectionState(currentConnectionState)
                )
            )
            return .failure(message: message)
        }
    }

    private func syncPlaylistsIfNeeded(
        provider: MusicSourceSyncProvider,
        source: MusicSourceIdentifier,
        enabled: Bool,
        incremental: Bool,
        progressBase: Double,
        progressWeight: Double,
        sourceWork: (revision: SourceProviderRevision, lease: SourcePersistenceLease)
    ) async throws -> PlaylistSyncResult? {
        guard enabled else { return nil }

        if incremental {
            return try await provider.syncPlaylistsIncremental(
                to: dependencies.playlistRepository,
                forceOrphanCheck: false,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        guard dependencies.isSourcePersistenceWorkCurrent(
                            source,
                            sourceWork.revision,
                            sourceWork.lease
                        ) else { return }
                        dependencies.publishProgress(source, progressBase + (progress * progressWeight))
                    }
                }
            )
        }

        return try await provider.syncPlaylists(
            to: dependencies.playlistRepository,
            progressHandler: { [dependencies] progress in
                Task { @MainActor in
                    guard dependencies.isSourcePersistenceWorkCurrent(
                        source,
                        sourceWork.revision,
                        sourceWork.lease
                    ) else { return }
                    dependencies.publishProgress(source, progressBase + (progress * progressWeight))
                }
            }
        )
    }

    private func beginSourcePersistenceWork(
        for source: MusicSourceIdentifier
    ) -> (revision: SourceProviderRevision, lease: SourcePersistenceLease)? {
        guard let revision = dependencies.providerRevision(source),
              let lease = dependencies.beginSourcePersistenceWork(source, revision) else {
            return nil
        }
        return (revision, lease)
    }

    private func isSourcePersistenceWorkCurrent(
        _ work: (revision: SourceProviderRevision, lease: SourcePersistenceLease),
        for source: MusicSourceIdentifier
    ) -> Bool {
        dependencies.isSourcePersistenceWorkCurrent(source, work.revision, work.lease)
    }

    private func staleSourceOutcome(
        for source: MusicSourceIdentifier,
        publishFailure: Bool = false
    ) -> MusicSourceSyncOutcome {
        let message = "The music source changed while syncing. Please try again."
        EnsembleLogger.debug("⏹️ Ignoring stale sync work for \(source.compositeKey)")
        if publishFailure {
            dependencies.publishPreflightFailure(source, message)
        }
        return .failure(message: message)
    }

    private func serverSourceKey(for source: MusicSourceIdentifier) -> String {
        MediaSourceIdentity.serverSourceKey(for: source)
    }
}
