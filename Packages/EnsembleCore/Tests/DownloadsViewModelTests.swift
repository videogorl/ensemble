import Combine
import EnsembleAPI
@testable import EnsembleCore
import EnsemblePersistence
import XCTest

@MainActor
final class DownloadsViewModelTests: XCTestCase {

    private final class NoopBackgroundExecutionCoordinator: OfflineDownloadBackgroundCoordinating {
        var onExecutionRequested: (() -> Void)?
        var onExpiration: (() -> Void)?
        var onBackgroundURLSessionEvents: ((_ identifier: String, _ completion: @escaping () -> Void) -> Void)?
        var onSystemWillSleep: (() -> Void)?
        var onSystemDidWake: (() -> Void)?

        func register() {}
        func requestContinuedProcessingIfAvailable(pendingTrackCount: Int) {}
        func setProgress(completedUnitCount: Int, totalUnitCount: Int) {}
        func finishCurrentTask(success: Bool) {}
        func handleBackgroundURLSessionEvents(identifier: String, completionHandler: @escaping () -> Void) {
            onBackgroundURLSessionEvents?(identifier, completionHandler)
        }
        func completeBackgroundURLSessionEvents(identifier: String) {}
        func handleSystemWillSleep() { onSystemWillSleep?() }
        func handleSystemDidWake() { onSystemDidWake?() }
    }

    func testArtistDownloadItemsIncludeSourceDisplayText() {
        let accountManager = makeAccountManager()
        let subscriberSource = "plex:subscriber:server:3"
        let freeSharedSource = "plex:free:server:3"
        let freeTestSource = "plex:free:server:1"

        let items = DownloadsViewModel.mapItems(
            from: [
                makeSnapshot(key: "target-subscriber", kind: .artist, ratingKey: "11617", sourceCompositeKey: subscriberSource, displayName: "AJR"),
                makeSnapshot(key: "target-free-shared", kind: .artist, ratingKey: "11617", sourceCompositeKey: freeSharedSource, displayName: "AJR"),
                makeSnapshot(key: "target-free-test", kind: .artist, ratingKey: "147", sourceCompositeKey: freeTestSource, displayName: "AJR"),
                makeSnapshot(key: "target-album", kind: .album, ratingKey: "album", sourceCompositeKey: subscriberSource, displayName: "The Maybe Man")
            ],
            accountManager: accountManager
        )

        let artistItems = items.filter { $0.kind == .artist }
        XCTAssertEqual(artistItems.map(\.sourceDisplayText), [
            "Free Server - Music · felicity+test@nysics.com",
            "Free Server - Music+Test · felicity+test@nysics.com",
            "Subscriber Server - Music · felicity@nysics.com"
        ])
        XCTAssertNil(items.first { $0.kind == .album }?.sourceDisplayText)
    }

    func testLibrarySummariesSeedFromEnabledLibrariesOnInit() async {
        let stack = CoreDataStack.inMemory()
        let libraryRepository = LibraryRepository(coreDataStack: stack)
        let playlistRepository = PlaylistRepository(coreDataStack: stack)
        let downloadManager = DownloadManager(coreDataStack: stack)
        let targetRepository = OfflineDownloadTargetRepository(coreDataStack: stack)
        let accountManager = makeAccountManager()
        let networkMonitor = NetworkMonitor(
            debounceNanoseconds: 1_000,
            monitorQueue: DispatchQueue(label: "downloads.view.model.test.network"),
            monitorFactory: { SystemNetworkPathMonitor() }
        )
        networkMonitor.injectNetworkStateForTesting(.online(.wifi), debounced: false)
        let serverHealthChecker = ServerHealthChecker(accountManager: accountManager, networkMonitor: networkMonitor)
        let syncCoordinator = SyncCoordinator(
            accountManager: accountManager,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            artworkDownloadManager: ArtworkDownloadManager(),
            networkMonitor: networkMonitor,
            serverHealthChecker: serverHealthChecker
        )
        let offlineDownloadService = OfflineDownloadService(
            downloadManager: downloadManager,
            targetRepository: targetRepository,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            syncCoordinator: syncCoordinator,
            networkMonitor: networkMonitor,
            backgroundExecutionCoordinator: NoopBackgroundExecutionCoordinator(),
            artworkDownloadManager: ArtworkDownloadManager(),
            toastCenter: ToastCenter(),
            lyricsService: LyricsService(syncCoordinator: syncCoordinator)
        )

        let viewModel = DownloadsViewModel(
            offlineDownloadService: offlineDownloadService,
            libraryRepository: libraryRepository,
            playlistRepository: playlistRepository,
            mutationCoordinator: MutationCoordinator(
                repository: PendingMutationRepository(coreDataStack: stack),
                networkMonitor: networkMonitor,
                syncCoordinator: syncCoordinator
            ),
            accountManager: accountManager,
            downloadManager: downloadManager
        )

        XCTAssertEqual(viewModel.librarySummaries.map { $0.sourceCompositeKey }, [
            "plex:free:server:3",
            "plex:free:server:1",
            "plex:subscriber:server:3"
        ])

        XCTAssertNil(viewModel.disambiguatingAccountName(for: viewModel.librarySummaries[0]))

        let summariesUpdated = expectation(description: "Duplicate library summary published")
        let summaryObservation = viewModel.$librarySummaries
            .first { $0.count == 4 }
            .sink { _ in summariesUpdated.fulfill() }
        defer { summaryObservation.cancel() }

        accountManager.addPlexAccount(PlexAccountConfig(
            id: "duplicate",
            email: "other@nysics.com",
            authToken: "duplicate-token",
            servers: [
                PlexServerConfig(
                    id: "other-server",
                    name: "Free Server",
                    url: "http://127.0.0.1:32401",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        await fulfillment(of: [summariesUpdated], timeout: 1)

        let collidingLibraries = viewModel.librarySummaries.filter {
            $0.serverName == "Free Server" && $0.libraryName == "Music"
        }
        XCTAssertEqual(collidingLibraries.count, 2)
        XCTAssertEqual(
            Set(collidingLibraries.compactMap(viewModel.disambiguatingAccountName(for:))),
            ["felicity+test@nysics.com", "other@nysics.com"]
        )
    }

    private func makeSnapshot(
        key: String,
        kind: CDOfflineDownloadTarget.Kind,
        ratingKey: String?,
        sourceCompositeKey: String?,
        displayName: String
    ) -> OfflineDownloadTargetSnapshot {
        OfflineDownloadTargetSnapshot(
            id: key,
            key: key,
            kind: kind,
            ratingKey: ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            status: .completed,
            totalTrackCount: 1,
            completedTrackCount: 1,
            downloadedBytes: 1024,
            progress: 1,
            failedTrackCount: 0
        )
    }

    private func makeAccountManager() -> AccountManager {
        let manager = AccountManager(keychain: TestKeychain())
        manager.addPlexAccount(PlexAccountConfig(
            id: "subscriber",
            email: "felicity@nysics.com",
            authToken: "subscriber-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Subscriber Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        manager.addPlexAccount(PlexAccountConfig(
            id: "free",
            email: "felicity+test@nysics.com",
            authToken: "free-token",
            servers: [
                PlexServerConfig(
                    id: "server",
                    name: "Free Server",
                    url: "http://127.0.0.1:32400",
                    token: "server-token",
                    libraries: [
                        PlexLibraryConfig(id: "3", key: "3", title: "Music", isEnabled: true, allowSync: true),
                        PlexLibraryConfig(id: "1", key: "1", title: "Music+Test", isEnabled: true, allowSync: true)
                    ]
                )
            ]
        ))
        return manager
    }
}
