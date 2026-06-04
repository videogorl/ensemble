import XCTest
@testable import EnsembleCore

@MainActor
final class LibraryVisibilityProfileTests: XCTestCase {
    func testStorePersistsActiveProfileAndHiddenSources() {
        let suiteName = "LibraryVisibilityProfileTests.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = LibraryVisibilityStore(userDefaults: userDefaults)
        let profile = store.createProfile(name: "Focus")
        store.setActiveProfile(id: profile.id)
        store.setSourceVisibility(sourceCompositeKey: "plex:a:s:l1", isVisible: false)

        let reloadedStore = LibraryVisibilityStore(userDefaults: userDefaults)
        XCTAssertEqual(reloadedStore.activeProfileID, profile.id)
        XCTAssertEqual(reloadedStore.activeProfile.hiddenSourceCompositeKeys, ["plex:a:s:l1"])
    }

    func testHiddenSourceFilteringDoesNotChangeLibrarySyncEnabledFlags() {
        let server = PlexServerConfig(
            id: "server-1",
            name: "Server",
            url: "https://example.com",
            token: "token",
            libraries: [
                PlexLibraryConfig(id: "lib-1", key: "lib-1", title: "Music", isEnabled: true),
            ]
        )
        let account = PlexAccountConfig(
            id: "account-1",
            email: "user@example.com",
            plexUsername: "user",
            displayTitle: "User",
            authToken: "token",
            servers: [server]
        )

        let hidden = Set(["plex:account-1:server-1:lib-1"])
        let tracks = [
            Track(id: "t1", key: "/tracks/t1", title: "Hidden", sourceCompositeKey: "plex:account-1:server-1:lib-1"),
            Track(id: "t2", key: "/tracks/t2", title: "Visible", sourceCompositeKey: "plex:account-1:server-1:lib-2"),
        ]

        let filteredTracks = LibraryViewModel.filterTracksForVisibility(
            tracks,
            hiddenSourceCompositeKeys: hidden
        )

        XCTAssertEqual(filteredTracks.map(\.id), ["t2"])
        XCTAssertTrue(account.servers[0].libraries[0].isEnabled)
    }

    func testSearchVisibilityFiltersMultipleEntityTypes() {
        let hidden = Set(["plex:a:s:hidden"])

        let tracks = SearchViewModel.filterTracksForVisibility(
            [
                Track(id: "track-hidden", key: "/tracks/1", title: "Hidden", sourceCompositeKey: "plex:a:s:hidden"),
                Track(id: "track-visible", key: "/tracks/2", title: "Visible", sourceCompositeKey: "plex:a:s:visible"),
            ],
            hiddenSourceCompositeKeys: hidden
        )
        let artists = SearchViewModel.filterArtistsForVisibility(
            [
                Artist(id: "artist-hidden", key: "/artists/1", name: "Hidden", sourceCompositeKey: "plex:a:s:hidden"),
                Artist(id: "artist-visible", key: "/artists/2", name: "Visible", sourceCompositeKey: "plex:a:s:visible"),
            ],
            hiddenSourceCompositeKeys: hidden
        )
        let playlists = SearchViewModel.filterPlaylistsForVisibility(
            [
                Playlist(id: "playlist-hidden", key: "/playlists/1", title: "Hidden", sourceCompositeKey: "plex:a:s:hidden"),
                Playlist(id: "playlist-visible", key: "/playlists/2", title: "Visible", sourceCompositeKey: "plex:a:s:visible"),
            ],
            hiddenSourceCompositeKeys: hidden
        )

        XCTAssertEqual(tracks.map(\.id), ["track-visible"])
        XCTAssertEqual(artists.map(\.id), ["artist-visible"])
        XCTAssertEqual(playlists.map(\.id), ["playlist-visible"])
    }

    func testMergedMoodVisibilityStaysVisibleWhenAnySourceIsVisible() {
        let hidden = Set(["plex:a:s:hidden"])
        let moods = [
            Mood(
                id: "mood:acerbic",
                key: "/library/sections/1/mood/11",
                title: "Acerbic",
                sourceCompositeKey: SearchViewModel.mergedMoodSourceCompositeKey(
                    from: ["plex:a:s:hidden", "plex:a:s:visible"]
                )
            ),
            Mood(
                id: "mood:hidden-only",
                key: "/library/sections/1/mood/12",
                title: "Hidden Only",
                sourceCompositeKey: SearchViewModel.mergedMoodSourceCompositeKey(from: ["plex:a:s:hidden"])
            ),
        ]

        let filtered = SearchViewModel.filterMoodsForVisibility(
            moods,
            hiddenSourceCompositeKeys: hidden
        )

        XCTAssertEqual(filtered.map(\.id), ["mood:acerbic"])
    }

    func testMoodTitleNormalizationDedupesCaseAndDiacritics() {
        XCTAssertEqual(
            SearchViewModel.normalizedMoodTitleKey("  ÁCERBIC "),
            SearchViewModel.normalizedMoodTitleKey("acerbic")
        )
    }

    func testMergeMoodsForDisplayCollapsesDuplicateTitlesAndSourceKeys() {
        let merged = SearchViewModel.mergeMoodsForDisplay([
            Mood(
                id: "mood-1",
                key: "/library/sections/1/mood/11",
                title: "Acerbic",
                sourceCompositeKey: Mood.sourceReference(
                    sourceCompositeKey: "plex:a:s:one",
                    moodKey: "/library/sections/1/mood/11"
                )
            ),
            Mood(
                id: "mood-2",
                key: "/library/sections/2/mood/42",
                title: "acerbic",
                sourceCompositeKey: Mood.sourceReference(
                    sourceCompositeKey: "plex:a:s:two",
                    moodKey: "/library/sections/2/mood/42"
                )
            ),
        ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].id, "mood:acerbic")
        XCTAssertEqual(
            SearchViewModel.moodSourceCompositeKeys(from: merged[0].sourceCompositeKey),
            ["plex:a:s:one", "plex:a:s:two"]
        )
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: SearchViewModel
                    .moodSourceReferences(from: merged[0].sourceCompositeKey)
                    .compactMap { reference in
                        reference.moodKey.map { (reference.sourceCompositeKey, $0) }
                    }
            ),
            [
                "plex:a:s:one": "/library/sections/1/mood/11",
                "plex:a:s:two": "/library/sections/2/mood/42",
            ]
        )
    }

    func testHomeVisibilityFilterRemovesHiddenItemsAndEmptyHubs() {
        let hidden = Set(["plex:a:s:hidden"])
        let hiddenOnlyHub = Hub(
            id: "plex:a:hub-1",
            title: "Hidden Hub",
            type: "mixed",
            items: [
                HubItem(
                    id: "item-hidden",
                    type: "album",
                    title: "Hidden",
                    subtitle: nil,
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:a:s:hidden"
                ),
            ]
        )
        let mixedHub = Hub(
            id: "plex:a:hub-2",
            title: "Mixed Hub",
            type: "mixed",
            items: [
                HubItem(
                    id: "item-hidden-2",
                    type: "track",
                    title: "Hidden",
                    subtitle: nil,
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:a:s:hidden"
                ),
                HubItem(
                    id: "item-visible",
                    type: "track",
                    title: "Visible",
                    subtitle: nil,
                    thumbPath: nil,
                    year: nil,
                    sourceCompositeKey: "plex:a:s:visible"
                ),
            ]
        )

        let filtered = HomeViewModel.filterHubsForVisibility(
            [hiddenOnlyHub, mixedHub],
            hiddenSourceCompositeKeys: hidden
        )

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].id, "plex:a:hub-2")
        XCTAssertEqual(filtered[0].items.map(\.id), ["item-visible"])
    }
}
