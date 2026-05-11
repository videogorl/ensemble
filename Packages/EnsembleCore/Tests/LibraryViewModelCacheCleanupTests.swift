import XCTest
import EnsembleAPI
import EnsemblePersistence
@testable import EnsembleCore

@MainActor
final class LibraryViewModelCacheCleanupTests: XCTestCase {
    private actor CleanupRecorder {
        private var sourceKeys: [String] = []

        func record(_ sourceKey: String) {
            sourceKeys.append(sourceKey)
        }

        func recordedSourceKeys() -> [String] {
            sourceKeys
        }
    }

    private final class TestKeychain: KeychainServiceProtocol, @unchecked Sendable {
        private var storage: [String: String] = [:]

        func save(_ value: String, forKey key: String) throws {
            storage[key] = value
        }

        func get(_ key: String) throws -> String? {
            storage[key]
        }

        func delete(_ key: String) throws {
            storage.removeValue(forKey: key)
        }
    }

    func testLoadLibraryPurgesAllCachedLibraryDataWhenNoAccountsExist() async throws {
        let harness = makeHarness()
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedOfflineDownload(harness: harness, sourceKey: "plex:account-1:server-1:lib-1", trackRatingKey: "track-lib-1")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        XCTAssertTrue(viewModel.albums.isEmpty)
        XCTAssertTrue(viewModel.artists.isEmpty)
        XCTAssertTrue(viewModel.genres.isEmpty)
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
        try await waitForDeferredOfflineCleanup(harness: harness)
    }

    func testLoadLibraryPurgesAllCachedLibraryDataWhenNoLibrariesAreEnabled() async throws {
        let harness = makeHarness()
        harness.accountManager.addPlexAccount(
            makeAccount(libraries: [("lib-1", "Library One", false)])
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        XCTAssertTrue(viewModel.tracks.isEmpty)
        try await waitForDeferredCleanup(repository: harness.libraryRepository)
    }

    func testLoadLibraryPurgesCachedSourcesThatAreNoLongerEnabled() async throws {
        let cleanupRecorder = CleanupRecorder()
        let harness = makeHarness { sourceKey in
            await cleanupRecorder.record(sourceKey)
        }
        harness.accountManager.addPlexAccount(
            makeAccount(
                libraries: [
                    ("lib-1", "Library One", true),
                    ("lib-2", "Library Two", false)
                ]
            )
        )
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-1")
        try await seedSourceAndTrack(repository: harness.libraryRepository, sourceKey: "plex:account-1:server-1:lib-2")

        let viewModel = makeViewModel(harness: harness)
        await viewModel.loadLibrary()

        try await waitForDeferredCleanup(repository: harness.libraryRepository, expectedSourceKeys: ["plex:account-1:server-1:lib-1"])

        let sourceKeys = Set(try await harness.libraryRepository.fetchMusicSources().map(\.compositeKey))
        XCTAssertEqual(sourceKeys, ["plex:account-1:server-1:lib-1"])

        let trackSourceKeys = Set(try await harness.libraryRepository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(trackSourceKeys, ["plex:account-1:server-1:lib-1"])
        let cleanedSourceKeys = await cleanupRecorder.recordedSourceKeys()
        XCTAssertEqual(cleanedSourceKeys, ["plex:account-1:server-1:lib-2"])
    }

    private struct Harness {
        let accountManager: AccountManager
        let syncCoordinator: SyncCoordinator
        let libraryRepository: LibraryRepository
        let downloadManager: DownloadManager
        let targetRepository: OfflineDownloadTargetRepository
        let sourceCacheCleanupService: SourceCacheCleaning
    }

    private func makeHarness(
        clearLyricsCache: @escaping SourceCacheCleanupService.LyricsCacheCleanup = { _ in },
        clearAllLyricsCaches: @escaping SourceCacheCleanupService.AllLyricsCacheCleanup = {}
    ) -> Harness {
        let accountManager = AccountManager(keychain: TestKeychain())
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let targetRepository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let artworkDownloadManager = ArtworkDownloadManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "test.library-cache-cleanup.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: artworkDownloadManager,
            networkMonitor: networkMonitor,
            serverHealthChecker: ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        )
        let sourceCacheCleanupService = SourceCacheCleanupService(
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            artworkDownloadManager: artworkDownloadManager,
            fetchArtworkRatingKeys: { sourceKey in
                try await libraryRepository.fetchArtworkRatingKeys(forSourceCompositeKey: sourceKey)
            },
            clearLyricsCache: clearLyricsCache,
            clearAllLyricsCaches: clearAllLyricsCaches
        )
        syncCoordinator.sourceCacheCleanupService = sourceCacheCleanupService

        return Harness(
            accountManager: accountManager,
            syncCoordinator: syncCoordinator,
            libraryRepository: libraryRepository,
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            sourceCacheCleanupService: sourceCacheCleanupService
        )
    }

    private func waitForDeferredCleanup(
        repository: LibraryRepository,
        expectedSourceKeys: Set<String> = []
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
            let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
            if sourceKeys == expectedSourceKeys && trackSourceKeys == expectedSourceKeys {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let sourceKeys = Set(try await repository.fetchMusicSources().map(\.compositeKey))
        let trackSourceKeys = Set(try await repository.fetchTracks().compactMap(\.sourceCompositeKey))
        XCTAssertEqual(sourceKeys, expectedSourceKeys)
        XCTAssertEqual(trackSourceKeys, expectedSourceKeys)
    }

    private func waitForDeferredOfflineCleanup(harness: Harness) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let downloads = try await harness.downloadManager.fetchDownloads()
            let targets = try await harness.targetRepository.fetchTargets()
            if downloads.isEmpty && targets.isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let downloads = try await harness.downloadManager.fetchDownloads()
        let targets = try await harness.targetRepository.fetchTargets()
        XCTAssertTrue(downloads.isEmpty)
        XCTAssertTrue(targets.isEmpty)
    }

    private func makeViewModel(harness: Harness) -> LibraryViewModel {
        LibraryViewModel(
            libraryRepository: harness.libraryRepository,
            syncCoordinator: harness.syncCoordinator,
            sourceCacheCleanupService: harness.sourceCacheCleanupService,
            accountManager: harness.accountManager,
            visibilityStore: LibraryVisibilityStore(),
            toastCenter: ToastCenter()
        )
    }

    private func makeAccount(
        libraries: [(key: String, title: String, enabled: Bool)]
    ) -> PlexAccountConfig {
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
                        PlexConnectionConfig(uri: "https://server-1.example.com", local: false, relay: false, protocol: "https")
                    ],
                    token: "token-1",
                    platform: "Linux",
                    libraries: libraries.map { library in
                        PlexLibraryConfig(
                            id: library.key,
                            key: library.key,
                            title: library.title,
                            isEnabled: library.enabled
                        )
                    }
                )
            ]
        )
    }

    private func seedSourceAndTrack(repository: LibraryRepository, sourceKey: String) async throws {
        let parts = sourceKey.split(separator: ":").map(String.init)
        XCTAssertEqual(parts.count, 4)
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

    private func seedOfflineDownload(harness: Harness, sourceKey: String, trackRatingKey: String) async throws {
        _ = try await harness.downloadManager.createDownload(
            forTrackRatingKey: trackRatingKey,
            sourceCompositeKey: sourceKey,
            quality: "high"
        )
        _ = try await harness.targetRepository.upsertTarget(
            key: "library:\(sourceKey)",
            kind: .library,
            ratingKey: nil,
            sourceCompositeKey: sourceKey,
            displayName: "Library"
        )
        try await harness.targetRepository.replaceMemberships(
            targetKey: "library:\(sourceKey)",
            trackReferences: [
                OfflineTrackReference(trackRatingKey: trackRatingKey, trackSourceCompositeKey: sourceKey)
            ]
        )
    }
}
