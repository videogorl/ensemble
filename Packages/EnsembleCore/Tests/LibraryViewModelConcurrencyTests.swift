import XCTest
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class LibraryViewModelConcurrencyTests: XCTestCase {
    private actor RepositoryCallGate {
        private var nextCall = 0
        private var startedCalls: Set<Int> = []
        private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

        func suspendNextCall() async {
            nextCall += 1
            let call = nextCall

            await withCheckedContinuation { continuation in
                releaseWaiters[call] = continuation
                startedCalls.insert(call)
            }
        }

        func hasStarted(_ call: Int) -> Bool {
            startedCalls.contains(call)
        }

        func release(_ call: Int) {
            releaseWaiters.removeValue(forKey: call)?.resume()
        }
    }

    private final class DelayedLibraryRepository:
        LibraryRepositoryProtocol,
        LibraryRepositoryBackingStoreProviding,
        @unchecked Sendable
    {
        let backingCoreDataStack: CoreDataStack

        private let repository: LibraryRepository
        private let sourceFetchGate: RepositoryCallGate

        init(repository: LibraryRepository, sourceFetchGate: RepositoryCallGate) {
            self.repository = repository
            self.sourceFetchGate = sourceFetchGate
            self.backingCoreDataStack = repository.backingCoreDataStack
        }

        func refreshContext() async {
            await repository.refreshContext()
        }

        func fetchArtists() async throws -> [CDArtist] {
            try await repository.fetchArtists()
        }

        func fetchArtist(ratingKey: String) async throws -> CDArtist? {
            try await repository.fetchArtist(ratingKey: ratingKey)
        }

        func fetchAlbums() async throws -> [CDAlbum] {
            try await repository.fetchAlbums()
        }

        func fetchAlbum(ratingKey: String) async throws -> CDAlbum? {
            try await repository.fetchAlbum(ratingKey: ratingKey)
        }

        func fetchAlbums(forArtist artistRatingKey: String) async throws -> [CDAlbum] {
            try await repository.fetchAlbums(forArtist: artistRatingKey)
        }

        func fetchTracks() async throws -> [CDTrack] {
            try await repository.fetchTracks()
        }

        func fetchTracks(forSource sourceCompositeKey: String) async throws -> [CDTrack] {
            try await repository.fetchTracks(forSource: sourceCompositeKey)
        }

        func fetchSiriEligibleTracks() async throws -> [CDTrack] {
            try await repository.fetchSiriEligibleTracks()
        }

        func fetchTracks(forAlbum albumRatingKey: String) async throws -> [CDTrack] {
            try await repository.fetchTracks(forAlbum: albumRatingKey)
        }

        func fetchTracks(forAlbum albumRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
            try await repository.fetchTracks(forAlbum: albumRatingKey, sourceCompositeKey: sourceCompositeKey)
        }

        func fetchTracks(forArtist artistRatingKey: String) async throws -> [CDTrack] {
            try await repository.fetchTracks(forArtist: artistRatingKey)
        }

        func fetchTracks(forArtist artistRatingKey: String, sourceCompositeKey: String) async throws -> [CDTrack] {
            try await repository.fetchTracks(forArtist: artistRatingKey, sourceCompositeKey: sourceCompositeKey)
        }

        func fetchFavoriteTracks() async throws -> [CDTrack] {
            try await repository.fetchFavoriteTracks()
        }

        func fetchTrack(ratingKey: String) async throws -> CDTrack? {
            try await repository.fetchTrack(ratingKey: ratingKey)
        }

        func fetchTrack(ratingKey: String, sourceCompositeKey: String?) async throws -> CDTrack? {
            try await repository.fetchTrack(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)
        }

        func upsertTrack(
            ratingKey: String,
            key: String,
            title: String,
            artistName: String?,
            albumName: String?,
            albumRatingKey: String?,
            trackNumber: Int?,
            discNumber: Int?,
            duration: Int?,
            thumbPath: String?,
            streamKey: String?,
            dateAdded: Date?,
            dateModified: Date?,
            lastPlayed: Date?,
            lastRatedAt: Date?,
            rating: Int?,
            playCount: Int?,
            genreNames: String?,
            sourceCompositeKey: String?
        ) async throws -> CDTrack {
            try await repository.upsertTrack(
                ratingKey: ratingKey,
                key: key,
                title: title,
                artistName: artistName,
                albumName: albumName,
                albumRatingKey: albumRatingKey,
                trackNumber: trackNumber,
                discNumber: discNumber,
                duration: duration,
                thumbPath: thumbPath,
                streamKey: streamKey,
                dateAdded: dateAdded,
                dateModified: dateModified,
                lastPlayed: lastPlayed,
                lastRatedAt: lastRatedAt,
                rating: rating,
                playCount: playCount,
                genreNames: genreNames,
                sourceCompositeKey: sourceCompositeKey
            )
        }

        func fetchGenres() async throws -> [CDGenre] {
            try await repository.fetchGenres()
        }

        func upsertGenre(
            ratingKey: String?,
            key: String,
            title: String,
            sourceCompositeKey: String?
        ) async throws -> CDGenre {
            try await repository.upsertGenre(
                ratingKey: ratingKey,
                key: key,
                title: title,
                sourceCompositeKey: sourceCompositeKey
            )
        }

        func searchTracks(query: String) async throws -> [CDTrack] {
            try await repository.searchTracks(query: query)
        }

        func searchArtists(query: String) async throws -> [CDArtist] {
            try await repository.searchArtists(query: query)
        }

        func searchAlbums(query: String) async throws -> [CDAlbum] {
            try await repository.searchAlbums(query: query)
        }

        func findTracksByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDTrack] {
            try await repository.findTracksByTitle(title, sourceCompositeKeys: sourceCompositeKeys)
        }

        func findArtistsByName(_ name: String, sourceCompositeKeys: Set<String>?) async throws -> [CDArtist] {
            try await repository.findArtistsByName(name, sourceCompositeKeys: sourceCompositeKeys)
        }

        func findAlbumsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDAlbum] {
            try await repository.findAlbumsByTitle(title, sourceCompositeKeys: sourceCompositeKeys)
        }

        func fetchMusicSources() async throws -> [CDMusicSource] {
            await sourceFetchGate.suspendNextCall()
            return try await repository.fetchMusicSources()
        }

        func upsertMusicSource(
            compositeKey: String,
            type: String,
            accountId: String,
            serverId: String,
            libraryId: String,
            displayName: String?,
            accountName: String?
        ) async throws -> CDMusicSource {
            try await repository.upsertMusicSource(
                compositeKey: compositeKey,
                type: type,
                accountId: accountId,
                serverId: serverId,
                libraryId: libraryId,
                displayName: displayName,
                accountName: accountName
            )
        }

        func updateMusicSourceSyncTimestamp(compositeKey: String) async throws {
            try await repository.updateMusicSourceSyncTimestamp(compositeKey: compositeKey)
        }

        func deleteAllData(forSourceCompositeKey: String) async throws {
            try await repository.deleteAllData(forSourceCompositeKey: forSourceCompositeKey)
        }

        func deleteAllLibraryData() async throws {
            try await repository.deleteAllLibraryData()
        }

        func removeOrphanedArtists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
            try await repository.removeOrphanedArtists(notIn: validRatingKeys, forSource: sourceKey)
        }

        func removeOrphanedAlbums(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
            try await repository.removeOrphanedAlbums(notIn: validRatingKeys, forSource: sourceKey)
        }

        func removeOrphanedTracks(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
            try await repository.removeOrphanedTracks(notIn: validRatingKeys, forSource: sourceKey)
        }

        func removeOrphanedGenres(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
            try await repository.removeOrphanedGenres(notIn: validRatingKeys, forSource: sourceKey)
        }

        func fetchTrackRatings(forSource sourceKey: String) async throws -> [String: Int16] {
            try await repository.fetchTrackRatings(forSource: sourceKey)
        }

        func fetchArtistTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
            try await repository.fetchArtistTimestamps(forSource: sourceKey)
        }

        func fetchAlbumTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
            try await repository.fetchAlbumTimestamps(forSource: sourceKey)
        }

        func fetchTrackTimestamps(forSource sourceKey: String) async throws -> [String: Date] {
            try await repository.fetchTrackTimestamps(forSource: sourceKey)
        }

        func batchUpsertArtists(_ inputs: [ArtistUpsertInput], sourceCompositeKey: String) async throws {
            try await repository.batchUpsertArtists(inputs, sourceCompositeKey: sourceCompositeKey)
        }

        func batchUpsertAlbums(_ inputs: [AlbumUpsertInput], sourceCompositeKey: String) async throws {
            try await repository.batchUpsertAlbums(inputs, sourceCompositeKey: sourceCompositeKey)
        }

        func batchUpsertTracks(_ inputs: [TrackUpsertInput], sourceCompositeKey: String) async throws {
            try await repository.batchUpsertTracks(inputs, sourceCompositeKey: sourceCompositeKey)
        }

        func drainTrackReparentInfo() -> [TrackReparentInfo] {
            repository.drainTrackReparentInfo()
        }
    }

    private struct Harness {
        let accountManager: AccountManager
        let syncCoordinator: SyncCoordinator
        let libraryRepository: LibraryRepository
    }

    func testLatestSourceSnapshotWinsWhenOlderLoadFinishesLast() async throws {
        let harness = makeHarness()
        let sourceA = "plex:account-1:server-1:lib-a"
        let sourceB = "plex:account-1:server-1:lib-b"
        harness.accountManager.addPlexAccount(makeAccount(libraryKey: "lib-a"))
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceA)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceB)

        let gate = RepositoryCallGate()
        let delayedRepository = DelayedLibraryRepository(
            repository: harness.libraryRepository,
            sourceFetchGate: gate
        )
        let viewModel = makeViewModel(harness: harness, libraryRepository: delayedRepository)
        let olderLoad = Task { @MainActor in await viewModel.loadLibrary() }
        try await waitForCallStart(1, gate: gate)

        harness.accountManager.updatePlexAccount(makeAccount(libraryKey: "lib-b"))
        try await waitForCallStart(2, gate: gate)

        await gate.release(2)
        try await waitForLoadCompletion(viewModel: viewModel, expectedSourceKey: sourceB)
        await gate.release(1)
        await olderLoad.value

        XCTAssertEqual(viewModel.tracks.compactMap(\.sourceCompositeKey), [sourceB])
        XCTAssertFalse(viewModel.isLoading)
    }

    func testOlderLoadCannotFinishLoadingWhileLatestLoadIsPending() async throws {
        let harness = makeHarness()
        let sourceA = "plex:account-1:server-1:lib-a"
        let sourceB = "plex:account-1:server-1:lib-b"
        harness.accountManager.addPlexAccount(makeAccount(libraryKey: "lib-a"))
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceA)
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: sourceB)

        let gate = RepositoryCallGate()
        let delayedRepository = DelayedLibraryRepository(
            repository: harness.libraryRepository,
            sourceFetchGate: gate
        )
        let viewModel = makeViewModel(harness: harness, libraryRepository: delayedRepository)
        let olderLoad = Task { @MainActor in await viewModel.loadLibrary() }
        try await waitForCallStart(1, gate: gate)

        harness.accountManager.updatePlexAccount(makeAccount(libraryKey: "lib-b"))
        try await waitForCallStart(2, gate: gate)

        await gate.release(1)
        await olderLoad.value
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertTrue(viewModel.tracks.isEmpty)

        await gate.release(2)
        try await waitForLoadCompletion(viewModel: viewModel, expectedSourceKey: sourceB)
        XCTAssertFalse(viewModel.isLoading)
    }

    private func makeHarness() -> Harness {
        let accountManager = AccountManager(keychain: TestKeychain())
        accountManager.loadAccounts()
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let artworkDownloadManager = ArtworkDownloadManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.library-concurrency.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(
                accountManager: accountManager,
                networkMonitor: networkMonitor
            )
        )

        return Harness(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository
        )
    }

    private func makeViewModel(
        harness: Harness,
        libraryRepository: LibraryRepositoryProtocol
    ) -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: libraryRepository,
            syncCoordinator: harness.syncCoordinator,
            accountManager: harness.accountManager,
            visibilityStore: LibraryVisibilityStore(),
            toastCenter: ToastCenter()
        )
    }

    private func makeAccount(libraryKey: String) -> PlexAccountConfig {
        PlexAccountConfig(
            id: "account-1",
            email: "user@example.com",
            plexUsername: "felicity",
            displayTitle: "Felicity",
            authToken: "auth-token",
            servers: [
                PlexServerConfig(
                    id: "server-1",
                    name: "Server One",
                    url: "https://server-1.example.com",
                    connections: [
                        PlexConnectionConfig(
                            uri: "https://server-1.example.com",
                            local: false,
                            relay: false,
                            protocol: "https"
                        )
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: [
                        PlexLibraryConfig(
                            id: libraryKey,
                            key: libraryKey,
                            title: "Library \(libraryKey)",
                            isEnabled: true
                        )
                    ]
                )
            ]
        )
    }

    private func seedSourceAndTrack(repository: LibraryRepository, sourceKey: String) async throws {
        let parts = sourceKey.split(separator: ":").map(String.init)
        _ = try await repository.upsertMusicSource(
            compositeKey: sourceKey,
            type: parts[0],
            accountId: parts[1],
            serverId: parts[2],
            libraryId: parts[3],
            displayName: "Library \(parts[3])",
            accountName: "Felicity"
        )
        _ = try await repository.upsertTrack(
            ratingKey: "track-\(parts[3])",
            key: "track-\(parts[3])",
            title: "Track \(parts[3])",
            artistName: nil,
            albumName: nil,
            albumRatingKey: nil,
            trackNumber: nil,
            discNumber: nil,
            duration: 120_000,
            thumbPath: nil,
            streamKey: nil,
            dateAdded: nil,
            dateModified: nil,
            lastPlayed: nil,
            rating: nil,
            playCount: nil,
            sourceCompositeKey: sourceKey
        )
    }

    private func waitForLoadCompletion(
        viewModel: LibraryViewModel,
        expectedSourceKey: String
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if viewModel.tracks.compactMap(\.sourceCompositeKey) == [expectedSourceKey],
               !viewModel.isLoading {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(viewModel.tracks.compactMap(\.sourceCompositeKey), [expectedSourceKey])
        XCTAssertFalse(viewModel.isLoading)
    }

    private func waitForCallStart(_ call: Int, gate: RepositoryCallGate) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await gate.hasStarted(call) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTFail("Repository call \(call) did not start")
        throw WaitError.timedOut
    }

    private enum WaitError: Error {
        case timedOut
    }
}
