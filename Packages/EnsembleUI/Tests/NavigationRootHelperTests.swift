import XCTest
@testable import EnsembleUI
import EnsembleCore

final class NavigationRootHelperTests: XCTestCase {
    func testSidebarSelectionMappingForDestinations() {
        XCTAssertEqual(
            SidebarSelection.selection(for: .displayArtist(id: "merged:ajr"), fallback: nil),
            .library(.artists)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .artist(id: "artist", sourceKey: "server/library"), fallback: nil),
            .library(.artists)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .album(id: "album", sourceKey: nil), fallback: nil),
            .library(.albums)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .playlist(id: "playlist", sourceKey: "server/library"), fallback: nil),
            .playlist(id: "playlist", sourceKey: "server/library")
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .mergedPlaylist(title: "Mix", isSmart: true), fallback: nil),
            .mergedPlaylist(title: "Mix", isSmart: true)
        )
        XCTAssertEqual(
            SidebarSelection.selection(
                for: .moodTracks(mood: Mood(id: "focus", key: "/moods/focus", title: "Focus")),
                fallback: nil
            ),
            .library(.home)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .view(.favorites), fallback: nil),
            .library(.favorites)
        )
    }

    func testSidebarSelectionFallsBackForAuxiliaryViewDestinations() {
        let fallback = SidebarSelection.pin(id: "album", sourceKey: "server/library", type: .album)

        XCTAssertEqual(SidebarSelection.selection(for: .view(.downloads), fallback: fallback), fallback)
        XCTAssertEqual(SidebarSelection.selection(for: .view(.settings), fallback: nil), .library(.home))
    }

    func testSidebarSelectionCorrespondingTabs() {
        XCTAssertEqual(SidebarSelection.library(.artists).correspondingTab, .artists)
        XCTAssertEqual(SidebarSelection.playlist(id: "playlist", sourceKey: nil).correspondingTab, .playlists)
        XCTAssertEqual(SidebarSelection.mergedPlaylist(title: "Mix", isSmart: false).correspondingTab, .playlists)
        XCTAssertNil(SidebarSelection.pin(id: "artist", sourceKey: "server/library", type: .artist).correspondingTab)
    }

    func testStageFlowPolicyResolvesVisibleStageFlowTabs() {
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .albums,
                morePath: [],
                isPhone: true
            ),
            .albums
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .playlists,
                morePath: [],
                isPhone: true
            ),
            .playlists
        )
    }

    func testStageFlowPolicyResolvesHiddenAlbumsFromMorePath() {
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                morePath: [.view(.albums)],
                isPhone: true
            ),
            .albums
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                morePath: [.view(.albums), .album(id: "album", sourceKey: nil)],
                isPhone: true
            ),
            .albums
        )
    }

    func testStageFlowPolicyResolvesHiddenPlaylistsFromMorePath() {
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                morePath: [.view(.playlists)],
                isPhone: true
            ),
            .playlists
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                morePath: [.view(.playlists), .playlist(id: "playlist", sourceKey: nil)],
                isPhone: true
            ),
            .playlists
        )
    }

    func testStageFlowPolicyRejectsUnsupportedAndNonPhoneRoutes() {
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .artists,
                morePath: [],
                isPhone: true
            )
        )
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                morePath: [.view(.artists)],
                isPhone: true
            )
        )
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .albums,
                morePath: [],
                isPhone: false
            )
        )
    }

    func testInitialSelectionPolicyPreservesVisibleExternalRoute() {
        let barTabs: [TabItem] = [.home, .artists, .playlists, .search]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.rootTab(selectedTab: .playlists, barTabs: barTabs),
            .playlists
        )
        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .playlists,
                selectedPath: [.playlist(id: "playlist", sourceKey: "server")],
                barTabs: barTabs
            ),
            .preserve
        )
    }

    func testInitialSelectionPolicyFallsBackWhenDefaultTabIsHidden() {
        let barTabs: [TabItem] = [.artists, .playlists, .search, .favorites]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.rootTab(selectedTab: .home, barTabs: barTabs),
            .artists
        )
        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .home,
                selectedPath: [],
                barTabs: barTabs
            ),
            .select(.artists)
        )
    }

    func testInitialSelectionPolicyRoutesHiddenExternalPathThroughMore() {
        let barTabs: [TabItem] = [.home, .artists, .playlists, .search]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .albums,
                selectedPath: [.album(id: "album", sourceKey: "server/library")],
                barTabs: barTabs
            ),
            .routeThroughMore(.albums)
        )
    }

    @MainActor
    func testNavigationCoordinatorPathBindingWritesThroughToCoordinator() {
        let coordinator = NavigationCoordinator()
        let binding = coordinator.pathBinding(for: .artists)
        let path: [NavigationCoordinator.Destination] = [
            .artist(id: "artist", sourceKey: "server/library")
        ]

        binding.wrappedValue = path

        XCTAssertEqual(coordinator.artistsPath, path)
        XCTAssertEqual(binding.wrappedValue, path)
    }
}
