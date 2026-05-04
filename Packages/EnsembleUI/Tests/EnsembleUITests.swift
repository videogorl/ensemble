import XCTest
@testable import EnsembleUI
import EnsembleCore
import UniformTypeIdentifiers

final class EnsembleUITests: XCTestCase {
    func testMediaDragPayloadPreservesTrackIdentity() throws {
        let track = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track One",
            sourceCompositeKey: "server/library"
        )

        let payload = MediaDragPayload.track(track)

        XCTAssertEqual(payload.items.count, 1)
        XCTAssertEqual(payload.items[0].kind, .track)
        XCTAssertEqual(payload.items[0].id, "track-1")
        XCTAssertEqual(payload.items[0].sourceKey, "server/library")
        XCTAssertNil(payload.items[0].isSmartPlaylist)
    }

    func testMediaDragPayloadProviderRoundTripsPlaylist() async throws {
        let playlist = Playlist(
            id: "playlist-1",
            key: "/playlists/playlist-1",
            title: "Road",
            isSmart: false,
            sourceCompositeKey: "server/library"
        )
        let expected = MediaDragPayload.playlist(playlist)
        let provider = expected.itemProvider()

        let decoded = await MediaDragPayload.load(from: [provider])

        XCTAssertEqual(decoded, expected)
    }

    func testMediaDragPayloadProviderAdvertisesCustomAndJSONTypes() {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let provider = MediaDragPayload.track(track).itemProvider()

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(MediaDragPayload.typeIdentifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.json.identifier))
        XCTAssertTrue(MediaDragPayload.canLoad(from: [provider]))
    }

    func testMediaDragPayloadLoadsJSONFallback() async throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let expected = MediaDragPayload.track(track)
        let encoded = try XCTUnwrap(expected.encodedData())
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.json.identifier,
            visibility: .all
        ) { completion in
            completion(encoded, nil)
            return nil
        }

        let decoded = await MediaDragPayload.load(from: [provider])

        XCTAssertEqual(decoded, expected)
    }

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
        XCTAssertEqual(TrackListLayoutMetrics.detailHorizontalPadding, 40)
        XCTAssertEqual(TrackListLayoutMetrics.utilitySectionOuterPadding, 24)
        XCTAssertGreaterThan(TrackListLayoutMetrics.durationColumnWidth, TrackListLayoutMetrics.durationMinimumWidth)
        XCTAssertEqual(TrackListLayoutMetrics.miniPlayerBottomSpacing, 140)
        XCTAssertEqual(TrackListLayoutMetrics.compactMiniPlayerBottomSpacing, 110)
    }

    func testTrackListLayoutMetricsRowInsets() {
        let insets = TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false)

        XCTAssertEqual(insets.top, TrackListLayoutMetrics.rowVerticalPadding)
        XCTAssertEqual(insets.leading, TrackListLayoutMetrics.rowHorizontalPadding)
        XCTAssertEqual(insets.bottom, TrackListLayoutMetrics.rowVerticalPadding)
        XCTAssertEqual(insets.trailing, TrackListLayoutMetrics.rowHorizontalPadding)
    }

    func testTrackListLayoutMetricsUtilityListRowInsets() {
        let insets = TrackListLayoutMetrics.utilityListRowInsets(verticalPadding: 4)

        XCTAssertEqual(insets.top, 4)
        XCTAssertEqual(insets.leading, TrackListLayoutMetrics.detailHorizontalPadding)
        XCTAssertEqual(insets.bottom, 4)
        XCTAssertEqual(insets.trailing, TrackListLayoutMetrics.detailHorizontalPadding)
    }

    func testTrackListLayoutMetricsDividerTokens() {
        XCTAssertEqual(TrackListLayoutMetrics.nativeDividerAlpha, 0.18)
        _ = TrackListLayoutMetrics.dividerColor
        #if os(iOS) || os(macOS)
        _ = TrackListLayoutMetrics.nativeSeparatorColor
        #endif
    }

    func testScrollIndexCompactTrailingPaddingDoesNotOverlapViewportEdge() {
        XCTAssertGreaterThanOrEqual(EnsembleScaffold.ScrollIndex.compactTrailingPadding, 0)
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
