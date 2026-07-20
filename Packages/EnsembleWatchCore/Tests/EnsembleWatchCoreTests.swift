import XCTest
import EnsembleDomain
import EnsemblePlex
@testable import EnsembleWatchCore

final class EnsembleWatchCoreTests: XCTestCase {
    func testLibraryFlagEntryDecodesFromAppKVSShape() throws {
        let data = """
        [{"key":"account:server:3","isEnabled":true}]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([WatchLibraryFlagEntry].self, from: data)

        XCTAssertEqual(entries, [WatchLibraryFlagEntry(key: "account:server:3", isEnabled: true)])
    }

    func testWatchCatalogStorePersistsLibraryFlagsInStableOrder() {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchCatalogStore(defaults: defaults)

        store.saveLibraryFlags([
            "account:server:2": false,
            "account:server:1": true
        ])

        XCTAssertEqual(store.loadLibraryFlags(), [
            "account:server:1": true,
            "account:server:2": false
        ])
    }

    func testWatchSourceLibraryFlagKeyMatchesAppKVSShape() {
        XCTAssertEqual(
            WatchSourceLibraryRow.flagKey(accountId: "account", serverId: "server", libraryKey: "3"),
            "account:server:3"
        )
    }

    func testFilteredSnapshotRemovesDisabledLibraryMediaEverywhere() {
        let selectedLibrary = makeLibrary(accountId: "account", serverId: "server", libraryKey: "3")
        let disabledSourceKey = "plex:account:server:5"
        let selectedSourceKey = selectedLibrary.sourceKey
        let snapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            libraries: [
                EnsembleLibraryReference(id: "3", key: "3", title: "Music", isEnabled: true),
                EnsembleLibraryReference(id: "5", key: "5", title: "Podcasts", isEnabled: true)
            ],
            pins: [
                makeSummary(id: "pin-selected", sourceKey: selectedSourceKey),
                makeSummary(id: "pin-disabled", sourceKey: disabledSourceKey)
            ],
            albums: [
                makeSummary(id: "album-selected", sourceKey: selectedSourceKey),
                makeSummary(id: "album-disabled", sourceKey: disabledSourceKey)
            ],
            artists: [
                makeSummary(id: "artist-selected", sourceKey: selectedSourceKey),
                makeSummary(id: "artist-disabled", sourceKey: disabledSourceKey)
            ],
            playlists: [
                makeSummary(id: "playlist-selected", sourceKey: selectedSourceKey),
                makeSummary(id: "playlist-disabled", sourceKey: disabledSourceKey)
            ],
            recentlyAdded: [
                makeSummary(id: "recent-selected", sourceKey: selectedSourceKey),
                makeSummary(id: "recent-disabled", sourceKey: disabledSourceKey)
            ]
        )

        let filtered = WatchExperienceModel.filteredSnapshot(snapshot, for: [selectedLibrary])

        XCTAssertEqual(filtered.libraries.map(\.key), ["3"])
        XCTAssertEqual(filtered.pins.map(\.id), ["pin-selected"])
        XCTAssertEqual(filtered.albums.map(\.id), ["album-selected"])
        XCTAssertEqual(filtered.artists.map(\.id), ["artist-selected"])
        XCTAssertEqual(filtered.playlists.map(\.id), ["playlist-selected"])
        XCTAssertEqual(filtered.recentlyAdded.map(\.id), ["recent-selected"])
    }

    func testFilteredSnapshotClearsEverythingWhenNoLibrariesAreSelected() {
        let snapshot = EnsemblePlexCatalogSnapshot(
            libraries: [EnsembleLibraryReference(id: "3", key: "3", title: "Music", isEnabled: true)],
            pins: [makeSummary(id: "pin", sourceKey: "plex:account:server:3")],
            albums: [makeSummary(id: "album", sourceKey: "plex:account:server:3")],
            artists: [makeSummary(id: "artist", sourceKey: "plex:account:server:3")],
            playlists: [makeSummary(id: "playlist", sourceKey: "plex:account:server:3")],
            recentlyAdded: [makeSummary(id: "recent", sourceKey: "plex:account:server:3")]
        )

        let filtered = WatchExperienceModel.filteredSnapshot(snapshot, for: [])

        XCTAssertTrue(filtered.libraries.isEmpty)
        XCTAssertTrue(filtered.pins.isEmpty)
        XCTAssertTrue(filtered.albums.isEmpty)
        XCTAssertTrue(filtered.artists.isEmpty)
        XCTAssertTrue(filtered.playlists.isEmpty)
        XCTAssertTrue(filtered.recentlyAdded.isEmpty)
    }

    func testFilteredSnapshotCollapsesLegacyPerLibraryPlaylistCopiesToServerScope() {
        let firstLibrary = makeLibrary(accountId: "account", serverId: "server", libraryKey: "3")
        let secondLibrary = makeLibrary(accountId: "account", serverId: "server", libraryKey: "5")
        let snapshot = EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [],
            albums: [],
            artists: [],
            playlists: [
                makeSummary(id: "playlist", sourceKey: firstLibrary.sourceKey),
                makeSummary(id: "playlist", sourceKey: secondLibrary.sourceKey)
            ],
            recentlyAdded: []
        )

        let filtered = WatchExperienceModel.filteredSnapshot(
            snapshot,
            for: [firstLibrary, secondLibrary]
        )

        XCTAssertEqual(filtered.playlists.map(\.id), ["playlist"])
        XCTAssertEqual(filtered.playlists.map(\.sourceKey), ["plex:account:server"])
    }

    func testClockFormatting() {
        XCTAssertEqual(TimeInterval(65).ensembleWatchClockText, "1:05")
    }

    func testPinnedItemsResolveBySourceAndTypeAcrossTheFullSnapshot() {
        let selectedSource = "plex:account:server:3"
        let otherSource = "plex:account:server:5"
        let albums = (1...50).map { makeSummary(id: "album-\($0)", sourceKey: selectedSource) }
        let snapshot = EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [],
            albums: albums + [makeSummary(id: "album-50", sourceKey: otherSource)],
            artists: [],
            playlists: [],
            recentlyAdded: []
        )
        let pins = [
            WatchPinnedReference(
                id: "album-50",
                sourceCompositeKey: otherSource,
                type: "album",
                title: "Pinned Album"
            ),
            WatchPinnedReference(
                id: "album-49",
                sourceCompositeKey: selectedSource,
                type: "artist",
                title: "Wrong Type"
            )
        ]

        let resolved = WatchExperienceModel.resolvedPinnedItems(pins, in: snapshot)

        XCTAssertEqual(resolved.map(\.sourceKey), [otherSource])
        XCTAssertEqual(resolved.map(\.id), ["album-50"])
    }

    func testPlaybackStatusMessagesFollowPauseAndResume() {
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .playing), "Playing on Apple Watch")
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .paused), "Paused on Apple Watch")
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .idle), "Ready")
    }

    @MainActor
    func testPlaybackVolumeClampsToPlayerRange() {
        let playback = WatchPlaybackController()

        playback.setVolume(1.5)
        XCTAssertEqual(playback.volume, 1)

        playback.setVolume(-0.5)
        XCTAssertEqual(playback.volume, 0)
    }

    func testWatchPlaylistGroupsMergeRegularSourcesButKeepSmartPlaylistsSeparate() {
        let playlists = [
            EnsembleMediaSummary(id: "a", kind: .playlist, title: "Café Mix", sourceKey: "plex:a:s1", isSmart: false),
            EnsembleMediaSummary(id: "b", kind: .playlist, title: " CAFE  MIX ", sourceKey: "plex:a:s2", isSmart: false),
            EnsembleMediaSummary(id: "c", kind: .playlist, title: "Cafe Mix", sourceKey: "plex:a:s3", isSmart: true)
        ]

        let groups = WatchPlaylistGroup.grouped(playlists)

        XCTAssertEqual(groups.map { $0.playlists.map(\.id) }, [["a", "b"], ["c"]])
        XCTAssertEqual(WatchExperienceModel.mergedPinnedItems(playlists).map(\.id), ["a", "c"])
        XCTAssertEqual(WatchExperienceModel.trackLoadStatus(trackCount: 4, failureCount: 1), "Some sources unavailable.")
    }

    @MainActor
    func testCachedCatalogStartsReadyAndRefreshesOnlyWhenStale() {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchCatalogStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 10_000)
        let freshSnapshot = EnsemblePlexCatalogSnapshot(
            fetchedAt: now.addingTimeInterval(-599),
            libraries: [],
            pins: [],
            albums: [],
            artists: [],
            playlists: [],
            recentlyAdded: []
        )
        store.saveSnapshot(freshSnapshot)

        let model = WatchExperienceModel(catalogStore: store)

        XCTAssertEqual(model.bootstrapState, .ready)
        XCTAssertFalse(WatchExperienceModel.catalogNeedsRefresh(freshSnapshot, now: now))
        XCTAssertTrue(WatchExperienceModel.catalogNeedsRefresh(
            EnsemblePlexCatalogSnapshot(
                fetchedAt: now.addingTimeInterval(-600),
                libraries: [],
                pins: [],
                albums: [],
                artists: [],
                playlists: [],
                recentlyAdded: []
            ),
            now: now
        ))
    }

    private func makeLibrary(
        accountId: String,
        serverId: String,
        libraryKey: String
    ) -> EnsemblePlexLibrary {
        let account = EnsembleAccountCredential(accountId: accountId, authToken: "token")
        let server = EnsemblePlexServer(
            account: account,
            id: serverId,
            name: "Server",
            token: "server-token",
            url: "https://example.com",
            connections: [],
            libraries: [
                EnsembleLibraryReference(id: libraryKey, key: libraryKey, title: "Music", isEnabled: true)
            ]
        )
        return EnsemblePlexLibrary(server: server, id: libraryKey, key: libraryKey, title: "Music")
    }

    private func makeSummary(id: String, sourceKey: String) -> EnsembleMediaSummary {
        EnsembleMediaSummary(
            id: id,
            kind: .album,
            title: id,
            sourceKey: sourceKey
        )
    }
}
