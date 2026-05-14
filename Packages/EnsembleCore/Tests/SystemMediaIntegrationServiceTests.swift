import CoreSpotlight
import EnsembleSiriShared
import XCTest
@testable import EnsembleCore

@MainActor
final class SystemMediaIntegrationServiceTests: XCTestCase {
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
