import EnsemblePersistence
import Foundation

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
            let shouldSyncPlaylists = syncedServerKeys.insert("\(source.accountId):\(source.serverId)").inserted
            await syncFullSource(
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
            guard let lastSyncDate = await dependencies.loadLastSyncDate(source) else {
                EnsembleLogger.debug("⚠️ No previous sync found for \(source.compositeKey), performing full sync")
                await syncFullSource(
                    provider,
                    source: source,
                    shouldSyncPlaylists: false,
                    publishGlobalSyncState: false,
                    libraryProgressWeight: 0.9,
                    playlistProgressBase: 0.9,
                    playlistProgressWeight: 0.1,
                    cacheArtworkAfterLibrarySync: false
                )
                continue
            }

            let shouldSyncPlaylists = syncedServerKeys.insert("\(source.accountId):\(source.serverId)").inserted
            await syncIncrementalSource(
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

        await syncIncrementalSource(
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
        guard let provider = providers[source.compositeKey] else {
            let message = "The music source is unavailable. Please try again."
            EnsembleLogger.error("Sync failed for \(source.compositeKey): \(message)")
            return .failure(message: message)
        }
        return await syncFullSource(
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
        dependencies.setStatus(
            source,
            MusicSourceStatus(syncStatus: .syncing(progress: 0), connectionState: currentConnectionState)
        )

        do {
            let libraryResult = try await provider.syncLibrary(
                to: dependencies.libraryRepository,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        dependencies.publishProgress(source, progress * libraryProgressWeight)
                    }
                }
            )

            await dependencies.processReparentedTracks()
            await dependencies.processArtworkInvalidations()

            if cacheArtworkAfterLibrarySync {
                await dependencies.cacheArtworkForSource(source, provider)
            }

            let playlistResult = try await syncPlaylistsIfNeeded(
                provider: provider,
                source: source,
                enabled: shouldSyncPlaylists,
                incremental: false,
                progressBase: playlistProgressBase,
                progressWeight: playlistProgressWeight
            )
            await dependencies.processArtworkInvalidations()

            if cacheArtworkAfterLibrarySync, playlistResult != nil {
                await dependencies.cachePlaylistArtwork(source, provider)
            }

            let syncedAt = Date()
            let resolvedConnectionState = await dependencies.connectionStateAfterSuccessfulSync(
                source,
                currentConnectionState
            )
            dependencies.setStatus(
                source,
                MusicSourceStatus(syncStatus: .lastSynced(syncedAt), connectionState: resolvedConnectionState)
            )
            dependencies.publishContentChange(source, libraryResult, playlistResult, syncedAt)
            dependencies.postSiriRebuildRequest()
            return .success
        } catch is CancellationError {
            dependencies.restoreStatusAfterCancellation(source, previousStatus, currentConnectionState)
            return .failure(message: "Sync was cancelled.")
        } catch {
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

    private func syncIncrementalSource(
        _ provider: MusicSourceSyncProvider,
        source: MusicSourceIdentifier,
        lastSyncDate: Date,
        shouldSyncPlaylists: Bool,
        publishGlobalSyncState: Bool,
        logTimings: Bool,
        cacheArtworkAfterSync: Bool,
        notifyPlaylistRefreshAfterSync: Bool
    ) async {
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
        dependencies.setStatus(
            source,
            MusicSourceStatus(syncStatus: .syncing(progress: 0), connectionState: currentConnectionState)
        )

        do {
            let timestamp = lastSyncDate.timeIntervalSince1970 - 5
            let libraryResult = try await provider.syncLibraryIncremental(
                since: timestamp,
                to: dependencies.libraryRepository,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        dependencies.publishProgress(source, progress * 0.9)
                    }
                }
            )

            await dependencies.processReparentedTracks()
            await dependencies.processArtworkInvalidations()

            let playlistPhaseStart = CFAbsoluteTimeGetCurrent()
            let playlistResult = try await syncPlaylistsIfNeeded(
                provider: provider,
                source: source,
                enabled: shouldSyncPlaylists,
                incremental: true,
                progressBase: 0.9,
                progressWeight: 0.1
            )

            if logTimings, playlistResult != nil {
                EnsembleLogger.debug(
                    "⏱️ SyncCoordinator: playlist phase took \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - playlistPhaseStart))s"
                )
            }

            await dependencies.processArtworkInvalidations()

            if cacheArtworkAfterSync {
                await dependencies.cacheAlbumArtwork(source, provider)
                await dependencies.cacheArtistArtwork(source, provider)
                await dependencies.cachePlaylistArtwork(source, provider)
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
            dependencies.setStatus(
                source,
                MusicSourceStatus(syncStatus: .lastSynced(syncedAt), connectionState: resolvedConnectionState)
            )
            dependencies.publishContentChange(source, libraryResult, playlistResult, syncedAt)
            dependencies.postSiriRebuildRequest()
        } catch is CancellationError {
            dependencies.restoreStatusAfterCancellation(source, previousStatus, currentConnectionState)
        } catch {
            dependencies.setStatus(
                source,
                MusicSourceStatus(
                    syncStatus: .error(dependencies.syncErrorMessage(error)),
                    connectionState: dependencies.effectiveConnectionState(currentConnectionState)
                )
            )
        }
    }

    private func syncPlaylistsIfNeeded(
        provider: MusicSourceSyncProvider,
        source: MusicSourceIdentifier,
        enabled: Bool,
        incremental: Bool,
        progressBase: Double,
        progressWeight: Double
    ) async throws -> PlaylistSyncResult? {
        guard enabled else { return nil }

        if incremental {
            return try await provider.syncPlaylistsIncremental(
                to: dependencies.playlistRepository,
                forceOrphanCheck: false,
                progressHandler: { [dependencies] progress in
                    Task { @MainActor in
                        dependencies.publishProgress(source, progressBase + (progress * progressWeight))
                    }
                }
            )
        }

        return try await provider.syncPlaylists(
            to: dependencies.playlistRepository,
            progressHandler: { [dependencies] progress in
                Task { @MainActor in
                    dependencies.publishProgress(source, progressBase + (progress * progressWeight))
                }
            }
        )
    }

    private func serverSourceKey(for source: MusicSourceIdentifier) -> String {
        MediaSourceIdentity.serverSourceKey(for: source)
    }
}
