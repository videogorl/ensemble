import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class SyncExecutionControllerArtworkInvalidationTests: XCTestCase {
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
        private let syncLibraryHandler: (@Sendable () async throws -> LibrarySyncResult)?
        private let syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?
        private let syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?

        init(
            sourceIdentifier: MusicSourceIdentifier,
            recorder: EventRecorder,
            syncLibraryHandler: (@Sendable () async throws -> LibrarySyncResult)? = nil,
            syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil,
            syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.recorder = recorder
            self.syncLibraryHandler = syncLibraryHandler
            self.syncPlaylistsHandler = syncPlaylistsHandler
            self.syncPlaylistsIncrementalHandler = syncPlaylistsIncrementalHandler
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            if let syncLibraryHandler {
                return try await syncLibraryHandler()
            }
            await recorder.record("library")
            return LibrarySyncResult(changedAlbums: 1)
        }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
            await recorder.record("library-incremental")
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
            nil
        }

        func rateTrack(ratingKey: String, rating: Int?) async throws {}
        func reportTimeline(ratingKey: String, key: String, state: String, time: Int, duration: Int) async throws {}
        func scrobble(ratingKey: String) async throws {}
        func getAlbumTracks(albumKey: String) async throws -> [Track] { [] }
        func getArtistAlbums(artistKey: String) async throws -> [Album] { [] }
        func getArtistTracks(artistKey: String) async throws -> [Track] { [] }
    }

    func testFullSyncProcessesArtworkInvalidationsAroundPlaylistPhase() async throws {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(sourceIdentifier: source, recorder: recorder)
        var completedSources: [MusicSourceIdentifier] = []
        let controller = makeController(
            source: source,
            recorder: recorder,
            markSourceSyncCompleted: { completedSources.append($0) }
        )

        let outcome = await controller.sync(source: source, providers: [source.compositeKey: provider])

        let events = await recorder.snapshot()
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(completedSources, [source])
        XCTAssertEqual(events, ["library", "reparent", "artwork", "playlists", "artwork"])
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

    func testDelayedOldProviderCompletionIsDiscardedAfterSameKeyRemoveAndReadd() async {
        let sources = [
            MusicSourceIdentifier.appleMusic,
            makeSourceIdentifier(),
        ]

        for source in sources {
            let recorder = EventRecorder()
            let gate = AsyncGate()
            let oldRevision = SourceProviderRevision(sourceConfiguration: 1, providerRegistration: 1)
            var currentRevision = oldRevision
            var completedSources: [MusicSourceIdentifier] = []
            var publishedChanges = 0
            let provider = RecordingProvider(
                sourceIdentifier: source,
                recorder: recorder,
                syncLibraryHandler: {
                    await gate.enterAndWait()
                    await recorder.record("delayed-library-write")
                    return LibrarySyncResult(changedAlbums: 1)
                }
            )
            let controller = makeController(
                source: source,
                recorder: recorder,
                markSourceSyncCompleted: { completedSources.append($0) },
                providerRevision: oldRevision,
                isProviderRevisionCurrent: { $0 == currentRevision },
                publishContentChange: { _, _, _, _ in publishedChanges += 1 }
            )

            let syncTask = Task {
                await controller.sync(source: source, providers: [source.compositeKey: provider])
            }
            await gate.waitUntilEntered()

            // Removal and re-add keep the composite key but advance its source generation.
            currentRevision = SourceProviderRevision(sourceConfiguration: 3, providerRegistration: 3)
            await gate.release()

            let outcome = await syncTask.value
            let events = await recorder.snapshot()
            XCTAssertEqual(
                outcome,
                .failure(message: "The music source changed while syncing. Please try again."),
                source.compositeKey
            )
            XCTAssertEqual(events, ["delayed-library-write"], source.compositeKey)
            XCTAssertTrue(completedSources.isEmpty, source.compositeKey)
            XCTAssertEqual(publishedChanges, 0, source.compositeKey)
        }
    }

    func testSingleSourceSyncReturnsPlaylistFailureToCaller() async throws {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(
            sourceIdentifier: source,
            recorder: recorder,
            syncPlaylistsHandler: { _ in throw TestError.playlistSync }
        )
        var completedSources: [MusicSourceIdentifier] = []
        var publishedLibraryResult: LibrarySyncResult?
        var publishedPlaylistResult: PlaylistSyncResult?
        let controller = makeController(
            source: source,
            recorder: recorder,
            markSourceSyncCompleted: { completedSources.append($0) },
            publishContentChange: { _, libraryResult, playlistResult, _ in
                publishedLibraryResult = libraryResult
                publishedPlaylistResult = playlistResult
            }
        )

        let outcome = await controller.sync(source: source, providers: [source.compositeKey: provider])
        let events = await recorder.snapshot()

        XCTAssertEqual(outcome, .failure(message: "Apple Music playlist body failed."))
        XCTAssertTrue(completedSources.isEmpty)
        XCTAssertEqual(publishedLibraryResult?.changedAlbums, 1)
        XCTAssertNil(publishedPlaylistResult)
        XCTAssertEqual(events, ["library", "reparent", "artwork", "playlists"])
    }

    func testSingleSourceSyncReturnsFailureWhenProviderIsUnavailable() async {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        var publishedFailure: (source: MusicSourceIdentifier, message: String)?
        let controller = makeController(
            source: source,
            recorder: recorder,
            publishPreflightFailure: { publishedFailure = ($0, $1) }
        )

        let outcome = await controller.sync(source: source, providers: [:])
        let events = await recorder.snapshot()

        XCTAssertEqual(outcome, .failure(message: "The music source is unavailable. Please try again."))
        XCTAssertEqual(publishedFailure?.source, source)
        XCTAssertEqual(publishedFailure?.message, "The music source is unavailable. Please try again.")
        XCTAssertTrue(events.isEmpty)
    }

    func testSingleSourceSyncPublishesStalePreflightFailure() async {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(sourceIdentifier: source, recorder: recorder)
        var publishedFailure: (source: MusicSourceIdentifier, message: String)?
        let controller = makeController(
            source: source,
            recorder: recorder,
            isProviderRevisionCurrent: { _ in false },
            publishPreflightFailure: { publishedFailure = ($0, $1) }
        )

        let outcome = await controller.sync(
            source: source,
            providers: [source.compositeKey: provider]
        )

        let expectedMessage = "The music source changed while syncing. Please try again."
        let events = await recorder.snapshot()
        XCTAssertEqual(outcome, .failure(message: expectedMessage))
        XCTAssertEqual(publishedFailure?.source, source)
        XCTAssertEqual(publishedFailure?.message, expectedMessage)
        XCTAssertTrue(events.isEmpty)
    }

    func testIncrementalSyncProcessesArtworkInvalidationsAfterPlaylistPhaseBeforeArtworkCaching() async throws {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(sourceIdentifier: source, recorder: recorder)
        var completedSources: [MusicSourceIdentifier] = []
        let controller = makeController(
            source: source,
            recorder: recorder,
            markSourceSyncCompleted: { completedSources.append($0) }
        )

        await controller.syncIncremental(source: source, providers: [source.compositeKey: provider])

        let events = await recorder.snapshot()
        XCTAssertEqual(completedSources, [source])
        XCTAssertEqual(
            events,
            [
                "library-incremental",
                "reparent",
                "artwork",
                "playlists-incremental",
                "artwork",
                "cache-albums",
                "cache-artists",
                "cache-playlists"
            ]
        )
    }

    func testIncrementalSyncPublishesCommittedLibraryChangesWhenPlaylistSyncFails() async {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(
            sourceIdentifier: source,
            recorder: recorder,
            syncPlaylistsIncrementalHandler: { _ in throw TestError.playlistSync }
        )
        var completedSources: [MusicSourceIdentifier] = []
        var publishedLibraryResult: LibrarySyncResult?
        let controller = makeController(
            source: source,
            recorder: recorder,
            markSourceSyncCompleted: { completedSources.append($0) },
            publishContentChange: { _, libraryResult, _, _ in
                publishedLibraryResult = libraryResult
            }
        )

        await controller.syncIncremental(source: source, providers: [source.compositeKey: provider])
        let events = await recorder.snapshot()

        XCTAssertTrue(completedSources.isEmpty)
        XCTAssertEqual(publishedLibraryResult?.changedAlbums, 1)
        XCTAssertEqual(
            events,
            ["library-incremental", "reparent", "artwork", "playlists-incremental"]
        )
    }

    func testSyncAllDrainsPlaylistInvalidationAndRecachesPlaylistArtworkAfterPlaylistPhase() async throws {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)

        _ = try await upsertPlaylist(
            in: playlistRepository,
            compositePath: "/playlists/playlist-1/composite/old",
            dateModified: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(playlistRepository.drainArtworkInvalidationInfo().isEmpty)

        let provider = RecordingProvider(
            sourceIdentifier: source,
            recorder: recorder,
            syncPlaylistsHandler: { repository in
                _ = try await repository.upsertPlaylist(
                    ratingKey: "playlist-1",
                    key: "/playlists/playlist-1",
                    title: "Playlist One",
                    summary: nil,
                    compositePath: "/playlists/playlist-1/composite/new",
                    isSmart: false,
                    duration: nil,
                    trackCount: 0,
                    dateAdded: nil,
                    dateModified: Date(timeIntervalSince1970: 1_001),
                    lastPlayed: nil,
                    sourceCompositeKey: "plex/account/server"
                )
                return PlaylistSyncResult(changedPlaylists: 1)
            }
        )
        let controller = makeController(
            source: source,
            recorder: recorder,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            processArtworkInvalidations: {
                let invalidations = libraryRepository.drainArtworkInvalidationInfo()
                    + playlistRepository.drainArtworkInvalidationInfo()
                guard !invalidations.isEmpty else { return }

                let typeSummary = invalidations
                    .map { $0.type.rawValue }
                    .sorted()
                    .joined(separator: ",")
                await recorder.record("artwork-\(typeSummary)")
            },
            recordWholeSourceArtworkCache: true
        )

        await controller.syncAll(providers: [source.compositeKey: provider])

        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [
                "library",
                "reparent",
                "cache-source",
                "playlists",
                "artwork-playlist",
                "cache-playlists"
            ]
        )
    }

    func testSyncAllKeepsPlaylistDeduplicationProviderScoped() async {
        let recorder = EventRecorder()
        let plexSource = makeSourceIdentifier()
        let appleSource = MusicSourceIdentifier(
            type: .appleMusic,
            accountId: plexSource.accountId,
            serverId: plexSource.serverId,
            libraryId: "library-2"
        )
        let providers = [plexSource, appleSource].map {
            RecordingProvider(sourceIdentifier: $0, recorder: recorder)
        }
        let controller = makeController(source: plexSource, recorder: recorder)

        await controller.syncAll(
            providers: Dictionary(uniqueKeysWithValues: providers.map { ($0.sourceIdentifier.compositeKey, $0) })
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events.filter { $0 == "playlists" }.count, 2)
    }

    func testIncrementalAllFullFallbackSyncsSingleSourcePlaylists() async {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let provider = RecordingProvider(sourceIdentifier: source, recorder: recorder)
        let controller = makeController(
            source: source,
            recorder: recorder,
            loadLastSyncDate: { _ in nil }
        )

        await controller.syncAllIncremental(providers: [source.compositeKey: provider])

        let events = await recorder.snapshot()
        XCTAssertEqual(events.filter { $0 == "library" }.count, 1)
        XCTAssertEqual(events.filter { $0 == "playlists" }.count, 1)
    }

    func testIncrementalAllFullFallbackSyncsPlaylistsOncePerServer() async {
        let recorder = EventRecorder()
        let firstSource = makeSourceIdentifier()
        let secondSource = MusicSourceIdentifier(
            type: .plex,
            accountId: firstSource.accountId,
            serverId: firstSource.serverId,
            libraryId: "library-2"
        )
        let providers = [firstSource, secondSource].map {
            RecordingProvider(sourceIdentifier: $0, recorder: recorder)
        }
        let controller = makeController(
            source: firstSource,
            recorder: recorder,
            loadLastSyncDate: { _ in nil }
        )

        await controller.syncAllIncremental(
            providers: Dictionary(uniqueKeysWithValues: providers.map { ($0.sourceIdentifier.compositeKey, $0) })
        )

        let events = await recorder.snapshot()
        XCTAssertEqual(events.filter { $0 == "library" }.count, 2)
        XCTAssertEqual(events.filter { $0 == "playlists" }.count, 1)
    }

    func testIncrementalSyncDrainsPlaylistInvalidationBeforePlaylistArtworkCaching() async throws {
        let recorder = EventRecorder()
        let source = makeSourceIdentifier()
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)

        _ = try await upsertPlaylist(
            in: playlistRepository,
            compositePath: "/playlists/playlist-1/composite",
            dateModified: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertTrue(playlistRepository.drainArtworkInvalidationInfo().isEmpty)

        let provider = RecordingProvider(
            sourceIdentifier: source,
            recorder: recorder,
            syncPlaylistsIncrementalHandler: { repository in
                _ = try await repository.upsertPlaylist(
                    ratingKey: "playlist-1",
                    key: "/playlists/playlist-1",
                    title: "Playlist One",
                    summary: nil,
                    compositePath: "/playlists/playlist-1/composite",
                    isSmart: false,
                    duration: nil,
                    trackCount: 0,
                    dateAdded: nil,
                    dateModified: Date(timeIntervalSince1970: 1_001),
                    lastPlayed: nil,
                    sourceCompositeKey: "plex/account/server"
                )
                return PlaylistSyncResult(changedPlaylists: 1)
            }
        )
        let controller = makeController(
            source: source,
            recorder: recorder,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            processArtworkInvalidations: {
                let invalidations = libraryRepository.drainArtworkInvalidationInfo()
                    + playlistRepository.drainArtworkInvalidationInfo()
                guard !invalidations.isEmpty else { return }

                let typeSummary = invalidations
                    .map { $0.type.rawValue }
                    .sorted()
                    .joined(separator: ",")
                await recorder.record("artwork-\(typeSummary)")
            }
        )

        await controller.syncIncremental(source: source, providers: [source.compositeKey: provider])

        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            [
                "library-incremental",
                "reparent",
                "playlists-incremental",
                "artwork-playlist",
                "cache-albums",
                "cache-artists",
                "cache-playlists"
            ]
        )
    }

    private func makeSourceIdentifier() -> MusicSourceIdentifier {
        MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "library-1"
        )
    }

    private func makeController(
        source: MusicSourceIdentifier,
        recorder: EventRecorder,
        libraryRepository providedLibraryRepository: LibraryRepositoryProtocol? = nil,
        playlistRepository providedPlaylistRepository: PlaylistRepositoryProtocol? = nil,
        processArtworkInvalidations providedProcessArtworkInvalidations: (() async -> Void)? = nil,
        recordWholeSourceArtworkCache: Bool = false,
        markSourceSyncCompleted: @escaping (MusicSourceIdentifier) -> Void = { _ in },
        loadLastSyncDate: @escaping (MusicSourceIdentifier) async -> Date? = { _ in
            Date(timeIntervalSince1970: 1_000)
        },
        providerRevision: SourceProviderRevision = SourceProviderRevision(
            sourceConfiguration: 1,
            providerRegistration: 1
        ),
        isProviderRevisionCurrent: @escaping (SourceProviderRevision) -> Bool = { _ in true },
        publishContentChange: @escaping (
            MusicSourceIdentifier,
            LibrarySyncResult?,
            PlaylistSyncResult?,
            Date
        ) -> Void = { _, _, _, _ in },
        publishPreflightFailure: @escaping (MusicSourceIdentifier, String) -> Void = { _, _ in }
    ) -> SyncExecutionController {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = providedLibraryRepository ?? LibraryRepository(coreDataStack: stack)
        let playlistRepository = providedPlaylistRepository ?? PlaylistRepository(coreDataStack: stack)
        var isSyncing = false
        var statuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]
        let sourcePersistenceFence = SourcePersistenceFence()

        return SyncExecutionController(
            dependencies: SyncExecutionController.Dependencies(
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                isSyncing: { isSyncing },
                setIsSyncing: { isSyncing = $0 },
                isOffline: { false },
                statusForSource: { statuses[$0] },
                setStatus: { statuses[$0] = $1 },
                loadLastSyncDate: loadLastSyncDate,
                removeDuplicatePlaylists: {},
                publishProgress: { _, _ in },
                processReparentedTracks: {
                    await recorder.record("reparent")
                },
                processArtworkInvalidations: providedProcessArtworkInvalidations ?? {
                    await recorder.record("artwork")
                },
                cacheArtworkForSource: { _, _ in
                    if recordWholeSourceArtworkCache {
                        await recorder.record("cache-source")
                    }
                },
                cacheAlbumArtwork: { _, _ in
                    await recorder.record("cache-albums")
                },
                cacheArtistArtwork: { _, _ in
                    await recorder.record("cache-artists")
                },
                cachePlaylistArtwork: { _, _ in
                    await recorder.record("cache-playlists")
                },
                notifyPlaylistRefreshCompleted: { _ in },
                connectionStateAfterSuccessfulSync: { _, state in state },
                markSourceSyncCompleted: markSourceSyncCompleted,
                publishContentChange: publishContentChange,
                restoreStatusAfterCancellation: { source, status, connectionState in
                    statuses[source] = status ?? MusicSourceStatus(connectionState: connectionState)
                },
                syncErrorMessage: { $0.localizedDescription },
                effectiveConnectionState: { $0 },
                postSiriRebuildRequest: {},
                sourceNeedsGenreMetadataRepair: { _ in false },
                runStartupHealthChecksIfNeeded: { _, _ in false },
                enabledServerKeysForHealthChecks: { [] },
                isCheckingHealth: { false },
                lastHealthCheckCompletion: { nil },
                updateSourceConnectionStates: {},
                setLastStartupSyncCompletion: { _ in },
                providerRevision: { _ in providerRevision },
                beginSourcePersistenceWork: { _, revision in
                    guard isProviderRevisionCurrent(revision) else { return nil }
                    return sourcePersistenceFence.begin(sourceKey: source.compositeKey)
                },
                isSourcePersistenceWorkCurrent: { _, revision, lease in
                    isProviderRevisionCurrent(revision) && sourcePersistenceFence.isCurrent(lease)
                },
                finishSourcePersistenceWork: { sourcePersistenceFence.finish($0) },
                runSourceSync: { _, operation in await operation() },
                publishPreflightFailure: publishPreflightFailure
            )
        )
    }

    @discardableResult
    private func upsertPlaylist(
        in repository: PlaylistRepositoryProtocol,
        compositePath: String?,
        dateModified: Date?
    ) async throws -> CDPlaylist {
        try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Playlist One",
            summary: nil,
            compositePath: compositePath,
            isSmart: false,
            duration: nil,
            trackCount: 0,
            dateAdded: nil,
            dateModified: dateModified,
            lastPlayed: nil,
            sourceCompositeKey: "plex/account/server"
        )
    }

}
