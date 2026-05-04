import XCTest
@testable import EnsembleCore

final class NavigationCoordinatorTests: XCTestCase {
    func testDestinationTargetTabs() {
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
    func testPushIgnoresDuplicateTopDestination() {
        let coordinator = NavigationCoordinator()
        let destination = NavigationCoordinator.Destination.playlist(id: "playlist", sourceKey: "server/library")

        coordinator.push(destination, in: .playlists)
        coordinator.push(destination, in: .playlists)

        XCTAssertEqual(coordinator.pathSnapshot(for: .playlists), [destination])
    }
}
