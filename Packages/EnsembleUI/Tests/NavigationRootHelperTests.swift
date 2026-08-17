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
            SidebarSelection.selection(for: .displayGenre(id: "merged:rock"), fallback: nil),
            .library(.genres)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .artistDetail(Self.artist()), fallback: nil),
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
            SidebarSelection.selection(for: .albumDetail(Self.album()), fallback: nil),
            .library(.albums)
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .playlist(id: "playlist", sourceKey: "server/library"), fallback: nil),
            .playlist(id: "playlist", sourceKey: "server/library")
        )
        XCTAssertEqual(
            SidebarSelection.selection(for: .playlistDetail(Self.playlist()), fallback: nil),
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
            SidebarSelection.selection(for: .searchResults(section: .songs), fallback: nil),
            .library(.search)
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
                navigationPath: [],
                isPhone: true
            ),
            .albums
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .playlists,
                navigationPath: [],
                isPhone: true
            ),
            .playlists
        )
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .playlists,
                navigationPath: [.playlist(id: "playlist", sourceKey: nil)],
                isPhone: true
            )
        )
    }

    func testStageFlowPolicyResolvesHiddenAlbumsFromMorePath() {
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                navigationPath: [.view(.albums)],
                isPhone: true
            ),
            .albums
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                navigationPath: [.view(.albums), .album(id: "album", sourceKey: nil)],
                isPhone: true
            ),
            nil
        )
    }

    func testStageFlowPolicyResolvesHiddenPlaylistsFromMorePath() {
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                navigationPath: [.view(.playlists)],
                isPhone: true
            ),
            .playlists
        )
        XCTAssertEqual(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                navigationPath: [.view(.playlists), .playlist(id: "playlist", sourceKey: nil)],
                isPhone: true
            ),
            nil
        )
    }

    func testStageFlowPolicyRejectsUnsupportedAndNonPhoneRoutes() {
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .artists,
                navigationPath: [],
                isPhone: true
            )
        )
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .settings,
                navigationPath: [.view(.artists)],
                isPhone: true
            )
        )
        XCTAssertNil(
            MainTabStageFlowPolicy.activeRootTab(
                selectedRootTab: .albums,
                navigationPath: [],
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

    func testInitialSelectionPolicySelectsFirstVisibleTabOnFreshLaunch() {
        let barTabs: [TabItem] = [.albums, .home, .artists, .playlists]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialRootTab(
                selectedTab: .home,
                selectedPath: [],
                barTabs: barTabs
            ),
            .albums
        )
        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .home,
                selectedPath: [],
                barTabs: barTabs
            ),
            .select(.albums)
        )
    }

    func testInitialSelectionPolicyPreservesHomeWhenItHasALaunchPath() {
        let barTabs: [TabItem] = [.albums, .home, .artists, .playlists]
        let path: [NavigationCoordinator.Destination] = [.album(id: "album", sourceKey: "server/library")]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialRootTab(
                selectedTab: .home,
                selectedPath: path,
                barTabs: barTabs
            ),
            .home
        )
        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .home,
                selectedPath: path,
                barTabs: barTabs
            ),
            .preserve
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

    func testInitialSelectionPolicyRoutesHiddenLaunchSurfaceThroughMore() {
        let barTabs: [TabItem] = [.home, .artists, .playlists, .search]

        XCTAssertEqual(
            MainTabInitialSelectionPolicy.initialResolution(
                selectedTab: .songs,
                selectedPath: [],
                barTabs: barTabs
            ),
            .routeThroughMore(.songs)
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

    func testConcreteAlbumDetailDestinationTargetsAlbums() {
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .albumDetail(Self.album())), .albums)
    }

    func testConcreteArtistDetailDestinationTargetsArtists() {
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .artistDetail(Self.artist())), .artists)
    }

    func testConcretePlaylistDetailDestinationTargetsPlaylists() {
        XCTAssertEqual(NavigationCoordinator.targetTab(for: .playlistDetail(Self.playlist())), .playlists)
    }

    @MainActor
    func testSearchPlaylistDestinationRoutesMergedAndSingleResults() {
        let first = Self.playlist(id: "first", source: "plex:account:server")
        let second = Self.playlist(id: "second", source: MusicSourceIdentifier.appleMusic.compositeKey)
        let merged = DisplayPlaylist.merged(
            title: "Ambient Electric",
            isSmart: false,
            playlists: [first, second]
        )
        let single = DisplayPlaylist.single(first)

        XCTAssertEqual(
            SearchView.playlistDestination(for: merged),
            .mergedPlaylist(title: "Ambient Electric", isSmart: false)
        )
        XCTAssertEqual(
            SearchView.playlistDestination(for: single),
            .playlistDetail(first)
        )
    }

    func testLegacyNestedNavigationResolvesDestinationAtDepth() {
        let album = Self.album()
        let path: [NavigationCoordinator.Destination] = [
            .view(.albums),
            .albumDetail(album),
            .artist(id: "artist", sourceKey: "server/library")
        ]

        XCTAssertEqual(NestedNavigationLink.destination(in: path, at: 0), .view(.albums))
        XCTAssertEqual(
            NestedNavigationLink.destination(in: path, at: 1),
            .albumDetail(album)
        )
        XCTAssertEqual(
            NestedNavigationLink.destination(in: path, at: 2),
            .artist(id: "artist", sourceKey: "server/library")
        )
        XCTAssertNil(NestedNavigationLink.destination(in: path, at: 3))
    }

    func testLegacyNestedNavigationTrimsPathWhenNestedLinkDeactivates() {
        let album = Self.album()
        let path: [NavigationCoordinator.Destination] = [
            .view(.albums),
            .albumDetail(album),
            .artist(id: "artist", sourceKey: "server/library")
        ]

        XCTAssertEqual(
            NestedNavigationLink.pathAfterDeactivatingLink(at: 2, in: path),
            [.view(.albums), .albumDetail(album)]
        )
        XCTAssertEqual(
            NestedNavigationLink.pathAfterDeactivatingLink(at: 1, in: path),
            [.view(.albums)]
        )
        XCTAssertEqual(
            NestedNavigationLink.pathAfterDeactivatingLink(at: 0, in: path),
            []
        )
    }

    private static func album() -> Album {
        Album(id: "album", key: "/library/metadata/album", title: "Album", artistName: "Artist")
    }

    private static func artist() -> Artist {
        Artist(id: "artist", key: "/library/metadata/artist", name: "Artist")
    }

    private static func playlist() -> Playlist {
        playlist(id: "playlist", source: "server/library")
    }

    private static func playlist(id: String, source: String) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)/items",
            title: "Playlist",
            sourceCompositeKey: source
        )
    }
}
