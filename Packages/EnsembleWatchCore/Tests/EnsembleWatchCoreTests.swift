import XCTest
import EnsembleDomain
import EnsemblePersistence
import EnsemblePlex
import MediaPlayer
@testable import EnsembleWatchCore

final class EnsembleWatchCoreTests: XCTestCase {
    func testLibraryFlagEntryDecodesFromAppKVSShape() throws {
        let data = """
        [{"key":"account:server:3","isEnabled":true,"updatedAt":42}]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([EnsembleLibraryFlagEntry].self, from: data)

        XCTAssertEqual(entries, [
            EnsembleLibraryFlagEntry(key: "account:server:3", isEnabled: true, updatedAt: 42)
        ])
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

    func testWatchPreferenceDecodingPreservesMissingPinsAndAcceptsDuplicateFlags() throws {
        XCTAssertNil(WatchCloudPreferenceStore.decodePinnedReferences(nil))
        XCTAssertEqual(
            WatchCloudPreferenceStore.decodePinnedReferences(try JSONEncoder().encode([WatchPinnedReference]())),
            []
        )

        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(try JSONEncoder().encode([
            EnsembleLibraryFlagEntry(key: "library", isEnabled: false),
            EnsembleLibraryFlagEntry(key: "library", isEnabled: true)
        ]), forKey: "ensemble.watch.libraryFlags")

        XCTAssertEqual(WatchCatalogStore(defaults: defaults).loadLibraryFlags(), ["library": true])
    }

    func testWatchCatalogStorePersistsCatalogRowsAndLoadsHomeOnly() async throws {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = WatchCatalogStore(
            defaults: defaults,
            coreDataStack: .inMemory()
        )
        let pin = makeSummary(id: "pin", sourceKey: "plex:account:server:1")
        let album = makeSummary(id: "album", sourceKey: "plex:account:server:1")
        let snapshot = EnsemblePlexCatalogSnapshot(
            libraries: [
                EnsembleLibraryReference(id: "1", key: "1", title: "Music", isEnabled: true),
                EnsembleLibraryReference(id: "3", key: "3", title: "Music", isEnabled: true)
            ],
            pins: [pin],
            albums: [album],
            artists: [],
            playlists: [],
            recentlyAdded: [album],
            tracks: [makeTrack(id: "track")]
        )

        try await store.saveSnapshot(snapshot)
        let loaded = try await store.loadSnapshot()
        let home = try await store.loadHomeSnapshot()

        XCTAssertNil(defaults.data(forKey: "ensemble.watch.catalogSnapshot"))
        XCTAssertEqual(loaded, snapshot)
        XCTAssertEqual(home?.pins, [pin])
        XCTAssertEqual(home?.recentlyAdded, [album])
        XCTAssertEqual(home?.albums, [])
        XCTAssertEqual(home?.tracks, [])
    }

    func testWatchPlaybackQueueStoreRoundTripsAllQueueState() {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchPlaybackQueueStore(defaults: defaults)
        let item = WatchQueueItem(
            id: "current",
            track: makeTrack(id: "track"),
            source: .continuePlaying
        )
        let snapshot = WatchPlaybackQueueSnapshot(
            queue: [item],
            originalQueue: [item],
            history: [item],
            currentIndex: 0,
            currentTime: 42,
            isShuffleEnabled: true,
            repeatMode: .one,
            isAutoplayEnabled: true,
            hasUserQueueEdits: true
        )

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func testWatchPlaybackQueueStoreMigratesDefaultsToAtomicFile() throws {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshotURL = directory.appendingPathComponent("queue.json")
        let item = WatchQueueItem(track: makeTrack(id: "track"))
        let snapshot = WatchPlaybackQueueSnapshot(queue: [item], currentIndex: 0)
        defaults.set(try JSONEncoder().encode(snapshot), forKey: "ensemble.watch.playbackQueue")
        let store = WatchPlaybackQueueStore(defaults: defaults, snapshotURL: snapshotURL)

        XCTAssertEqual(store.load(), snapshot)
        XCTAssertNil(defaults.data(forKey: "ensemble.watch.playbackQueue"))
        XCTAssertEqual(
            try JSONDecoder().decode(WatchPlaybackQueueSnapshot.self, from: Data(contentsOf: snapshotURL)),
            snapshot
        )
    }

    func testWatchPlaybackQueuePersistenceDropsOnlyFutureAutoplayItems() {
        let manual = makeTrack(id: "manual")
        let currentAutoplay = makeTrack(id: "current-autoplay")
        let futureAutoplay = makeTrack(id: "future-autoplay")
        var queue = WatchPlaybackQueue()

        _ = queue.replace(with: [manual, currentAutoplay])
        queue.appendAutoplay([futureAutoplay])
        _ = queue.advance()

        let persisted = queue.snapshotForPersistence()

        XCTAssertEqual(persisted.queue.map(\.track.id), ["manual", "current-autoplay"])
        XCTAssertEqual(persisted.originalQueue.map(\.track.id), ["manual", "current-autoplay"])
        XCTAssertEqual(persisted.currentIndex, 1)
        XCTAssertTrue(persisted.isAutoplayEnabled == false)
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

    func testHiddenMediaUsesExactIdentityAndCascadesFromArtistsAndAlbums() {
        let sourceKey = "plex:account:server:3"
        let artist = HiddenMediaIdentity(kind: .artist, itemID: "artist", sourceCompositeKey: sourceKey)
        let album = HiddenMediaIdentity(kind: .album, itemID: "album", sourceCompositeKey: sourceKey)
        let playlist = HiddenMediaIdentity(kind: .playlist, itemID: "playlist", sourceCompositeKey: sourceKey)
        let hiddenTrack = HiddenMediaIdentity(kind: .track, itemID: "track", sourceCompositeKey: sourceKey)
        let albumSummary = EnsembleMediaSummary(
            id: "album",
            kind: .album,
            title: "Album",
            artistID: "artist",
            sourceKey: sourceKey
        )
        let track = EnsembleTrack(
            id: "track",
            title: "Track",
            albumID: "album",
            artistID: "artist",
            sourceKey: sourceKey
        )
        let playlistSummary = EnsembleMediaSummary(
            id: "playlist",
            kind: .playlist,
            title: "Playlist",
            sourceKey: sourceKey
        )

        XCTAssertTrue(WatchExperienceModel.isHidden(albumSummary, hiddenIdentities: [artist]))
        XCTAssertTrue(WatchExperienceModel.isHidden(albumSummary, hiddenIdentities: [album]))
        XCTAssertTrue(WatchExperienceModel.isHidden(playlistSummary, hiddenIdentities: [playlist]))
        XCTAssertTrue(WatchExperienceModel.isHidden(track, hiddenIdentities: [hiddenTrack]))
        XCTAssertTrue(WatchExperienceModel.isHidden(track, hiddenIdentities: [artist]))
        XCTAssertTrue(WatchExperienceModel.isHidden(track, hiddenIdentities: [album]))
        XCTAssertFalse(WatchExperienceModel.isHidden(track, hiddenIdentities: [
            HiddenMediaIdentity(kind: .artist, itemID: "artist", sourceCompositeKey: "plex:other:source")
        ]))
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

    func testPinnedItemsHaveNoWatchDisplayCap() {
        let sourceKey = "plex:account:server:3"
        let albums = (1...13).map { makeSummary(id: "album-\($0)", sourceKey: sourceKey) }
        let snapshot = EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [],
            albums: albums,
            artists: [],
            playlists: [],
            recentlyAdded: []
        )
        let pins = albums.map {
            WatchPinnedReference(id: $0.id, sourceCompositeKey: sourceKey, type: "album", title: $0.title)
        }

        XCTAssertEqual(WatchExperienceModel.resolvedPinnedItems(pins, in: snapshot).count, 13)
    }

    func testPlaybackStatusMessagesFollowPauseAndResume() {
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .playing), "Playing on Apple Watch")
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .paused), "Paused on Apple Watch")
        XCTAssertEqual(WatchExperienceModel.playbackStatusMessage(for: .idle), "Ready")
    }

    @MainActor
    func testNowPlayingInfoPublishesTrackPlaybackAndQueueMetadata() {
        let track = EnsembleTrack(
            id: "track",
            title: "Track",
            artistName: "Artist",
            albumTitle: "Album",
            duration: 180,
            sourceKey: "plex:account:server:3"
        )
        let info = WatchPlaybackController.nowPlayingInfo(
            for: track,
            status: .playing,
            elapsedTime: 12,
            queueIndex: 2,
            queueCount: 8
        )

        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, track.title)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int, 2)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackQueueCount] as? Int, 8)
        XCTAssertEqual(
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String,
            "\(track.sourceKey):\(track.id)"
        )
    }

    func testWatchPlaybackQueueStartsAtRequestedTrackAndAdvancesByIndex() {
        let first = makeTrack(id: "first")
        let duplicate = makeTrack(id: "duplicate", playlistItemID: "item")
        let last = makeTrack(id: "last")
        var queue = WatchPlaybackQueue()

        XCTAssertEqual(
            queue.replace(with: [first, duplicate, duplicate, last], startingAt: duplicate)?.id,
            "duplicate"
        )
        XCTAssertEqual(queue.currentIndex, 1)
        XCTAssertEqual(queue.nextTrack?.id, "duplicate")
        XCTAssertEqual(queue.advance()?.id, "duplicate")
        XCTAssertEqual(queue.currentIndex, 2)
        XCTAssertEqual(queue.advance()?.id, "last")
        XCTAssertFalse(queue.canAdvance)
        XCTAssertNil(queue.advance())
        XCTAssertEqual(queue.movePrevious()?.id, "duplicate")
    }

    @MainActor
    func testWatchPlaybackControllerAutomaticallyAdvancesToPreloadedTrack() async {
        let playback = WatchPlaybackController()
        let first = makeTrack(id: "first")
        let second = makeTrack(id: "second")
        let audioURL = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        let advanced = expectation(description: "Preloaded track became current")
        playback.playbackAdvancedHandler = { track in
            if track.id == second.id { advanced.fulfill() }
        }

        playback.play(track: first, url: audioURL)
        XCTAssertTrue(playback.preload(track: second, url: audioURL))
        await fulfillment(of: [advanced], timeout: 3)
        XCTAssertEqual(playback.currentTrack?.id, "second")
        playback.stop()
    }

    func testWatchPlaybackQueueShufflePreservesEveryTrack() {
        let tracks = (1...12).map { makeTrack(id: "track-\($0)") }
        var queue = WatchPlaybackQueue()

        XCTAssertNotNil(queue.replace(with: tracks, shuffled: true))
        XCTAssertEqual(queue.currentIndex, 0)
        XCTAssertEqual(Set(queue.tracks.map(\.id)), Set(tracks.map(\.id)))

        var playedTrackIDs = [queue.currentTrack?.id].compactMap { $0 }
        while let track = queue.advance() {
            playedTrackIDs.append(track.id)
        }
        XCTAssertEqual(Set(playedTrackIDs), Set(tracks.map(\.id)))
        XCTAssertEqual(playedTrackIDs.count, tracks.count)
    }

    func testWatchShuffleKeepsSelectedAutoplayCurrentExactlyOnce() {
        var queue = WatchPlaybackQueue()
        _ = queue.replace(with: [makeTrack(id: "manual")])
        queue.appendAutoplay([
            makeTrack(id: "current-auto"),
            makeTrack(id: "future-auto")
        ])
        _ = queue.select(index: 1)

        queue.toggleShuffle()

        XCTAssertEqual(queue.currentTrack?.id, "current-auto")
        XCTAssertEqual(queue.tracks.filter { $0.id == "current-auto" }.count, 1)
        XCTAssertEqual(Set(queue.tracks.map(\.id)), ["current-auto", "future-auto"])
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

    func testMergedPlaylistIsPinnedWhenAnyConstituentIsPinned() {
        let playlists = [
            EnsembleMediaSummary(id: "a", kind: .playlist, title: "Mix", sourceKey: "plex:a:s1"),
            EnsembleMediaSummary(id: "b", kind: .playlist, title: "Mix", sourceKey: "plex:a:s2")
        ]

        XCTAssertTrue(WatchExperienceModel.containsPinnedItem(
            playlists,
            pinnedItemIDs: ["plex:a:s1||a"]
        ))
        XCTAssertFalse(WatchExperienceModel.containsPinnedItem(playlists, pinnedItemIDs: []))
    }

    @MainActor
    func testCachedCatalogStartsReadyAndRefreshesOnlyWhenStale() async throws {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchCatalogStore(defaults: defaults, coreDataStack: .inMemory())
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
        try await store.saveSnapshot(freshSnapshot)

        let model = WatchExperienceModel(catalogStore: store)
        model.start()
        for _ in 0..<100 where model.bootstrapState != .ready { await Task.yield() }

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

    @MainActor
    func testCachedPinsAreAvailableBeforeCloudBootstrapCompletes() async throws {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchCatalogStore(defaults: defaults, coreDataStack: .inMemory())
        let pinnedAlbum = makeSummary(id: "pinned", sourceKey: "plex:account:server:3")
        try await store.saveSnapshot(EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [pinnedAlbum],
            albums: [pinnedAlbum],
            artists: [],
            playlists: [],
            recentlyAdded: []
        ))

        let model = WatchExperienceModel(catalogStore: store)
        model.start()
        for _ in 0..<100 where !model.isPinned(pinnedAlbum) { await Task.yield() }

        XCTAssertTrue(model.isPinned(pinnedAlbum))
    }

    func testRefreshKeepsLastGoodCatalogUntilSelectedContentArrives() {
        let cachedAlbum = makeSummary(id: "cached", sourceKey: "plex:account:server:3")
        let cached = EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [cachedAlbum],
            albums: [cachedAlbum],
            artists: [],
            playlists: [],
            recentlyAdded: []
        )
        let empty = EnsemblePlexCatalogSnapshot(
            libraries: [],
            pins: [],
            albums: [],
            artists: [],
            playlists: [],
            recentlyAdded: []
        )

        XCTAssertEqual(
            WatchExperienceModel.snapshotDuringRefresh(previous: cached, selected: empty),
            cached
        )
        XCTAssertEqual(
            WatchExperienceModel.snapshotDuringRefresh(previous: empty, selected: cached),
            cached
        )
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

    private func makeTrack(id: String, playlistItemID: String? = nil) -> EnsembleTrack {
        EnsembleTrack(
            id: id,
            playlistItemID: playlistItemID,
            title: id,
            sourceKey: "plex:account:server:3"
        )
    }
}
