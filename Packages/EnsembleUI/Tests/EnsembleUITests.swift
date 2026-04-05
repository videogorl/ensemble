import XCTest
@testable import EnsembleUI
import EnsembleCore

final class EnsembleUITests: XCTestCase {
    func testArtworkSizeValues() {
        XCTAssertEqual(ArtworkSize.thumbnail.rawValue, 100)
        XCTAssertEqual(ArtworkSize.small.rawValue, 200)
        XCTAssertEqual(ArtworkSize.medium.rawValue, 300)
        XCTAssertEqual(ArtworkSize.large.rawValue, 500)
        XCTAssertEqual(ArtworkSize.extraLarge.rawValue, 800)
    }

    func testTrackListLayoutMetricsLeadingInsets() {
        XCTAssertEqual(
            TrackListLayoutMetrics.contentLeadingInset(showArtwork: true, showTrackNumbers: false),
            TrackListLayoutMetrics.artworkLeadingInset
        )
        XCTAssertEqual(
            TrackListLayoutMetrics.contentLeadingInset(showArtwork: false, showTrackNumbers: true),
            TrackListLayoutMetrics.trackNumberLeadingInset
        )
        XCTAssertEqual(
            TrackListLayoutMetrics.contentLeadingInset(showArtwork: false, showTrackNumbers: false),
            TrackListLayoutMetrics.plainLeadingInset
        )
        XCTAssertEqual(TrackListLayoutMetrics.miniPlayerBottomSpacing, 140)
        XCTAssertEqual(TrackListLayoutMetrics.compactMiniPlayerBottomSpacing, 110)
    }

    func testTrackRowInteractionModelResolvesRecentPlaylistAndFavoriteState() {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            artistName: "Artist",
            albumName: "Album",
            rating: 4,
            sourceCompositeKey: "plex:account:server:lib"
        )

        let model = TrackRowInteractionModel(
            onPlayNext: { _ in },
            onAddToRecentPlaylist: { _ in },
            onToggleFavorite: { _ in },
            isTrackFavorited: { $0.id == "track-1" },
            canAddToRecentPlaylist: { $0.id == "track-1" },
            recentPlaylistTitle: "Road Trip"
        )

        let resolved = model.resolve(for: track)

        XCTAssertNotNil(resolved.onPlayNext)
        XCTAssertNotNil(resolved.onAddToRecentPlaylist)
        XCTAssertNotNil(resolved.onToggleFavorite)
        XCTAssertEqual(resolved.recentPlaylistTitle, "Road Trip")
        XCTAssertTrue(resolved.isFavorited)
        XCTAssertTrue(resolved.hasContextMenu)
    }

    func testTrackRowInteractionModelSuppressesUnavailableRecentPlaylistAction() {
        let track = Track(
            id: "track-2",
            key: "/tracks/2",
            title: "Track",
            artistName: "Artist",
            albumName: "Album",
            rating: 0,
            sourceCompositeKey: "plex:account:server:lib"
        )

        let model = TrackRowInteractionModel(
            onAddToRecentPlaylist: { _ in },
            canAddToRecentPlaylist: { _ in false },
            recentPlaylistTitle: "Road Trip"
        )

        let resolved = model.resolve(for: track)

        XCTAssertNil(resolved.onAddToRecentPlaylist)
        XCTAssertNil(resolved.recentPlaylistTitle)
        XCTAssertFalse(resolved.isFavorited)
    }
}
