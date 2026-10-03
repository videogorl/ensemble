import XCTest
import CoreData
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class SyncCoordinatorExecutionTests: XCTestCase {
    private enum TestError: LocalizedError {
        case unused
        case playlistSync

        var errorDescription: String? {
            switch self {
            case .unused: "Unused test error."
            case .playlistSync: "Apple Music playlist body failed."
            }
        }
    }

    private actor EventRecorder {
        private var events: [String] = []

        func record(_ event: String) {
            events.append(event)
        }

        func snapshot() -> [String] {
            events
        }
    }

    private actor AsyncGate {
        private var didEnter = false
        private var entryWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func enterAndWait() async {
            didEnter = true
            entryWaiters.forEach { $0.resume() }
            entryWaiters.removeAll()
            await withCheckedContinuation { releaseContinuation = $0 }
        }

        func waitUntilEntered() async {
            guard !didEnter else { return }
            await withCheckedContinuation { entryWaiters.append($0) }
        }

        func release() {
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class RecordingProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        private let recorder: EventRecorder
        private let syncLibraryHandler: (@Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult)?
        private let syncLibraryIncrementalHandler: (@Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult)?
        private let syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?
        private let syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?

        init(
            sourceIdentifier: MusicSourceIdentifier,
            recorder: EventRecorder,
            syncLibraryHandler: (@Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult)? = nil,
            syncLibraryIncrementalHandler: (@Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult)? = nil,
            syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil,
            syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.recorder = recorder
            self.syncLibraryHandler = syncLibraryHandler
            self.syncLibraryIncrementalHandler = syncLibraryIncrementalHandler
            self.syncPlaylistsHandler = syncPlaylistsHandler
            self.syncPlaylistsIncrementalHandler = syncPlaylistsIncrementalHandler
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            await recorder.record("library")
            if let syncLibraryHandler {
                return try await syncLibraryHandler(repository)
            }
            return LibrarySyncResult(changedAlbums: 1)
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            await recorder.record("library-incremental")
            if let syncLibraryIncrementalHandler {
                return try await syncLibraryIncrementalHandler(repository)
            }
            return LibrarySyncResult(changedAlbums: 1)
        }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1)
            await recorder.record("playlists")
            if let syncPlaylistsHandler {
                return try await syncPlaylistsHandler(repository)
            }
            return PlaylistSyncResult()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            progressHandler(1)
            await recorder.record("playlists-incremental")
            if let syncPlaylistsIncrementalHandler {
                return try await syncPlaylistsIncrementalHandler(repository)
            }
            return PlaylistSyncResult()
        }

        func getStreamURL(
            for trackRatingKey: String,
            trackStreamKey: String?,
            quality: StreamingQuality,
            metadataDurationSeconds: Double?
        ) async throws -> StreamResolution {
            throw TestError.unused
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? {
            URL(string: "https://example.com\(path ?? "/artwork")")
        }

        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    func testSourcePersistenceFenceDrainsWorkAndBlocksUntilCleanupFinishes() async throws {
        let fence = SourcePersistenceFence()
        let sourceKey = "plex:account:server:library"
        let activeLease = try XCTUnwrap(fence.begin(sourceKey: sourceKey))
        var cleanupEntered = false

        let cleanupTask = Task { @MainActor in
            await fence.beginCleanup(sourceKey: sourceKey)
            cleanupEntered = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(cleanupEntered)
        XCTAssertNil(fence.begin(sourceKey: sourceKey))

        fence.finish(activeLease)
        await cleanupTask.value
        XCTAssertTrue(cleanupEntered)
        XCTAssertNil(
            fence.begin(sourceKey: sourceKey),
            "Cleanup keeps rejecting same-key work while its final purge is running"
        )

        fence.finishCleanup(sourceKey: sourceKey)
        let readdedLease = try XCTUnwrap(fence.begin(sourceKey: sourceKey))
        fence.finish(readdedLease)
    }

    func testServerCleanupFenceDrainsAndBlocksLibraryWork() async throws {
        let fence = SourcePersistenceFence()
        let serverKey = "plex:account:server"
        let libraryKey = "\(serverKey):library"
        let activeLease = try XCTUnwrap(fence.begin(sourceKey: libraryKey))
        var cleanupEntered = false

        let cleanupTask = Task { @MainActor in
            await fence.beginCleanup(sourceKey: serverKey)
            cleanupEntered = true
        }
        for _ in 0..<5 { await Task.yield() }
        XCTAssertFalse(cleanupEntered)
        XCTAssertNil(fence.begin(sourceKey: libraryKey))

        fence.finish(activeLease)
        await cleanupTask.value
        XCTAssertTrue(cleanupEntered)
        XCTAssertNil(fence.begin(sourceKey: libraryKey))

        fence.finishCleanup(sourceKey: serverKey)
        let restoredLease = try XCTUnwrap(fence.begin(sourceKey: libraryKey))
        fence.finish(restoredLease)
    }

    private final class NotificationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    private final class RecordingArtworkDownloadManager: ArtworkDownloadManagerProtocol, @unchecked Sendable {
        let recorder: EventRecorder
        init(recorder: EventRecorder) { self.recorder = recorder }
        func getLocalArtworkPath(for album: CDAlbum) async throws -> String? { nil }
        func getLocalArtworkPath(for artist: CDArtist) async throws -> String? { nil }
        func getLocalArtworkPath(for playlist: CDPlaylist) async throws -> String? { nil }
        func downloadAndCacheArtwork(from url: URL, ratingKey: String, type: ArtworkType) async throws {}
        func downloadAndCacheArtwork(from url: URL, identity: ArtworkIdentity) async throws {
            await recorder.record("cache-\(identity.type.rawValue)-\(identity.sourcePath ?? "")")
        }
        func deleteArtwork(ratingKey: String, type: ArtworkType) {}
        func deleteArtwork(forRatingKeys ratingKeys: Set<String>) {}
        func clearArtworkCache() async throws {}
        func getArtworkCacheSize() async throws -> Int64 { 0 }
    }

    private final class GatedCursorRepository: SyncCursorRepositoryProtocol, @unchecked Sendable {
        let repository: SyncCursorRepository
        let gate: AsyncGate
        init(stack: CoreDataStack, gate: AsyncGate) {
            repository = SyncCursorRepository(coreDataStack: stack)
            self.gate = gate
        }
        func fetchCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws -> SyncCursorRecord? {
            try await repository.fetchCursor(scopeKey: scopeKey, scopeType: scopeType)
        }
        func recordIncrementalSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
            try await repository.recordIncrementalSync(scopeKey: scopeKey, scopeType: scopeType, at: date)
        }
        func recordInventorySync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
            try await repository.recordInventorySync(scopeKey: scopeKey, scopeType: scopeType, at: date)
        }
        func recordFullSync(scopeKey: String, scopeType: SyncCursorScopeType, at date: Date) async throws {
            try await repository.recordFullSync(scopeKey: scopeKey, scopeType: scopeType, at: date)
        }
        func invalidateInventorySync(scopeKey: String, scopeType: SyncCursorScopeType) async throws {
            try await repository.invalidateInventorySync(scopeKey: scopeKey, scopeType: scopeType)
        }
        func deleteCursor(scopeKey: String, scopeType: SyncCursorScopeType) async throws {
            await gate.enterAndWait()
            try await repository.deleteCursor(scopeKey: scopeKey, scopeType: scopeType)
        }
    }

    func testSuccessfulSyncRequestsSiriRebuildOnlyForMaterialChanges() async throws {
        for incremental in [false, true] {
            let stack = CoreDataStack.inMemory()
            let source = makeSourceIdentifier()
            let coordinator = makeCoordinator(stack: stack, sources: [source])
            try await recordPreviousSync(stack: stack, source: source)
            let counter = NotificationCounter()
            let token = NotificationCenter.default.addObserver(
                forName: SiriMediaIndexNotifications.rebuildRequested, object: nil, queue: nil
            ) { notification in
                if notification.userInfo?[SiriMediaIndexNotifications.reasonKey] as? String == "sync_completed" {
                    counter.increment()
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }
            let recorder = EventRecorder()
            let noOp = RecordingProvider(
                sourceIdentifier: source, recorder: recorder,
                syncLibraryHandler: { _ in LibrarySyncResult() },
                syncLibraryIncrementalHandler: { _ in LibrarySyncResult() }
            )
            coordinator.setSyncProvidersForTesting([source.compositeKey: noOp])
            if incremental { await coordinator.syncIncremental(source: source) }
            else { _ = await coordinator.sync(source: source) }
            XCTAssertEqual(counter.count, 0)
            XCTAssertNil(coordinator.lastContentChange)

            let changed = RecordingProvider(
                sourceIdentifier: source, recorder: recorder,
                syncLibraryHandler: { _ in LibrarySyncResult(changedTracks: 1) },
                syncLibraryIncrementalHandler: { _ in LibrarySyncResult(changedTracks: 1) }
            )
            coordinator.setSyncProvidersForTesting([source.compositeKey: changed])
            if incremental { await coordinator.syncIncremental(source: source) }
            else { _ = await coordinator.sync(source: source) }
            XCTAssertEqual(counter.count, 1)
            XCTAssertEqual(coordinator.lastContentChange?.source, source)
            XCTAssertEqual(coordinator.lastContentChange?.libraryResult?.changedTracks, 1)
        }
    }

    func testPlaylistFailurePreservesCommittedLibraryAndTruthfulStatus() async throws {
        for incremental in [false, true] {
            for cancelled in [false, true] {
                let stack = CoreDataStack.inMemory()
                let source = makeSourceIdentifier()
                let previousDate = Date(timeIntervalSince1970: 1000)
                let previousStatus = MusicSourceStatus(syncStatus: .lastSynced(previousDate), connectionState: .connected(url: "https://example.com"))
                let coordinator = makeCoordinator(stack: stack, sources: [source])
                try await recordPreviousSync(stack: stack, source: source)
                let libraryCommit: @Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult = { repository in
                    try await self.upsertAlbums(in: repository, source: source, thumb: "/album/committed")
                    return LibrarySyncResult(changedAlbums: 2)
                }
                let provider = RecordingProvider(
                    sourceIdentifier: source, recorder: EventRecorder(),
                    syncLibraryHandler: libraryCommit,
                    syncLibraryIncrementalHandler: libraryCommit,
                    syncPlaylistsHandler: { _ in
                        if cancelled { throw CancellationError() }
                        throw TestError.playlistSync
                    },
                    syncPlaylistsIncrementalHandler: { _ in
                        if cancelled { throw CancellationError() }
                        throw TestError.playlistSync
                    }
                )
                coordinator.installSyncProviderForTesting(provider, status: previousStatus)
                let counter = NotificationCounter()
                let token = NotificationCenter.default.addObserver(
                    forName: SiriMediaIndexNotifications.rebuildRequested, object: nil, queue: nil
                ) { notification in
                    if notification.userInfo?[SiriMediaIndexNotifications.reasonKey] as? String == "sync_completed" { counter.increment() }
                }
                defer { NotificationCenter.default.removeObserver(token) }
                if incremental { await coordinator.syncIncremental(source: source) }
                else {
                    let outcome = await coordinator.sync(source: source)
                    XCTAssertEqual(outcome, .failure(message: cancelled ? "Sync was cancelled." : TestError.playlistSync.localizedDescription))
                }
                XCTAssertEqual(coordinator.lastContentChange?.libraryResult?.changedAlbums, 2)
                XCTAssertNil(coordinator.lastContentChange?.playlistResult)
                XCTAssertEqual(counter.count, 1)
                let albums = try await LibraryRepository(coreDataStack: stack).fetchAlbums(forSource: source.compositeKey)
                XCTAssertEqual(Set(albums.map(\.ratingKey)), ["album-old", "album-new"])
                if cancelled { XCTAssertEqual(coordinator.sourceStatuses[source]?.syncStatus, previousStatus.syncStatus) }
                else { XCTAssertEqual(coordinator.sourceStatuses[source]?.syncStatus, .error(TestError.playlistSync.localizedDescription)) }
            }
        }
    }

    func testDelayedOldProviderCompletionIsDiscardedAfterSameKeyReplacement() async {
        for source in [makeSourceIdentifier(), .appleMusic] {
            let recorder = EventRecorder()
            let gate = AsyncGate()
            let coordinator = makeCoordinator(sources: [source])
            let old = RecordingProvider(
                sourceIdentifier: source, recorder: recorder,
                syncLibraryHandler: { _ in
                    await gate.enterAndWait()
                    return LibrarySyncResult(changedAlbums: 1)
                }
            )
            coordinator.setSyncProvidersForTesting([source.compositeKey: old])
            let task = Task { await coordinator.sync(source: source) }
            await gate.waitUntilEntered()
            let replacement = RecordingProvider(sourceIdentifier: source, recorder: EventRecorder())
            coordinator.setSyncProvidersForTesting([source.compositeKey: replacement])
            await gate.release()
            let outcome = await task.value
            XCTAssertEqual(outcome, .failure(message: "The music source changed while syncing. Please try again."))
            XCTAssertNil(coordinator.lastContentChange)
            let events = await recorder.snapshot()
            XCTAssertEqual(events, ["library"])
        }
    }

    func testStartupKeepsCapturedProviderAcrossHealthAndFallback() async throws {
        for hasPreviousSync in [false, true] {
            let stack = CoreDataStack.inMemory()
            let source = makeSourceIdentifier()
            let coordinator = makeCoordinator(stack: stack, sources: [source])
            if hasPreviousSync { try await recordPreviousSync(stack: stack, source: source) }
            let recorder = EventRecorder()
            let old = RecordingProvider(sourceIdentifier: source, recorder: recorder)
            coordinator.setSyncProvidersForTesting([source.compositeKey: old])
            let healthGate = AsyncGate()
            coordinator.healthCheckRunnerForTesting = { _, _ in
                await healthGate.enterAndWait()
                return ServerHealthChecker.CheckSummary(checkedCount: 1, skippedCount: 0)
            }
            let task = Task { await coordinator.performStartupSync() }
            await healthGate.waitUntilEntered()
            coordinator.setSyncProvidersForTesting([
                source.compositeKey: RecordingProvider(sourceIdentifier: source, recorder: recorder)
            ])
            await healthGate.release()
            await task.value
            let events = await recorder.snapshot()
            XCTAssertTrue(events.isEmpty)
            XCTAssertEqual(coordinator.sourceStatuses[source]?.syncStatus, .error("The music source changed while syncing. Please try again."))
        }
    }

    func testReconciliationPreparationFinishesBeforeProviderCapture() async throws {
        for startup in [false, true] {
            let stack = CoreDataStack.inMemory()
            let source = makeSourceIdentifier()
            let gate = AsyncGate()
            let cursors = GatedCursorRepository(stack: stack, gate: gate)
            let coordinator = makeCoordinator(stack: stack, sources: [source], cursors: cursors)
            let oldRecorder = EventRecorder()
            let newRecorder = EventRecorder()
            coordinator.setSyncProvidersForTesting([
                source.compositeKey: RecordingProvider(sourceIdentifier: source, recorder: oldRecorder)
            ])
            let task = Task {
                if startup { await coordinator.performStartupSync() }
                else { await coordinator.syncAllIncremental(reconcileMissedPlexEvents: true) }
            }
            await gate.waitUntilEntered()
            coordinator.setSyncProvidersForTesting([
                source.compositeKey: RecordingProvider(sourceIdentifier: source, recorder: newRecorder)
            ])
            await gate.release()
            await task.value
            let oldEvents = await oldRecorder.snapshot()
            let newEvents = await newRecorder.snapshot()
            XCTAssertTrue(oldEvents.isEmpty)
            XCTAssertEqual(newEvents.filter { $0 == "library" }.count, 1)
            XCTAssertEqual(newEvents.filter { $0 == "playlists" }.count, 1)
        }
    }

    func testAllSourcePlaylistDeduplicationKeepsProviderAndAccountScope() async {
        let first = makeSourceIdentifier()
        let sibling = MusicSourceIdentifier(type: .plex, accountId: first.accountId, serverId: first.serverId, libraryId: "library-2")
        let otherAccount = MusicSourceIdentifier(type: .plex, accountId: "account-2", serverId: first.serverId, libraryId: first.libraryId)
        for incremental in [false, true] {
            for sources in [[first, sibling], [first, otherAccount], [first, .appleMusic]] {
                let coordinator = makeCoordinator(sources: sources)
                let recorder = EventRecorder()
                coordinator.setSyncProvidersForTesting(Dictionary(uniqueKeysWithValues: sources.map {
                    ($0.compositeKey, RecordingProvider(sourceIdentifier: $0, recorder: recorder))
                }))
                if incremental { await coordinator.syncAllIncremental() }
                else { await coordinator.syncAll() }
                let events = await recorder.snapshot()
                XCTAssertEqual(events.filter { $0 == "library" }.count, sources.count)
                XCTAssertEqual(events.filter { $0 == "playlists" }.count, sources == [first, sibling] ? 1 : 2)
                XCTAssertFalse(coordinator.isSyncing)
            }
        }
    }

    func testNativeReparentAndArtworkInvalidationsPrecedeRecaching() async throws {
        for incremental in [false, true] {
            let stack = CoreDataStack.inMemory()
            let source = makeSourceIdentifier()
            let library = LibraryRepository(coreDataStack: stack)
            let playlists = PlaylistRepository(coreDataStack: stack)
            try await upsertAlbums(in: library, source: source, thumb: "/album/old")
            try await upsertTrack(in: library, source: source, album: "album-old")
            try await upsertPlaylist(in: playlists, source: source, path: "/playlist/old", modified: 1000)
            XCTAssertTrue(library.drainTrackReparentInfo().isEmpty)
            _ = library.drainArtworkInvalidationInfo()
            XCTAssertTrue(playlists.drainArtworkInvalidationInfo().isEmpty)
            let recorder = EventRecorder()
            let coordinator = makeCoordinator(
                stack: stack, sources: [source],
                library: library, playlists: playlists,
                artwork: RecordingArtworkDownloadManager(recorder: recorder)
            )
            try await recordPreviousSync(stack: stack, source: source)
            coordinator.onTrackAlbumChanged = { changes in
                XCTAssertEqual(changes.map(\.trackRatingKey), ["track"])
                await recorder.record("reparent")
            }
            coordinator.onArtworkMetadataChanged = { changes in
                for change in changes {
                    XCTAssertEqual(change.sourceCompositeKey, change.type == .playlist ? MediaSourceIdentity.serverSourceKey(for: source) : source.compositeKey)
                    await recorder.record("invalidate-\(change.type.rawValue)")
                }
            }
            let libraryUpdate: @Sendable (LibraryRepositoryProtocol) async throws -> LibrarySyncResult = { repository in
                try await self.upsertAlbums(in: repository, source: source, thumb: "/album/new")
                try await self.upsertTrack(in: repository, source: source, album: "album-new")
                return LibrarySyncResult(changedAlbums: 1, changedTracks: 1)
            }
            let playlistUpdate: @Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult = { repository in
                try await self.upsertPlaylist(in: repository, source: source, path: "/playlist/new", modified: 1001)
                return PlaylistSyncResult(changedPlaylists: 1)
            }
            let provider = RecordingProvider(
                sourceIdentifier: source, recorder: recorder,
                syncLibraryHandler: libraryUpdate, syncLibraryIncrementalHandler: libraryUpdate,
                syncPlaylistsHandler: playlistUpdate, syncPlaylistsIncrementalHandler: playlistUpdate
            )
            coordinator.setSyncProvidersForTesting([source.compositeKey: provider])
            if incremental { await coordinator.syncIncremental(source: source) }
            else { await coordinator.syncAll() }
            let events = await recorder.snapshot()
            let libraryPhase = try XCTUnwrap(events.firstIndex(of: incremental ? "library-incremental" : "library"))
            let playlistPhase = try XCTUnwrap(events.firstIndex(of: incremental ? "playlists-incremental" : "playlists"))
            let reparent = try XCTUnwrap(events.firstIndex(of: "reparent"))
            let albumInvalidation = try XCTUnwrap(events.firstIndex(of: "invalidate-album"))
            let playlistInvalidation = try XCTUnwrap(events.firstIndex(of: "invalidate-playlist"))
            let albumCache = try XCTUnwrap(events.firstIndex(of: "cache-album-/album/new"))
            let playlistCache = try XCTUnwrap(events.firstIndex(of: "cache-playlist-/playlist/new"))
            XCTAssertLessThan(libraryPhase, reparent)
            XCTAssertLessThan(reparent, playlistPhase)
            XCTAssertLessThan(albumInvalidation, playlistPhase)
            XCTAssertLessThan(albumInvalidation, albumCache)
            XCTAssertLessThan(playlistPhase, playlistInvalidation)
            XCTAssertLessThan(playlistInvalidation, playlistCache)
            XCTAssertEqual(coordinator.lastContentChange?.source, source)
            XCTAssertTrue(library.drainTrackReparentInfo().isEmpty)
            XCTAssertTrue(library.drainArtworkInvalidationInfo().isEmpty)
            XCTAssertTrue(playlists.drainArtworkInvalidationInfo().isEmpty)
        }
    }

    private func makeSourceIdentifier() -> MusicSourceIdentifier {
        MusicSourceIdentifier(type: .plex, accountId: "account-1", serverId: "server-1", libraryId: "library-1")
    }

    private func makeCoordinator(
        stack: CoreDataStack = .inMemory(),
        sources: [MusicSourceIdentifier],
        library: LibraryRepositoryProtocol? = nil,
        playlists: PlaylistRepositoryProtocol? = nil,
        artwork: ArtworkDownloadManagerProtocol = EmptyArtworkDownloadManager(),
        cursors: SyncCursorRepositoryProtocol? = nil
    ) -> SyncCoordinator {
        let network = NetworkMonitor()
        let accounts = AccountManager(keychain: TestKeychain(), networkMonitor: network)
        for accountID in Set(sources.filter { $0.type == .plex }.map(\.accountId)).sorted() {
            let accountSources = sources.filter { $0.type == .plex && $0.accountId == accountID }
            let servers = Set(accountSources.map(\.serverId)).sorted().map { serverID in
                PlexServerConfig(
                    id: serverID, name: "Server", url: "https://example.com", token: "token",
                    libraries: accountSources.filter { $0.serverId == serverID }.map {
                        PlexLibraryConfig(id: $0.libraryId, key: $0.libraryId, title: "Music", isEnabled: true)
                    }
                )
            }
            accounts.addPlexAccount(PlexAccountConfig(id: accountID, displayTitle: "Test", authToken: "auth", servers: servers))
        }
        let coordinator = SyncCoordinator(
            accountManager: accounts,
            libraryRepository: library ?? LibraryRepository(coreDataStack: stack),
            playlistRepository: playlists ?? PlaylistRepository(coreDataStack: stack),
            syncCursorRepository: cursors,
            artworkDownloadManager: artwork, networkMonitor: network,
            serverHealthChecker: ServerHealthChecker(accountManager: accounts, networkMonitor: network)
        )
        coordinator.healthCheckRunnerForTesting = { _, _ in ServerHealthChecker.CheckSummary(checkedCount: 0, skippedCount: 0) }
        return coordinator
    }

    private func recordPreviousSync(stack: CoreDataStack, source: MusicSourceIdentifier) async throws {
        let repository = LibraryRepository(coreDataStack: stack)
        _ = try await repository.upsertMusicSource(
            compositeKey: source.compositeKey, type: source.type.rawValue,
            accountId: source.accountId, serverId: source.serverId, libraryId: source.libraryId,
            displayName: "Music", accountName: "Test"
        )
        try await repository.updateMusicSourceSyncTimestamp(compositeKey: source.compositeKey)
    }

    private func upsertAlbums(in repository: LibraryRepositoryProtocol, source: MusicSourceIdentifier, thumb: String) async throws {
        try await repository.batchUpsertAlbums(["album-old", "album-new"].map { id in
            AlbumUpsertInput(
                ratingKey: id, key: "/library/metadata/\(id)", title: id,
                artistName: nil, albumArtist: nil, artistRatingKey: nil, summary: nil,
                thumbPath: id == "album-old" ? thumb : nil, artPath: nil, year: nil,
                trackCount: nil, dateAdded: nil, dateModified: Date(timeIntervalSince1970: 1000), rating: nil
            )
        }, sourceCompositeKey: source.compositeKey)
    }

    private func upsertTrack(in repository: LibraryRepositoryProtocol, source: MusicSourceIdentifier, album: String) async throws {
        _ = try await repository.upsertTrack(
            ratingKey: "track", key: "/library/metadata/track", title: "Track",
            artistName: nil, albumName: album, albumRatingKey: album, trackNumber: nil,
            discNumber: nil, duration: nil, thumbPath: nil, streamKey: nil,
            dateAdded: nil, dateModified: nil, lastPlayed: nil, lastRatedAt: nil, rating: nil,
            playCount: nil, genreNames: nil, sourceCompositeKey: source.compositeKey
        )
    }

    @discardableResult
    private func upsertPlaylist(in repository: PlaylistRepositoryProtocol, source: MusicSourceIdentifier, path: String, modified: TimeInterval) async throws -> CDPlaylist {
        try await repository.upsertPlaylist(
            ratingKey: "playlist-1", key: "/playlists/playlist-1", title: "Playlist",
            summary: nil, compositePath: path, isSmart: false, duration: nil,
            trackCount: 0, dateAdded: nil, dateModified: Date(timeIntervalSince1970: modified),
            lastPlayed: nil, sourceCompositeKey: MediaSourceIdentity.serverSourceKey(for: source)
        )
    }
}
