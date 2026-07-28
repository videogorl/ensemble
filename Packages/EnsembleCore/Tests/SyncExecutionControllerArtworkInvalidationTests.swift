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

    private final class RecordingProvider: MusicSourceSyncProvider, @unchecked Sendable {
        let sourceIdentifier: MusicSourceIdentifier
        private let recorder: EventRecorder
        private let syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?
        private let syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)?

        init(
            sourceIdentifier: MusicSourceIdentifier,
            recorder: EventRecorder,
            syncPlaylistsHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil,
            syncPlaylistsIncrementalHandler: (@Sendable (PlaylistRepositoryProtocol) async throws -> PlaylistSyncResult)? = nil
        ) {
            self.sourceIdentifier = sourceIdentifier
            self.recorder = recorder
            self.syncPlaylistsHandler = syncPlaylistsHandler
            self.syncPlaylistsIncrementalHandler = syncPlaylistsIncrementalHandler
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult {
            progressHandler(1)
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
        let controller = makeController(source: source, recorder: recorder)

        let outcome = await controller.sync(source: source, providers: [:])
        let events = await recorder.snapshot()

        XCTAssertEqual(outcome, .failure(message: "The music source is unavailable. Please try again."))
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
        publishContentChange: @escaping (
            MusicSourceIdentifier,
            LibrarySyncResult?,
            PlaylistSyncResult?,
            Date
        ) -> Void = { _, _, _, _ in }
    ) -> SyncExecutionController {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = providedLibraryRepository ?? LibraryRepository(coreDataStack: stack)
        let playlistRepository = providedPlaylistRepository ?? PlaylistRepository(coreDataStack: stack)
        var isSyncing = false
        var statuses: [MusicSourceIdentifier: MusicSourceStatus] = [:]

        return SyncExecutionController(
            dependencies: SyncExecutionController.Dependencies(
                libraryRepository: libraryRepository,
                playlistRepository: playlistRepository,
                isSyncing: { isSyncing },
                setIsSyncing: { isSyncing = $0 },
                isOffline: { false },
                statusForSource: { statuses[$0] },
                setStatus: { statuses[$0] = $1 },
                loadLastSyncDate: { _ in Date(timeIntervalSince1970: 1_000) },
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
                setLastStartupSyncCompletion: { _ in }
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
