import XCTest
import CoreData
@testable import EnsembleCore
import EnsembleAPI
import EnsemblePersistence

@MainActor
final class SyncCoordinatorPlaylistMutationTests: XCTestCase {

    private actor LibraryAddGate {
        private(set) var invocationCount = 0
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var isReleased = false

        func add() async -> MusicSourceLibraryAddOutcome {
            invocationCount += 1
            if !isReleased {
                await withCheckedContinuation { continuations.append($0) }
            }
            return .alreadyPresent
        }

        func release() {
            isReleased = true
            let pending = continuations
            continuations.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private actor PlaylistGate {
        private var started = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        }

        func waitUntilStarted() async {
            if !started { await withCheckedContinuation { startWaiters.append($0) } }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private final class SnapshotWriteRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        let base: PlaylistRepository
        let gate: PlaylistGate
        let fails: Bool

        init(base: PlaylistRepository, gate: PlaylistGate, fails: Bool) {
            self.base = base
            self.gate = gate
            self.fails = fails
        }

        func fetchPlaylists() async throws -> [CDPlaylist] { try await base.fetchPlaylists() }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { try await base.fetchPlaylists(sourceCompositeKey: sourceCompositeKey) }
        func fetchPlaylist(ratingKey: String) async throws -> CDPlaylist? { try await base.fetchPlaylist(ratingKey: ratingKey) }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { try await base.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey) }
        func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { try await base.searchPlaylists(query: query, map: map) }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { try await base.findPlaylistsByTitle(title, sourceCompositeKeys: sourceCompositeKeys) }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist {
            try await base.upsertPlaylist(ratingKey: ratingKey, key: key, title: title, summary: summary, compositePath: compositePath, isSmart: isSmart, duration: duration, trackCount: trackCount, dateAdded: dateAdded, dateModified: dateModified, lastPlayed: lastPlayed, sourceCompositeKey: sourceCompositeKey)
        }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws { try await base.setPlaylistTracks(trackRatingKeys, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey) }
        func setPlaylistTrackSnapshots(_ snapshots: [PlaylistTrackSnapshot], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {
            await gate.wait()
            if fails { throw CocoaError(.fileWriteUnknown) }
            try await base.setPlaylistTrackSnapshots(snapshots, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey)
        }
        func deletePlaylist(ratingKey: String) async throws { try await base.deletePlaylist(ratingKey: ratingKey) }
        func deletePlaylists(sourceCompositeKey: String) async throws { try await base.deletePlaylists(sourceCompositeKey: sourceCompositeKey) }
        func removeDuplicatePlaylists() async throws { try await base.removeDuplicatePlaylists() }
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { try await base.removeOrphanedPlaylists(notIn: validRatingKeys, forSource: sourceKey) }
        func fetchPlaylistTimestamps(forSource sourceKey: String) async throws -> [String: Date] { try await base.fetchPlaylistTimestamps(forSource: sourceKey) }
    }

    private actor RecordingPlaylistProvider: MusicSourceSyncProvider, MusicSourcePlaylistMutating, MusicSourceRatingMutating {
        let sourceIdentifier: MusicSourceIdentifier
        private(set) var events: [String] = []
        private(set) var mutationTrackIDs: [String] = []
        private(set) var mutationTitle: String?
        private(set) var editedMembershipIDs: [String?] = []
        private let createdPlaylist: Playlist?

        init(sourceIdentifier: MusicSourceIdentifier = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-1"
        ), createdPlaylist: Playlist? = nil) {
            self.sourceIdentifier = sourceIdentifier
            self.createdPlaylist = createdPlaylist
        }

        private var loseAcknowledgment = true
        private(set) var acceptedRatings: [String: Int] = [:]
        func restoreAcknowledgments() { loseAcknowledgment = false }
        func ratings() -> [String: Int] { acceptedRatings }
        func rateTrack(_ track: Track, rating: Int?) async throws -> MusicSourceRatingMutationEffects {
            events.append("rate")
            acceptedRatings[track.id] = rating
            if loseAcknowledgment { throw URLError(.networkConnectionLost) }
            return .none
        }

        func recordedEvents() -> [String] {
            events
        }

        func recordReconciliation() { events.append("reconcile") }

        func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? {
            events.append("create")
            mutationTitle = title
            mutationTrackIDs = tracks.map(\.id)
            return createdPlaylist
        }

        func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int {
            events.append("add")
            mutationTrackIDs = tracks.map(\.id)
            return tracks.count
        }

        func renamePlaylist(_ playlistID: String, title: String) async throws {
            events.append("rename")
            mutationTitle = title
        }

        func deletePlaylist(_ playlistID: String) async throws {
            events.append("delete")
        }

        func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws {
            events.append("replace")
            mutationTrackIDs = tracks.map(\.id)
        }

        func editPlaylistItems(
            _ playlistID: String,
            originalItems: [PlaylistItem],
            editedItems: [PlaylistItem]
        ) async throws {
            events.append("edit")
            editedMembershipIDs = editedItems.map(\.playlistItemID)
        }

        func syncLibrary(
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult { LibrarySyncResult() }

        func syncLibraryIncremental(
            since timestamp: TimeInterval,
            to repository: LibraryRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> LibrarySyncResult { LibrarySyncResult() }

        func syncPlaylists(
            to repository: PlaylistRepositoryProtocol,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            events.append("refresh")
            return PlaylistSyncResult()
        }

        func syncPlaylistsIncremental(
            to repository: PlaylistRepositoryProtocol,
            forceOrphanCheck: Bool,
            progressHandler: @Sendable (Double) -> Void
        ) async throws -> PlaylistSyncResult {
            events.append("refresh")
            return PlaylistSyncResult()
        }

        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
    }

    private struct ReconcilingPlaylistProvider: MusicSourceSyncProvider, MusicSourcePlaylistReconciling {
        let base: RecordingPlaylistProvider
        var sourceIdentifier: MusicSourceIdentifier { base.sourceIdentifier }

        func createPlaylist(title: String, tracks: [Track]) async throws -> Playlist? { try await base.createPlaylist(title: title, tracks: tracks) }
        func addTracks(_ tracks: [Track], to playlistID: String) async throws -> Int { try await base.addTracks(tracks, to: playlistID) }
        func renamePlaylist(_ playlistID: String, title: String) async throws { try await base.renamePlaylist(playlistID, title: title) }
        func deletePlaylist(_ playlistID: String) async throws { try await base.deletePlaylist(playlistID) }
        func replacePlaylistContents(_ playlistID: String, tracks: [Track]) async throws { try await base.replacePlaylistContents(playlistID, tracks: tracks) }
        func editPlaylistItems(_ playlistID: String, originalItems: [PlaylistItem], editedItems: [PlaylistItem]) async throws { try await base.editPlaylistItems(playlistID, originalItems: originalItems, editedItems: editedItems) }
        func syncLibrary(to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { try await base.syncLibrary(to: repository, progressHandler: progressHandler) }
        func syncLibraryIncremental(since timestamp: TimeInterval, to repository: LibraryRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> LibrarySyncResult { try await base.syncLibraryIncremental(since: timestamp, to: repository, progressHandler: progressHandler) }
        func syncPlaylists(to repository: PlaylistRepositoryProtocol, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { try await base.syncPlaylists(to: repository, progressHandler: progressHandler) }
        func syncPlaylistsIncremental(to repository: PlaylistRepositoryProtocol, forceOrphanCheck: Bool, progressHandler: @Sendable (Double) -> Void) async throws -> PlaylistSyncResult { try await base.syncPlaylistsIncremental(to: repository, forceOrphanCheck: forceOrphanCheck, progressHandler: progressHandler) }
        func getArtworkURL(path: String?, size: Int) async throws -> URL? { nil }
        func reconcilePlaylist(id: String, minimumTrackCount: Int, requiredTracks: [Track], to repository: PlaylistRepositoryProtocol) async throws -> Int? {
            await base.recordReconciliation()
            return minimumTrackCount
        }
    }

    private func makeCoordinator(
        withServer: Bool = true,
        playlistRepository: PlaylistRepositoryProtocol = EmptyPlaylistRepository(),
        artworkDownloadManager: ArtworkDownloadManagerProtocol = EmptyArtworkDownloadManager()
    ) -> SyncCoordinator {
        let accountManager = AccountManager(keychain: TestKeychain())
        if withServer {
            accountManager.addPlexAccount(
                PlexAccountConfig(
                    id: "account-1",
                    displayTitle: "tester",
                    authToken: "auth",
                    servers: [
                        PlexServerConfig(
                            id: "server-1",
                            name: "Server",
                            url: "https://example.com",
                            token: "token",
                            libraries: [
                                PlexLibraryConfig(id: "lib-1", key: "1", title: "Music", isEnabled: true)
                            ]
                        )
                    ]
                )
            )
        }

        let networkMonitor = NetworkMonitor()
        let coordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: EmptyLibraryRepository(),
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        if withServer {
            coordinator.refreshProviders()
        }
        coordinator.setLastPlaylistTargetForTesting(nil, serverSourceKey: "plex:account-1:server-1")
        return coordinator
    }

    func testAgedOfflineMutationSurvivesStoreReopenAndLostAcknowledgment() async throws {
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: storeURL.path + suffix) }
        }
        let source = "plex:account-1:server-1:lib-1"
        var stack = CoreDataStack.inMemory()
        let payload = try JSONEncoder().encode(TrackRatingMutationPayload(trackRatingKey: "offline", sourceCompositeKey: source, rating: 10))
        try await PendingMutationRepository(coreDataStack: stack).enqueueMutation(id: "aged-rating", type: .trackRating, payload: payload, sourceCompositeKey: source)
        let record = try XCTUnwrap(try stack.viewContext.fetch(CDPendingMutation.fetchRequest()).first)
        record.createdAt = Date().addingTimeInterval(-72 * 3600)
        try stack.viewContext.save()
        let coordinator = stack.persistentContainer.persistentStoreCoordinator
        let original = try XCTUnwrap(coordinator.persistentStores.first)
        let saved = try coordinator.migratePersistentStore(original, to: storeURL, options: nil, withType: NSSQLiteStoreType)
        try coordinator.remove(saved)
        stack = CoreDataStack.inMemory()
        let reopened = stack.persistentContainer.persistentStoreCoordinator
        for store in reopened.persistentStores { try reopened.remove(store) }
        try reopened.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: storeURL, options: nil)
        let repository = PendingMutationRepository(coreDataStack: stack)
        let network = NetworkMonitor(debounceNanoseconds: 0, monitorQueue: DispatchQueue(label: "aged-replay"), monitorFactory: { SystemNetworkPathMonitor() })
        network.simulateOffline(true)
        let sync = makeCoordinator()
        let provider = RecordingPlaylistProvider()
        sync.setSyncProvidersForTesting([source: provider])
        var replay: MutationCoordinator? = MutationCoordinator(repository: repository, coreDataStack: stack, toastCenter: ToastCenter(), networkMonitor: network, syncCoordinator: sync)
        for _ in 0..<12 { await replay?.drainQueue() }
        let offlineEvents = await provider.recordedEvents()
        XCTAssertEqual(offlineEvents, [])
        let pending = try await repository.fetchPendingMutationRecords()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.retryCount, 0)
        network.simulateOffline(false)
        network.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        for _ in 0..<4 { await replay?.drainQueue() }
        let unacknowledged = try await repository.fetchPendingMutationRecords()
        XCTAssertEqual(unacknowledged.count, 1)
        XCTAssertEqual(unacknowledged.first?.retryCount, 0)
        let accepted = await provider.ratings()
        XCTAssertEqual(accepted, ["offline": 10])
        replay = nil
        await provider.restoreAcknowledgments()
        replay = MutationCoordinator(repository: repository, coreDataStack: stack, toastCenter: ToastCenter(), networkMonitor: network, syncCoordinator: sync)
        await replay?.drainQueue()
        let remaining = try await repository.fetchPendingMutationRecords()
        XCTAssertTrue(remaining.isEmpty)
        let finalRatings = await provider.ratings()
        XCTAssertEqual(finalRatings, accepted)
    }

    func testAddTrackToLibraryCoalescesConcurrentRequests() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let gate = LibraryAddGate()
        let firstAddStarted = expectation(description: "First library add started")
        let secondAddCoalesced = expectation(description: "Second library add coalesced")
        coordinator.sourceLibraryAddHandlerForTesting = { _ in
            firstAddStarted.fulfill()
            return await gate.add()
        }
        coordinator.sourceLibraryAddDidCoalesceForTesting = {
            secondAddCoalesced.fulfill()
        }
        let track = Track(
            id: "catalog-id",
            key: "apple-catalog",
            title: "The Wolf",
            artistName: "half alive",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )

        let first = Task { try await coordinator.addTrackToLibrary(track) }
        await fulfillment(of: [firstAddStarted], timeout: 1)
        let second = Task { try await coordinator.addTrackToLibrary(track) }
        await fulfillment(of: [secondAddCoalesced], timeout: 1)
        await gate.release()
        let secondOutcome = try await second.value
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome, .alreadyPresent)
        XCTAssertEqual(secondOutcome, .alreadyPresent)
        let finalInvocationCount = await gate.invocationCount
        XCTAssertEqual(finalInvocationCount, 1)
    }

    func testOptimisticAppleMusicPlaylistAddPersistsMembershipImmediately() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceKey = MusicSourceIdentifier.appleMusic.compositeKey
        _ = try await repository.upsertPlaylist(
            ratingKey: "playlist-1",
            key: "playlist-1",
            title: "Sleepy Ambient",
            summary: nil,
            compositePath: nil,
            isSmart: false,
            duration: 200_000,
            trackCount: 2,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: sourceKey
        )
        try await repository.setPlaylistTrackSnapshots(
            [
                PlaylistTrackSnapshot(ratingKey: "one", title: "One", duration: 90, sourceCompositeKey: sourceKey),
                PlaylistTrackSnapshot(ratingKey: "two", title: "Two", duration: 110, sourceCompositeKey: sourceKey)
            ],
            forPlaylist: "playlist-1",
            sourceCompositeKey: sourceKey
        )
        let playlist = Playlist(
            id: "playlist-1",
            key: "playlist-1",
            title: "Sleepy Ambient",
            trackCount: 2,
            duration: 200,
            sourceCompositeKey: sourceKey
        )
        let espresso = Track(
            id: "1752214923",
            key: "apple-catalog",
            title: "Espresso",
            artistName: "Sabrina Carpenter",
            albumName: "Short n' Sweet (Deluxe)",
            duration: 175.5,
            sourceCompositeKey: sourceKey
        )
        let coordinator = makeCoordinator(withServer: false, playlistRepository: repository)

        let firstCount = try await coordinator.persistOptimisticPlaylistAdd([espresso], playlist: playlist)
        let duplicateCount = try await coordinator.persistOptimisticPlaylistAdd([espresso], playlist: playlist)
        XCTAssertEqual(firstCount, 3)
        XCTAssertEqual(duplicateCount, 3)

        let fetched = try await repository.fetchPlaylist(ratingKey: playlist.id, sourceCompositeKey: sourceKey)
        let cached = try XCTUnwrap(fetched)
        XCTAssertEqual(cached.trackCount, 3)
        XCTAssertEqual(cached.playlistItemsArray.map(PlaylistItem.init(from:)).map(\.track.title), ["One", "Two", "Espresso"])
    }

    func testCreateWaitsForSnapshotPersistenceAndPropagatesStorageFailure() async throws {
        for fails in [false, true] {
            let repository = PlaylistRepository(coreDataStack: .inMemory())
            let gate = PlaylistGate()
            let coordinator = makeCoordinator(withServer: false, playlistRepository: SnapshotWriteRepository(base: repository, gate: gate, fails: fails))
            let created = Playlist(id: "created", key: "/playlists/created", title: "New Playlist", sourceCompositeKey: "plex:account-1:server-1")
            let provider = RecordingPlaylistProvider(createdPlaylist: created)
            coordinator.setSyncProvidersForTesting([provider.sourceIdentifier.compositeKey: provider])
            var refreshScopes: [String] = []
            coordinator.refreshServerPlaylistsHandlerForTesting = { refreshScopes.append($0) }
            var didReturn = false
            let tracks = [
                Track(id: "one", key: "one", title: "One", sourceCompositeKey: provider.sourceIdentifier.compositeKey),
                Track(id: "other", key: "other", title: "Other", sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey),
                Track(id: "two", key: "two", title: "Two", sourceCompositeKey: provider.sourceIdentifier.compositeKey)
            ]
            let createTask = Task { @MainActor in
                let result = try await coordinator.createPlaylist(title: " New Playlist ", tracks: tracks, serverSourceKey: "plex:account-1:server-1")
                didReturn = true
                return result
            }
            await gate.waitUntilStarted()
            XCTAssertFalse(didReturn, "Creation must not report success while memberships are uncommitted")
            XCTAssertNil(coordinator.lastPlaylistTarget)
            await gate.open()

            if fails {
                do {
                    _ = try await createTask.value
                    XCTFail("A storage failure must not become an accepted creation")
                } catch let error as CocoaError {
                    XCTAssertEqual(error.code, .fileWriteUnknown)
                }
                XCTAssertNil(coordinator.lastPlaylistTarget)
                XCTAssertTrue(refreshScopes.isEmpty)
            } else {
                let result = try await createTask.value
                XCTAssertEqual(result.addedCount, 2)
                XCTAssertEqual(result.skippedCount, 1)
                let cachedResult = try await repository.fetchPlaylist(ratingKey: created.id, sourceCompositeKey: created.sourceCompositeKey)
                let cached = try XCTUnwrap(cachedResult)
                XCTAssertEqual(cached.title, "New Playlist")
                XCTAssertEqual(cached.playlistItemsArray.map(PlaylistItem.init(from:)).map(\.track.id), ["one", "two"])
                XCTAssertEqual(coordinator.lastPlaylistTarget?.sourceCompositeKey, created.sourceCompositeKey)
            }
            let title = await provider.mutationTitle
            let trackIDs = await provider.mutationTrackIDs
            XCTAssertEqual(title, "New Playlist")
            XCTAssertEqual(trackIDs, ["one", "two"])
        }
    }

    func testCreateReplaceAndEditReturnBeforeDeferredRefreshFinishes() async throws {
        for operation in ["create", "replace", "edit"] {
            let coordinator = makeCoordinator(withServer: false)
            let provider = RecordingPlaylistProvider()
            coordinator.setSyncProvidersForTesting([provider.sourceIdentifier.compositeKey: provider])
            let gate = PlaylistGate()
            var refreshedSource: String?
            coordinator.refreshServerPlaylistsHandlerForTesting = {
                refreshedSource = $0
                await gate.wait()
            }
            let playlist = Playlist(id: "playlist-1", key: "playlist-1", title: "Mix", sourceCompositeKey: "plex:account-1:server-1")
            let completed = expectation(description: "\(operation) returned")
            let mutation = Task { @MainActor in
                defer { completed.fulfill() }
                switch operation {
                case "create": _ = try await coordinator.createPlaylist(title: "New Playlist", tracks: [], serverSourceKey: "plex:account-1:server-1")
                case "replace": try await coordinator.replacePlaylistContents(playlist, with: [])
                default: try await coordinator.editPlaylistItems(playlist, originalItems: [], editedItems: [])
                }
            }
            await gate.waitUntilStarted()
            await fulfillment(of: [completed], timeout: 1)
            XCTAssertEqual(refreshedSource, "plex:account-1:server-1")
            await gate.open()
            try await mutation.value
        }
    }

    func testAcceptedAddPreservesNativeOccurrencesAndRecentTargetBeforeRefresh() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceKey = "plex:account-1:server-1"
        let cached = CDPlaylist(context: stack.viewContext)
        cached.ratingKey = "playlist-1"
        cached.key = "playlist-1"
        cached.title = "Mix"
        cached.sourceCompositeKey = sourceKey
        try stack.viewContext.save()
        try await repository.setPlaylistTrackSnapshots([
            PlaylistTrackSnapshot(ratingKey: "one", playlistItemID: "occurrence-1", title: "One", sourceCompositeKey: "plex:account-1:server-1:lib-1"),
            PlaylistTrackSnapshot(ratingKey: "one", playlistItemID: "occurrence-2", title: "One", sourceCompositeKey: "plex:account-1:server-1:lib-1")
        ], forPlaylist: "playlist-1", sourceCompositeKey: sourceKey)
        let coordinator = makeCoordinator(withServer: false, playlistRepository: repository)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([provider.sourceIdentifier.compositeKey: provider])
        let gate = PlaylistGate()
        coordinator.refreshServerPlaylistsHandlerForTesting = { _ in await gate.wait() }
        let playlist = Playlist(id: "playlist-1", key: "playlist-1", title: "Mix", trackCount: 2, sourceCompositeKey: sourceKey)
        let result = try await coordinator.addTracksToPlaylist([
            Track(id: "one", key: "one", title: "One", sourceCompositeKey: provider.sourceIdentifier.compositeKey),
            Track(id: "two", key: "two", title: "Two", sourceCompositeKey: provider.sourceIdentifier.compositeKey)
        ], playlist: playlist)
        await gate.waitUntilStarted()
        await gate.open()
        let persistedResult = try await repository.fetchPlaylist(ratingKey: playlist.id, sourceCompositeKey: sourceKey)
        let items = try XCTUnwrap(persistedResult).playlistItemsArray.map(PlaylistItem.init(from:))
        XCTAssertEqual(result.addedCount, 2)
        XCTAssertEqual(items.map(\.track.id), ["one", "one", "two"])
        XCTAssertEqual(items.map(\.playlistItemID), ["occurrence-1", "occurrence-2", nil])
        XCTAssertEqual(coordinator.lastPlaylistTarget?.id, playlist.id)
        XCTAssertEqual(coordinator.lastPlaylistTarget?.sourceCompositeKey, sourceKey)
    }

    func testStaleAcceptedAddReconcilerDoesNotBlockSourceCleanup() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        let sourceKey = "plex:account-1:server-1"
        let cached = CDPlaylist(context: stack.viewContext)
        cached.ratingKey = "playlist-1"
        cached.key = "playlist-1"
        cached.title = "Mix"
        cached.sourceCompositeKey = sourceKey
        try stack.viewContext.save()
        let gate = PlaylistGate()
        let coordinator = makeCoordinator(withServer: false, playlistRepository: SnapshotWriteRepository(base: repository, gate: gate, fails: false))
        let recording = RecordingPlaylistProvider()
        let oldProvider = ReconcilingPlaylistProvider(base: recording)
        coordinator.setSyncProvidersForTesting([oldProvider.sourceIdentifier.compositeKey: oldProvider])
        let playlist = Playlist(id: "playlist-1", key: "playlist-1", title: "Mix", sourceCompositeKey: sourceKey)
        let track = Track(id: "one", key: "one", title: "One", sourceCompositeKey: oldProvider.sourceIdentifier.compositeKey)
        let addTask = Task { try await coordinator.addTracksToPlaylist([track], playlist: playlist) }
        await gate.waitUntilStarted()
        coordinator.installSyncProviderForTesting(RecordingPlaylistProvider())
        await gate.open()
        do {
            _ = try await addTask.value
            XCTFail("The replaced registration must invalidate the command's original operation")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .invalidSource)
        }
        // Let the already-scheduled reconciler reject its stale captured registration.
        for _ in 0..<20 { await Task.yield() }
        let events = await recording.recordedEvents()
        XCTAssertEqual(events, ["add"])

        let cleaned = expectation(description: "source cleanup completed after stale reconciler")
        var cleanupResult: Bool?
        let cleanupTask = Task { @MainActor in
            cleanupResult = await coordinator.cleanupRemovedSource(oldProvider.sourceIdentifier)
            cleaned.fulfill()
        }
        await fulfillment(of: [cleaned], timeout: 1)
        if let cleanupResult {
            XCTAssertTrue(cleanupResult)
            await cleanupTask.value
        } else {
            // A leaked lease cannot be drained by task cancellation. Keep a regressed
            // isolated fixture finite instead of awaiting the blocked cleanup forever.
            cleanupTask.cancel()
        }
    }

    func testRenameRejectsOnlyExactSourceDuplicateBeforeProviderMutation() async throws {
        let stack = CoreDataStack.inMemory()
        let repository = PlaylistRepository(coreDataStack: stack)
        for (title, source) in [("Taken", "plex:account-1:server-1"), ("Allowed", "plex:account-2:server-1")] {
            let duplicate = CDPlaylist(context: stack.viewContext)
            duplicate.ratingKey = "other"
            duplicate.key = "other"
            duplicate.title = title
            duplicate.sourceCompositeKey = source
        }
        try stack.viewContext.save()
        let coordinator = makeCoordinator(withServer: false, playlistRepository: repository)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([provider.sourceIdentifier.compositeKey: provider])
        let playlist = Playlist(id: "playlist-1", key: "playlist-1", title: "Mix", sourceCompositeKey: "plex:account-1:server-1")
        do {
            try await coordinator.renamePlaylist(playlist, to: " taken ")
            XCTFail("An exact-source name collision must fail")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .duplicateName)
        }
        let before = await provider.recordedEvents()
        XCTAssertTrue(before.isEmpty)
        try await coordinator.renamePlaylist(playlist, to: " Allowed ")
        let title = await provider.mutationTitle
        XCTAssertEqual(title, "Allowed")
    }

    func testDeletePlaylistRejectsSmartPlaylist() async throws {
        let coordinator = makeCoordinator()
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Smart",
            summary: nil,
            isSmart: true,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )

        do {
            try await coordinator.deletePlaylist(playlist)
            XCTFail("Expected smart playlist mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .smartPlaylistReadOnly)
        }
    }

    func testDeletePlaylistRejectsInvalidSource() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:missing-account:missing-server"
        )

        do {
            try await coordinator.deletePlaylist(playlist)
            XCTFail("Expected invalid source mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .invalidSource)
        }
    }

    func testEditPlaylistItemsRejectsReadOnlyPlaylistBeforeProviderMutation() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Read Only",
            sourceCompositeKey: "plex:account-1:server-1",
            actionCapabilities: PlaylistActionCapabilities(
                canAddItems: true,
                canRename: false,
                canReorder: false,
                canDelete: false
            )
        )

        do {
            try await coordinator.editPlaylistItems(
                playlist,
                originalItems: [],
                editedItems: []
            )
            XCTFail("Expected read-only playlist mutation to throw")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .smartPlaylistReadOnly)
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testServerScopedPlaylistMutationsRouteThroughRegisteredProvider() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let track = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track",
            sourceCompositeKey: provider.sourceIdentifier.compositeKey
        )
        let item = PlaylistItem(id: "item-1", playlistItemID: "item-1", track: track)

        _ = try await coordinator.createPlaylist(
            title: "Created",
            tracks: [track],
            serverSourceKey: "plex:account-1:server-1"
        )
        _ = try await coordinator.addTracksToPlaylist([track], playlist: playlist)
        try await coordinator.renamePlaylist(playlist, to: "Renamed")
        try await coordinator.replacePlaylistContents(playlist, with: [track])
        try await coordinator.editPlaylistItems(
            playlist,
            originalItems: [item],
            editedItems: []
        )
        try await coordinator.deletePlaylist(playlist)

        for _ in 0..<10 {
            if (await provider.recordedEvents()).contains("refresh") { break }
            await Task.yield()
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(
            events.filter { $0 != "refresh" },
            ["create", "add", "rename", "replace", "edit", "delete"]
        )
        XCTAssertTrue(events.contains("refresh"))
    }

    func testOnlinePlaylistMutationsRejectTrackFromRemovedSiblingLibrary() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let retainedSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-2"
        )
        let provider = RecordingPlaylistProvider(sourceIdentifier: retainedSource)
        coordinator.setSyncProvidersForTesting([
            retainedSource.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let removedTrack = Track(
            id: "removed-track",
            key: "/library/metadata/removed-track",
            title: "Removed",
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        let mutations: [() async throws -> Void] = [
            { _ = try await coordinator.createPlaylist(
                title: "Created",
                tracks: [removedTrack],
                serverSourceKey: "plex:account-1:server-1"
            ) },
            { _ = try await coordinator.addTracksToPlaylist([removedTrack], playlist: playlist) },
            { try await coordinator.replacePlaylistContents(playlist, with: [removedTrack]) }
        ]

        for mutation in mutations {
            do {
                try await mutation()
                XCTFail("Expected stale-library mutation to fail")
            } catch let error as PlaylistMutationError {
                XCTAssertEqual(error, .invalidSource)
            }
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(events, [])
    }

    func testReplacementPreservesCompatibleOrderedOccurrences() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([provider.sourceIdentifier.compositeKey: provider])
        let playlist = Playlist(id: "playlist-1", key: "playlist-1", title: "Mix", sourceCompositeKey: "plex:account-1:server-1")
        let first = Track(id: "a", key: "a", title: "A", sourceCompositeKey: provider.sourceIdentifier.compositeKey)
        let second = Track(id: "b", key: "b", title: "B", sourceCompositeKey: provider.sourceIdentifier.compositeKey)
        let incompatible = Track(id: "a", key: "a", title: "Other A", sourceCompositeKey: "plex:account-2:server-1:lib-1")

        try await coordinator.replacePlaylistContents(playlist, with: [first, incompatible, first, second])

        let received = await provider.mutationTrackIDs
        XCTAssertEqual(received, ["a", "a", "b"])

        do {
            try await coordinator.replacePlaylistContents(playlist, with: [Track(id: "legacy", key: "legacy", title: "Legacy")])
            XCTFail("Expected source-less replacement to fail before the provider")
        } catch let error as PlaylistMutationError {
            XCTAssertEqual(error, .emptySelection)
        }
        let events = await provider.recordedEvents()
        XCTAssertEqual(events.filter { $0 == "replace" }, ["replace"])
    }

    func testEditPlaylistAllowsServerOwnedItemFromRemovedLibrary() async throws {
        let coordinator = makeCoordinator(withServer: false)
        let retainedSource = MusicSourceIdentifier(
            type: .plex,
            accountId: "account-1",
            serverId: "server-1",
            libraryId: "lib-2"
        )
        let provider = RecordingPlaylistProvider(sourceIdentifier: retainedSource)
        coordinator.setSyncProvidersForTesting([retainedSource.compositeKey: provider])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let removedTrack = Track(
            id: "removed-track",
            key: "/library/metadata/removed-track",
            title: "Removed",
            sourceCompositeKey: "plex:account-1:server-1:lib-1"
        )
        let first = PlaylistItem(id: "first", playlistItemID: "first", track: removedTrack)
        let second = PlaylistItem(id: "second", playlistItemID: "second", track: removedTrack)
        let third = PlaylistItem(id: "third", playlistItemID: "third", track: removedTrack)

        try await coordinator.editPlaylistItems(
            playlist,
            originalItems: [first, second, third],
            editedItems: [second, first]
        )

        let events = await provider.recordedEvents()
        XCTAssertTrue(events.contains("edit"))
        let membershipIDs = await provider.editedMembershipIDs
        XCTAssertEqual(membershipIDs, ["second", "first"])
    }

    func testDeletePlaylistClearsMatchingRecentTarget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let artwork = ArtworkDownloadManager(storageDirectory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = makeCoordinator(withServer: false, artworkDownloadManager: artwork)
        let provider = RecordingPlaylistProvider()
        coordinator.setSyncProvidersForTesting([
            provider.sourceIdentifier.compositeKey: provider
        ])
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Regular",
            summary: nil,
            isSmart: false,
            trackCount: 1,
            duration: 100,
            compositePath: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            sourceCompositeKey: "plex:account-1:server-1"
        )
        let sources = ["plex:account-1:server-1", "plex:account-2:server-1"]
        let paths = sources.map {
            directory.appendingPathComponent(ArtworkDownloadManager.cacheFilename(ratingKey: playlist.id, type: .playlist, sourceCompositeKey: $0))
        }
        for path in paths { try Data("artwork".utf8).write(to: path) }
        let siblingTarget = LastPlaylistTarget(id: playlist.id, title: "Sibling", sourceCompositeKey: sources[1])
        coordinator.setLastPlaylistTargetForTesting(siblingTarget, serverSourceKey: sources[1])

        coordinator.setLastPlaylistTargetForTesting(
            LastPlaylistTarget(
                id: "playlist-1",
                title: "Regular",
                sourceCompositeKey: "plex:account-1:server-1"
            ),
            serverSourceKey: "plex:account-1:server-1"
        )
        try await coordinator.deletePlaylist(playlist)

        XCTAssertNil(coordinator.lastPlaylistTarget(forServerSourceKey: "plex:account-1:server-1"))
        XCTAssertNil(coordinator.lastPlaylistTarget)
        XCTAssertEqual(coordinator.lastPlaylistTarget(forServerSourceKey: sources[1]), siblingTarget)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[1].path))
    }
}
