import XCTest
import Combine
@testable import EnsembleCore

final class NavigationCoordinatorTests: XCTestCase {
    func testDestinationTargetTabs() {
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .displayArtist(id: "merged:ajr")), .artists)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .displayGenre(id: "merged:rock")), .genres)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .artistDetail(Self.artist())), .artists)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .artist(id: "artist")), .artists)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .album(id: "album")), .albums)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .playlist(id: "playlist", sourceKey: nil)), .playlists)
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .mergedPlaylist(title: "Mix", isSmart: false)), .playlists)
        XCTAssertEqual(
            NavigationCoordinator.targetTab(for: .moodTracks(mood: Mood(id: "focus", key: "/moods/focus", title: "Focus"))),
            .home
        )
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .view(.favorites)), .favorites)
    }

    func testJourneyLogDescriptionsStayRedacted() {
        XCTAssertEqual(
            NavigationCoordinator.Destination.album(id: "private-album-id", sourceKey: "private-source").journeyLogDescription,
            "album"
        )
        XCTAssertEqual(
            NavigationCoordinator.Destination.mergedPlaylist(title: "Private Playlist Title", isSmart: true).journeyLogDescription,
            "smartPlaylist"
        )
        XCTAssertEqual(
            NavigationCoordinator.Destination.view(.albums).journeyLogDescription,
            "view(Albums)"
        )
    }

    func testSystemMediaDestinationMapsSourceScopedIdentifiers() {
        XCTAssertEqual(
            NavigationCoordinator.systemMediaDestination(
                fromSourceScopedIdentifier: "album||album-1||plex://server.one/library"
            ),
            .album(id: "album-1", sourceKey: "plex://server.one/library")
        )
        XCTAssertEqual(
            NavigationCoordinator.systemMediaDestination(
                fromSourceScopedIdentifier: "playlist||playlist-1||plex://server.one"
            ),
            .playlist(id: "playlist-1", sourceKey: "plex://server.one")
        )
        XCTAssertEqual(
            NavigationCoordinator.systemMediaDestination(
                fromSourceScopedIdentifier: "track||track-1||plex://server.one/library"
            ),
            .view(.songs)
        )
    }

    @MainActor
    func testNavigateFromSearchUsesFirstVisibleTab() {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .search
        coordinator.visibleTabs = [.albums, .artists]

        coordinator.navigate(to: .artist(id: "artist"))

        XCTAssertEqual(coordinator.selectedTab, .albums)
        XCTAssertEqual(coordinator.pathSnapshot(for: .albums), [.artist(id: "artist", sourceKey: nil)])
        XCTAssertTrue(coordinator.pathSnapshot(for: .search).isEmpty)
    }

    @MainActor
    func testNavigateFromNowPlayingDefersToResolvedCurrentTab() throws {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .search
        coordinator.visibleTabs = [.playlists]

        coordinator.navigateFromNowPlaying(to: .album(id: "album", sourceKey: "server/library"))

        let pending = try XCTUnwrap(coordinator.pendingNavigation)
        XCTAssertEqual(pending.tab, .playlists)
        XCTAssertEqual(pending.destination, .album(id: "album", sourceKey: "server/library"))
    }

    @MainActor
    func testPathMutationHelpersMatchPublishedPaths() {
        let coordinator = NavigationCoordinator()
        let path: [NavigationCoordinator.Destination] = [
            .album(id: "album", sourceKey: nil),
            .artist(id: "artist", sourceKey: "server/library")
        ]

        coordinator.setPath(path, for: .albums)

        XCTAssertEqual(coordinator.albumsPath, path)
        XCTAssertEqual(coordinator.pathSnapshot(for: .albums), path)
    }

    @MainActor
    func testRedundantPathMutationsDoNotRepublishNavigationState() {
        let coordinator = NavigationCoordinator()
        let path: [NavigationCoordinator.Destination] = [
            .album(id: "album", sourceKey: nil)
        ]
        var publishCount = 0
        let cancellable = coordinator.objectWillChange.sink {
            publishCount += 1
        }

        coordinator.setPath(path, for: .albums)
        coordinator.setPath(path, for: .albums)
        coordinator.popToRoot(tab: .songs)

        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(coordinator.pathSnapshot(for: .albums), path)

        cancellable.cancel()
    }

    @MainActor
    func testPushIgnoresDuplicateTopDestination() {
        let coordinator = NavigationCoordinator()
        let destination = NavigationCoordinator.Destination.playlist(id: "playlist", sourceKey: "server/library")

        coordinator.push(destination, in: .playlists)
        coordinator.push(destination, in: .playlists)

        XCTAssertEqual(coordinator.pathSnapshot(for: .playlists), [destination])
    }

    @MainActor
    func testNavigationMarksForegroundWorkSchedulerAsNavigating() async {
        let scheduler = RecordingForegroundWorkScheduler()
        let coordinator = NavigationCoordinator(
            foregroundWorkScheduler: scheduler,
            navigationInteractionDurationNanoseconds: 10_000_000
        )

        coordinator.push(.album(id: "album", sourceKey: nil), in: .albums)

        XCTAssertEqual(scheduler.beginStates, [.navigating])
        XCTAssertTrue(scheduler.activeStates.contains(.navigating))

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(scheduler.endStates, [.navigating])
        XCTAssertFalse(scheduler.activeStates.contains(.navigating))
    }

    @MainActor
    func testRouteTransitionFlagClearsAfterDuration() async {
        let coordinator = NavigationCoordinator()

        coordinator.beginRouteTransition(in: .artists, durationNanoseconds: 10_000_000)

        XCTAssertTrue(coordinator.isRouteTransitionActive(for: .artists))
        XCTAssertFalse(coordinator.isRouteTransitionActive(for: .albums))

        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertFalse(coordinator.isRouteTransitionActive(for: .artists))
    }

    @MainActor
    func testNavigateFromExternalSearchUsesDestinationOwningTab() {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .home
        coordinator.albumsPath = [.artist(id: "stale", sourceKey: nil)]

        let destination = NavigationCoordinator.Destination.album(id: "album-1", sourceKey: "server/library")
        coordinator.navigateFromExternalSearch(to: destination)

        XCTAssertEqual(coordinator.selectedTab, .albums)
        XCTAssertEqual(coordinator.pathSnapshot(for: .albums), [destination])
        XCTAssertTrue(coordinator.pathSnapshot(for: .home).isEmpty)
        XCTAssertTrue(coordinator.isRouteTransitionActive(for: .albums))
    }

    @MainActor
    func testHandleMediaDeepLinkRoutesThroughOwningTab() throws {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .home
        coordinator.albumsPath = [.artist(id: "stale", sourceKey: nil)]
        let url = try XCTUnwrap(URL(string: "ensemble://album/album-1?sourceKey=server%2Flibrary"))

        XCTAssertTrue(coordinator.handleDeepLink(url))

        XCTAssertEqual(coordinator.selectedTab, .albums)
        XCTAssertEqual(
            coordinator.pathSnapshot(for: .albums),
            [.album(id: "album-1", sourceKey: "server/library")]
        )
    }

    @MainActor
    func testAutomationDeepLinkRoutesKnownSurface() throws {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .albums
        coordinator.songsPath = [.album(id: "stale", sourceKey: nil)]
        let url = try XCTUnwrap(URL(string: "ensemble://debug/open?surface=songs"))

        XCTAssertTrue(
            coordinator.handleDeepLink(
                url,
                automationOptions: AutomationLaunchOptions(isEnabled: true)
            )
        )

        XCTAssertEqual(coordinator.selectedTab, .songs)
        XCTAssertTrue(coordinator.pathSnapshot(for: .songs).isEmpty)
    }

    @MainActor
    func testAutomationDeepLinkRoutesHiddenSurfaceThroughMore() throws {
        let coordinator = NavigationCoordinator()
        coordinator.visibleTabs = [.home, .artists, .playlists, .search]
        coordinator.routesHiddenTabsThroughMore = true
        let url = try XCTUnwrap(URL(string: "ensemble://debug/open?surface=songs"))

        XCTAssertTrue(
            coordinator.handleDeepLink(
                url,
                automationOptions: AutomationLaunchOptions(isEnabled: true)
            )
        )

        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertEqual(coordinator.pathSnapshot(for: .settings), [.view(.songs)])
        XCTAssertTrue(coordinator.pathSnapshot(for: .songs).isEmpty)
    }

    @MainActor
    func testAutomationDeepLinkOpensProfilePresentation() throws {
        let coordinator = NavigationCoordinator()
        let url = try XCTUnwrap(URL(string: "ensemble://debug/open?surface=profile-storage"))

        XCTAssertTrue(
            coordinator.handleDeepLink(
                url,
                automationOptions: AutomationLaunchOptions(isEnabled: true)
            )
        )

        XCTAssertEqual(coordinator.activeAuxiliaryPresentation, .profile)
    }

    @MainActor
    func testNavigateFromExternalSearchRoutesHiddenDetailThroughMore() {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .home
        coordinator.visibleTabs = [.home, .artists, .playlists, .search]
        coordinator.routesHiddenTabsThroughMore = true
        coordinator.albumsPath = [.artist(id: "stale", sourceKey: nil)]
        coordinator.settingsPath = [.view(.downloads)]

        let destination = NavigationCoordinator.Destination.album(id: "album-1", sourceKey: "server/library")
        coordinator.navigateFromExternalSearch(to: destination)

        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertEqual(coordinator.pathSnapshot(for: .settings), [.view(.albums), destination])
        XCTAssertTrue(coordinator.pathSnapshot(for: .albums).isEmpty)
    }

    @MainActor
    func testNavigateFromExternalSearchRoutesHiddenPlaylistThroughMore() {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .home
        coordinator.visibleTabs = [.home, .artists, .search, .favorites]
        coordinator.routesHiddenTabsThroughMore = true
        coordinator.playlistsPath = [.album(id: "stale", sourceKey: nil)]

        let destination = NavigationCoordinator.Destination.playlist(id: "playlist-1", sourceKey: "server")
        coordinator.navigateFromExternalSearch(to: destination)

        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertEqual(coordinator.pathSnapshot(for: .settings), [.view(.playlists), destination])
        XCTAssertTrue(coordinator.pathSnapshot(for: .playlists).isEmpty)
    }

    @MainActor
    func testNavigateFromExternalSearchRoutesHiddenViewThroughMore() {
        let coordinator = NavigationCoordinator()
        coordinator.selectedTab = .home
        coordinator.visibleTabs = [.home, .artists, .playlists, .search]
        coordinator.routesHiddenTabsThroughMore = true

        coordinator.navigateFromExternalSearch(to: .view(.songs))

        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertEqual(coordinator.pathSnapshot(for: .settings), [.view(.songs)])
        XCTAssertTrue(coordinator.pathSnapshot(for: .songs).isEmpty)
    }

    @MainActor
    func testExternalSearchRouteQueuesUntilSceneCoordinatorIsActive() {
        let destination = NavigationCoordinator.Destination.playlist(id: "playlist", sourceKey: "server")

        XCTAssertFalse(NavigationCoordinator.routeExternalSearchInActiveScene(to: destination))

        let coordinator = NavigationCoordinator()
        NavigationCoordinator.setActiveSceneCoordinator(coordinator)
        defer {
            NavigationCoordinator.clearActiveSceneCoordinator(coordinator)
        }

        XCTAssertEqual(coordinator.selectedTab, .playlists)
        XCTAssertEqual(coordinator.pathSnapshot(for: .playlists), [destination])
    }

    @MainActor
    func testExternalSearchRouteUsesActiveSceneCoordinator() {
        let coordinator = NavigationCoordinator()
        NavigationCoordinator.setActiveSceneCoordinator(coordinator)
        defer {
            NavigationCoordinator.clearActiveSceneCoordinator(coordinator)
        }

        let destination = NavigationCoordinator.Destination.album(id: "album", sourceKey: "server/library")

        XCTAssertTrue(NavigationCoordinator.routeExternalSearchInActiveScene(to: destination))
        XCTAssertEqual(coordinator.selectedTab, .albums)
        XCTAssertEqual(coordinator.pathSnapshot(for: .albums), [destination])
    }

    private static func artist() -> Artist {
        Artist(id: "artist", key: "/library/metadata/artist", name: "Artist")
    }
}

@MainActor
private final class RecordingForegroundWorkScheduler: ForegroundWorkScheduling, @unchecked Sendable {
    var activeStates: Set<ForegroundInteractionState> = []
    var beginStates: [ForegroundInteractionState] = []
    var endStates: [ForegroundInteractionState] = []
    var startupSyncInFlight = false
    var isForegroundActive = true

    var isIdleForNonessentialWork: Bool {
        activeStates.isEmpty && !startupSyncInFlight && isForegroundActive
    }

    func beginInteraction(_ state: ForegroundInteractionState) {
        beginStates.append(state)
        activeStates.insert(state)
    }

    func endInteraction(_ state: ForegroundInteractionState) {
        endStates.append(state)
        activeStates.remove(state)
    }

    func setStartupSyncInFlight(_ inFlight: Bool) {
        startupSyncInFlight = inFlight
    }

    func setForegroundActive(_ active: Bool) {
        isForegroundActive = active
    }

    func waitUntilAllowed(_ kind: ForegroundWorkKind, policy: ForegroundWorkPolicy) async -> Bool {
        isIdleForNonessentialWork
    }
}
