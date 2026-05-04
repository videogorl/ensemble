import XCTest
@testable import EnsembleUI
import EnsembleCore
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

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

    func testMediaDragPayloadProviderAdvertisesAudioFileRepresentation() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("audio".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let provider = MediaDragPayload.track(track).itemProvider(
            externalFileProvider: { tempURL }
        )

        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier))

        let loadedURL: URL = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: loadedURL.path))
    }

    func testTrackItemProviderDefaultsExtensionlessExportNameToMP3() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("audio".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            artistName: "Artist",
            trackNumber: 5
        )
        let provider = MediaDragPayload.trackItemProvider(
            for: track,
            externalFileProvider: { tempURL }
        )

        XCTAssertEqual(provider.suggestedName, "05. Track - Artist.mp3")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier))
        let decoded = await MediaDragPayload.load(from: [provider])
        XCTAssertEqual(decoded, MediaDragPayload.track(track))
    }

    func testTrackItemProviderKeepsLocalFileExtensionInSuggestedName() {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Lossless",
            artistName: "Artist",
            localFilePath: "/tmp/cache/lossless.FLAC"
        )

        let provider = MediaDragPayload.trackItemProvider(for: track)

        XCTAssertEqual(provider.suggestedName, "Lossless - Artist.flac")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier))
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

    #if os(macOS)
    func testMediaDragPayloadPasteboardItemDoesNotExposeJSONOrStringFallbacks() throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let item = try XCTUnwrap(MediaDragPayload.track(track).pasteboardItem())

        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType(MediaDragPayload.typeIdentifier)))
        XCTAssertFalse(item.types.contains(NSPasteboard.PasteboardType(UTType.json.identifier)))
        XCTAssertFalse(item.types.contains(.string))
    }

    func testMediaDragPayloadFilePromiseWriterKeepsPayloadAndPromisesFile() throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let expected = MediaDragPayload.track(track)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")
        try Data("audio".utf8).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let writer = try XCTUnwrap(expected.filePromisePasteboardWriter(
            fallbackFileURL: tempURL,
            promisedFileName: "Track.mp3",
            fileTypeIdentifier: UTType(filenameExtension: "mp3")?.identifier ?? UTType.audio.identifier
        ))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        let types = writer.writableTypes(for: pasteboard)
        let customType = NSPasteboard.PasteboardType(MediaDragPayload.typeIdentifier)
        let promiseContentType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")
        let promisedFileNameType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-name")
        let promisedSuggestedFileNameType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")

        XCTAssertTrue(types.contains(customType))
        XCTAssertTrue(types.contains(promiseContentType))
        XCTAssertFalse(types.contains(NSPasteboard.PasteboardType(UTType.json.identifier)))
        XCTAssertFalse(types.contains(.string))
        XCTAssertTrue(
            [promisedFileNameType, promisedSuggestedFileNameType].contains { type in
                writer.pasteboardPropertyList(forType: type) as? String == "Track.mp3"
            }
        )

        let data = try XCTUnwrap(writer.pasteboardPropertyList(forType: customType) as? Data)
        let decoded = try JSONDecoder().decode(MediaDragPayload.self, from: data)
        XCTAssertEqual(decoded, expected)
    }
    #endif

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
