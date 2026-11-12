import CoreSpotlight
import EnsembleDomain
import EnsemblePersistence
import EnsembleSiriShared
import XCTest
@testable import EnsembleCore

@MainActor
final class SystemMediaIntegrationServiceTests: XCTestCase {
    /// Spotlight holds one item per displayed playlist: merging collapses same-named playlists to one, switching it
    /// off brings back one per source with the server name, and the per-source items that go away are the stale ones.
    func testSpotlightIndexFollowsPlaylistMergeSetting() {
        func playlist(_ id: String, _ server: String, duration: TimeInterval? = nil) -> SiriMediaIndexItem {
            SiriMediaIndexItem(
                kind: .playlist, id: id, displayName: "focus", sourceCompositeKey: "plex:account:\(server)",
                duration: duration, sourceName: server
            )
        }
        let track = SiriMediaIndexItem(kind: .track, id: "t", displayName: "focus", sourceCompositeKey: "plex:account:one")
        // Only playlists are transformed: two same-named, same-artist albums stay two items.
        let albums = ["a1", "a2"].map {
            SiriMediaIndexItem(kind: .album, id: $0, displayName: "Twin", sourceCompositeKey: "plex:account:\($0)", secondaryText: "Artist")
        }
        let full = SiriMediaIndex(items: [playlist("p1", "one"), albums[0], playlist("p2", "two"), albums[1], track])
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false

        let merged = SystemMediaIntegrationService.spotlightIndex(from: full, presentation: .init())
        let perSource = SystemMediaIntegrationService.spotlightIndex(from: full, presentation: .init(preferences: off))

        XCTAssertEqual(merged.items.map(\.id), ["p1", "a1", "a2", "t"])
        let timed = SiriMediaIndex(items: [playlist("p1", "one", duration: 100), playlist("p2", "two", duration: 20)])
        XCTAssertEqual(
            SystemMediaIntegrationService.spotlightIndex(from: timed, presentation: .init()).items.map(\.duration), [120],
            "a merged result carries the group's total length"
        )
        XCTAssertEqual(
            SystemMediaIntegrationService.spotlightIndex(from: timed, presentation: .init(preferences: off)).items.map(\.duration), [100, 20]
        )
        XCTAssertEqual(perSource.items.map(\.id), ["p1", "a1", "p2", "a2", "t"])
        XCTAssertEqual(perSource.items.filter { $0.kind == .playlist }.compactMap(\.secondaryText), ["one", "two"])
        XCTAssertEqual(
            SystemMediaIntegrationService.staleSystemMediaReferences(previous: perSource, current: merged).map(\.id),
            ["p2"]
        )
    }

    /// Hide and unhide one copy of a merged group while a pass is interrupted after its deletions: the group's item must
    /// be back in Spotlight at the end. Each step applies deletions, then indexing, like the service; `interrupted`
    /// stops before indexing and leaves the baseline as the service does.
    func testMergedGroupItemSurvivesHideUnhideWithAnInterruptedPass() {
        func playlist(_ id: String, _ server: String, _ duration: Double) -> SiriMediaIndexItem {
            SiriMediaIndexItem(kind: .playlist, id: id, displayName: "focus", sourceCompositeKey: "plex:account:\(server)", duration: duration, sourceName: server)
        }
        let home = playlist("h", "home", 20), away = playlist("a", "away", 100)
        var off = EnsembleMergingPreferences.default
        off.mergePlaylists = false

        // (name, catalog, merging off, interrupted after deletions)
        let steps: [(String, [SiriMediaIndexItem], Bool, Bool)] = [
            ("merged, both visible", [home, away], false, false),
            ("home hidden, the group's lead moves; interrupted", [away], false, true),
            ("home back, lead returns", [home, away], false, false),
            ("per source", [home, away], true, false),
            ("merged again; interrupted after deleting the non-lead copy", [home, away], false, true),
            ("per source again", [home, away], true, false),
            ("merged", [home, away], false, false)
        ]
        var spotlight = Set<String>()
        var baseline: SiriMediaIndex?
        for (name, catalog, perSource, interrupted) in steps {
            let current = SystemMediaIntegrationService.spotlightIndex(
                from: SiriMediaIndex(items: catalog), presentation: .init(preferences: perSource ? off : .default)
            )
            let stale = SystemMediaIntegrationService.staleSystemMediaReferences(previous: baseline, current: current)
            let toIndex = SystemMediaIntegrationService.spotlightItemsToIndex(previous: baseline, current: current, requiresFullRefresh: false)
            spotlight.subtract(stale.map(\.id))
            if let baseline, !stale.isEmpty {
                self.baselineAfterDeletion = SystemMediaIntegrationService.baseline(removing: stale, from: baseline)
            } else {
                self.baselineAfterDeletion = baseline
            }
            baseline = baselineAfterDeletion
            if interrupted { continue }
            spotlight.formUnion(toIndex.map(\.id))
            baseline = current
            XCTAssertEqual(spotlight, Set(current.items.map(\.id)), name)
        }
    }

    private var baselineAfterDeletion: SiriMediaIndex?

    func testSiriIndexMaterialChangeIgnoresGenerationTimeButDetectsContentAndSchema() {
        let item = SiriMediaIndexItem(kind: .track, id: "track", displayName: "Original")
        let previous = SiriMediaIndex(
            generatedAt: Date(timeIntervalSince1970: 1),
            items: [item]
        )
        let regenerated = SiriMediaIndex(
            generatedAt: Date(timeIntervalSince1970: 2),
            items: [item]
        )
        let edited = SiriMediaIndex(
            items: [SiriMediaIndexItem(kind: .track, id: "track", displayName: "Edited")]
        )
        let oldSchema = SiriMediaIndex(
            schemaVersion: SiriMediaIndex.currentSchemaVersion - 1,
            items: [item]
        )

        XCTAssertFalse(SiriMediaIndexStore.hasMaterialChanges(from: previous, to: regenerated))
        XCTAssertTrue(SiriMediaIndexStore.hasMaterialChanges(from: previous, to: edited))
        XCTAssertTrue(SiriMediaIndexStore.hasMaterialChanges(from: oldSchema, to: regenerated))
        XCTAssertTrue(SiriMediaIndexStore.hasMaterialChanges(from: nil, to: regenerated))
    }

    func testPlaybackStartContextDonationEligibilityRequiresAppUIReference() {
        let reference = makeReference(kind: .album)

        XCTAssertTrue(PlaybackStartContext(origin: .appUI, source: .album, reference: reference).isDonationEligible)
        XCTAssertFalse(PlaybackStartContext(origin: .siri, source: .album, reference: reference).isDonationEligible)
        XCTAssertFalse(PlaybackStartContext(origin: .remoteCommand, source: .album, reference: reference).isDonationEligible)
        XCTAssertFalse(PlaybackStartContext(origin: .appUI, source: .album, reference: nil).isDonationEligible)
    }

    func testSpotlightItemConstructionUsesSourceScopedIdentifiersAndAudioAttributes() throws {
        let item = SiriMediaIndexItem(
            kind: .track,
            id: "track-1",
            displayName: "Track Name",
            sourceCompositeKey: "plex://server.one/library",
            secondaryText: "Artist Name",
            lastPlayed: nil,
            playCount: 12,
            trackCount: nil,
            albumTitle: "Album Name",
            artistName: "Artist Name",
            genre: "Electronic, Ambient",
            duration: 240,
            trackNumber: 3,
            discNumber: 1
        )

        let searchableItems = SystemMediaIntegrationService.makeSpotlightItems(from: [item])

        XCTAssertEqual(searchableItems.count, 1)
        let searchableItem = try XCTUnwrap(searchableItems.first)
        XCTAssertEqual(searchableItem.uniqueIdentifier, "ensemble.systemMedia.track||track-1||plex://server.one/library")
        XCTAssertEqual(searchableItem.domainIdentifier, "ensemble.plex___server_one_library.track")
        XCTAssertEqual(searchableItem.expirationDate, .distantFuture)
        XCTAssertEqual(searchableItem.attributeSet.title, "Track Name")
        XCTAssertEqual(searchableItem.attributeSet.displayName, "Track Name")
        XCTAssertEqual(searchableItem.attributeSet.artist, "Artist Name")
        XCTAssertEqual(searchableItem.attributeSet.album, "Album Name")
        XCTAssertEqual(searchableItem.attributeSet.duration, NSNumber(value: 240))
        XCTAssertEqual(searchableItem.attributeSet.domainIdentifier, "ensemble.plex___server_one_library.track")
        XCTAssertTrue(searchableItem.attributeSet.keywords?.contains("Electronic") ?? false)
        XCTAssertTrue(searchableItem.attributeSet.keywords?.contains("Ambient") ?? false)
    }

    func testLocalArtworkURLUsesIndexedCacheIdentity() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }

        let expectedURL = artworkDirectory.appendingPathComponent("album-1_album.jpg")
        try Data("art".utf8).write(to: expectedURL)

        let item = SiriMediaIndexItem(
            kind: .track,
            id: "track-1",
            displayName: "Track Name",
            artworkPath: "/library/metadata/album-1/thumb/123",
            artworkCacheKey: "album-1",
            artworkCacheType: .album
        )

        XCTAssertEqual(
            SystemMediaIntegrationService.localArtworkURL(for: item, artworkDirectory: artworkDirectory),
            expectedURL
        )
    }

    func testLocalArtworkURLUsesSourceScopedCacheIdentity() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }
        let sourceA = "plex:account-a:server:library"
        let sourceB = "plex:account-b:server:library"
        let filenameA = ArtworkDownloadManager.cacheFilename(
            ratingKey: "album-1",
            type: .album,
            sourceCompositeKey: sourceA
        )
        let filenameB = ArtworkDownloadManager.cacheFilename(
            ratingKey: "album-1",
            type: .album,
            sourceCompositeKey: sourceB
        )
        let urlA = artworkDirectory.appendingPathComponent(filenameA)
        let urlB = artworkDirectory.appendingPathComponent(filenameB)
        try Data("a".utf8).write(to: urlA)
        try Data("b".utf8).write(to: urlB)
        let item = SiriMediaIndexItem(
            kind: .album,
            id: "album-1",
            displayName: "Album",
            sourceCompositeKey: sourceB,
            artworkCacheKey: "album-1",
            artworkCacheType: .album
        )

        XCTAssertEqual(
            SystemMediaIntegrationService.localArtworkURL(for: item, artworkDirectory: artworkDirectory),
            urlB
        )
        XCTAssertNotEqual(urlA, urlB)
    }

    func testSourceScopedLocalArtworkURLDoesNotClaimLegacyArtwork() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }
        let legacyURL = artworkDirectory.appendingPathComponent("album-1_album.jpg")
        try Data("legacy".utf8).write(to: legacyURL)
        let item = SiriMediaIndexItem(
            kind: .album,
            id: "album-1",
            displayName: "Album",
            sourceCompositeKey: "plex:account:server:library",
            artworkCacheKey: "album-1",
            artworkCacheType: .album
        )

        XCTAssertNil(
            SystemMediaIntegrationService.localArtworkURL(for: item, artworkDirectory: artworkDirectory)
        )
    }

    func testLocalArtworkURLFallsBackToArtworkPathRatingKey() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }

        let expectedURL = artworkDirectory.appendingPathComponent("album-1_album.jpg")
        try Data("art".utf8).write(to: expectedURL)

        let item = SiriMediaIndexItem(
            kind: .track,
            id: "track-1",
            displayName: "Track Name",
            artworkPath: "/library/metadata/album-1/thumb/123"
        )

        XCTAssertEqual(
            SystemMediaIntegrationService.localArtworkURL(for: item, artworkDirectory: artworkDirectory),
            expectedURL
        )
    }

    func testLocalArtworkDataReadsIndexedCacheIdentity() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }

        let expectedData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let expectedURL = artworkDirectory.appendingPathComponent("album-1_album.jpg")
        try expectedData.write(to: expectedURL)

        let reference = SystemMediaReference(
            kind: .album,
            id: "album-1",
            displayName: "Album Name",
            artworkCacheKey: "album-1",
            artworkCacheType: .album
        )

        XCTAssertEqual(
            SystemMediaIntegrationService.localArtworkData(for: reference, artworkDirectory: artworkDirectory),
            expectedData
        )
    }

    func testLocalArtworkURLUsesPlaylistCacheIdentity() throws {
        let artworkDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artworkDirectory) }

        let expectedURL = artworkDirectory.appendingPathComponent("playlist-1_playlist.jpg")
        try Data("art".utf8).write(to: expectedURL)

        let item = SiriMediaIndexItem(
            kind: .playlist,
            id: "playlist-1",
            displayName: "Road Trip",
            artworkCacheKey: "playlist-1",
            artworkCacheType: .playlist
        )

        XCTAssertEqual(
            SystemMediaIntegrationService.localArtworkURL(for: item, artworkDirectory: artworkDirectory),
            expectedURL
        )
    }

    func testSpotlightDomainIdentifiersAreSourceAndKindScoped() {
        let album = makeReference(kind: .album)
        let playlist = makeReference(kind: .playlist)

        XCTAssertEqual(SystemMediaIntegrationService.spotlightDomainIdentifier(for: album), "ensemble.plex___server_one_library.album")
        XCTAssertEqual(SystemMediaIntegrationService.spotlightDomainIdentifier(for: playlist), "ensemble.plex___server_one_library.playlist")
        XCTAssertNotEqual(
            SystemMediaIntegrationService.spotlightDomainIdentifier(for: album),
            SystemMediaIntegrationService.spotlightDomainIdentifier(for: playlist)
        )
    }

    func testSystemMediaSourceScopeAllowsOnlyEnabledLibraryKeys() {
        let allowedSources: Set<String> = ["plex:account-one:server-one:music"]

        XCTAssertTrue(SystemMediaSourceScope.allows(
            "plex:account-one:server-one:music",
            within: allowedSources
        ))
        XCTAssertFalse(SystemMediaSourceScope.allows(
            "plex:account-one:server-one:audiobooks",
            within: allowedSources
        ))
        XCTAssertFalse(SystemMediaSourceScope.allows(
            "plex:account-one:server-one:music",
            within: []
        ))
        XCTAssertFalse(SystemMediaSourceScope.allows(nil, within: allowedSources))
        XCTAssertTrue(SystemMediaSourceScope.allows(nil, within: nil))
    }

    func testSystemMediaSourceScopeIncludesEveryEnabledProvider() {
        let plex = MusicSourceIdentifier(
            type: .plex,
            accountId: "account",
            serverId: "server",
            libraryId: "library"
        )

        XCTAssertEqual(
            SystemMediaSourceScope.enabledLibraryKeys(for: [plex, .appleMusic]),
            [plex.compositeKey, MusicSourceIdentifier.appleMusic.compositeKey]
        )
    }

    func testSystemMediaSourceScopeExpandsPlaylistKeysToEnabledServers() {
        let playlistSources = SystemMediaSourceScope.playlistSourceKeys(
            forEnabledLibraryKeys: ["plex:account-one:server-one:music"]
        )

        XCTAssertTrue(playlistSources.contains("plex:account-one:server-one:music"))
        XCTAssertTrue(playlistSources.contains("plex:account-one:server-one"))
        XCTAssertFalse(playlistSources.contains("plex:account-one:server-two"))
    }

    func testStaleSystemMediaReferencesFindsItemsRemovedFromCurrentIndex() {
        let kept = SiriMediaIndexItem(
            kind: .album,
            id: "album-1",
            displayName: "Kept",
            sourceCompositeKey: "plex:account-one:server-one:music"
        )
        let removed = SiriMediaIndexItem(
            kind: .playlist,
            id: "playlist-1",
            displayName: "Removed",
            sourceCompositeKey: "plex:account-one:server-two"
        )
        let previous = SiriMediaIndex(items: [kept, removed])
        let current = SiriMediaIndex(items: [kept])

        let staleReferences = SystemMediaIntegrationService.staleSystemMediaReferences(
            previous: previous,
            current: current
        )

        XCTAssertEqual(staleReferences.map(\.sourceScopedIdentifier), [removed.reference.sourceScopedIdentifier])
    }

    func testSpotlightIncrementalDiffHandlesAddEditRemoveAndFullRefresh() {
        let unchanged = SiriMediaIndexItem(kind: .album, id: "album-1", displayName: "Unchanged")
        let edited = SiriMediaIndexItem(kind: .track, id: "track-1", displayName: "Edited")
        let removed = SiriMediaIndexItem(kind: .playlist, id: "playlist-1", displayName: "Removed")
        let added = SiriMediaIndexItem(kind: .artist, id: "artist-1", displayName: "Added")
        let previous = SiriMediaIndex(items: [unchanged, edited, removed])
        let current = SiriMediaIndex(items: [
            unchanged,
            SiriMediaIndexItem(kind: .track, id: "track-1", displayName: "Edited Again"),
            added
        ])

        XCTAssertEqual(
            SystemMediaIntegrationService.spotlightItemsToIndex(
                previous: previous,
                current: current,
                requiresFullRefresh: false
            ).map(\.id),
            ["track-1", "artist-1"]
        )
        XCTAssertEqual(
            SystemMediaIntegrationService.spotlightItemsToIndex(
                previous: previous,
                current: current,
                requiresFullRefresh: true
            ),
            current.items
        )
        XCTAssertTrue(
            SystemMediaIntegrationService.spotlightItemsToIndex(
                previous: current,
                current: current,
                requiresFullRefresh: false
            ).isEmpty
        )
    }

    func testDonationIdentifiersCoverShuffleVariants() {
        let reference = makeReference(kind: .playlist)

        XCTAssertEqual(
            SystemMediaIntegrationService.donationIdentifiers(for: reference),
            [
                "ensemble.play.playlist||playlist-1||plex://server.one/library.shuffle.0",
                "ensemble.play.playlist||playlist-1||plex://server.one/library.shuffle.1"
            ]
        )
    }

    func testSiriVocabularyStringsIncludeVideoPlaylistVariants() {
        let items = [
            SiriMediaIndexItem(
                kind: .playlist,
                id: "playlist-1",
                displayName: "Music Video Ideas",
                sourceCompositeKey: "plex://server.one/library",
                trackCount: 5
            ),
            SiriMediaIndexItem(
                kind: .album,
                id: "album-1",
                displayName: "Music Video Ideas",
                sourceCompositeKey: "plex://server.one/library"
            )
        ]

        let vocabulary = SystemMediaIntegrationService.siriVocabularyStrings(
            from: items,
            kind: .playlist,
            limit: 10
        )

        XCTAssertTrue(vocabulary.contains("Music Video Ideas"))
        XCTAssertTrue(vocabulary.contains("Music Videos Ideas"))
        XCTAssertTrue(vocabulary.contains("Video Ideas"))
        XCTAssertTrue(vocabulary.contains("Videos Ideas"))
        XCTAssertTrue(vocabulary.contains("Music Video Ideas playlist"))
        XCTAssertTrue(vocabulary.contains("playlist Music Video Ideas"))
        XCTAssertTrue(vocabulary.contains("the playlist Music Video Ideas"))
    }

    func testSiriVocabularyStringsRespectKindDedupeAndLimit() {
        let items = [
            SiriMediaIndexItem(kind: .playlist, id: "playlist-1", displayName: "Road Trip"),
            SiriMediaIndexItem(kind: .playlist, id: "playlist-2", displayName: "road trip"),
            SiriMediaIndexItem(kind: .artist, id: "artist-1", displayName: "Road Trip"),
            SiriMediaIndexItem(kind: .playlist, id: "playlist-3", displayName: "Workout")
        ]

        let vocabulary = SystemMediaIntegrationService.siriVocabularyStrings(
            from: items,
            kind: .playlist,
            limit: 2
        )

        XCTAssertEqual(vocabulary, ["Road Trip", "Workout"])
    }

    private func makeReference(kind: SiriMediaKind) -> SystemMediaReference {
        SystemMediaReference(
            kind: kind,
            id: "\(kind.rawValue)-1",
            sourceCompositeKey: "plex://server.one/library",
            displayName: "Display Name",
            secondaryText: "Secondary"
        )
    }
}
