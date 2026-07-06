import XCTest
@testable import EnsembleUI
import EnsembleCore
import EnsemblePersistence
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

final class EnsembleUITests: XCTestCase {
    func testCompactArtistHeroOverscrollStartsBeforeSafeAreaClears() {
        XCTAssertEqual(
            ArtistDetailView.compactHeroOverscroll(globalMinY: -59),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ArtistDetailView.compactHeroOverscroll(globalMinY: 11),
            11,
            accuracy: 0.001
        )
        XCTAssertEqual(
            ArtistDetailView.compactHeroOverscroll(globalMinY: 59),
            59,
            accuracy: 0.001
        )
    }

    func testControlsCardLayoutShrinksArtworkBeforeControlRows() {
        let layout = ControlsCardLayoutMetrics.resolve(for: CGSize(width: 320, height: 520))

        XCTAssertLessThan(layout.artworkSize, 160)
        XCTAssertEqual(layout.progressRowMinHeight, EnsembleScaffold.NowPlaying.controlsProgressRowMinHeight)
        XCTAssertEqual(layout.metadataRowMinHeight, EnsembleScaffold.NowPlaying.controlsMetadataRowMinHeight)
        XCTAssertEqual(layout.primaryControlsRowMinHeight, EnsembleScaffold.NowPlaying.controlsPrimaryRowMinHeight)
        XCTAssertEqual(layout.secondaryControlsRowMinHeight, EnsembleScaffold.NowPlaying.controlsSecondaryRowMinHeight)
        XCTAssertEqual(layout.secondaryControlsTopPadding, EnsembleScaffold.NowPlaying.secondaryControlsTopPadding)
        XCTAssertEqual(layout.secondaryControlsBottomPadding, EnsembleScaffold.NowPlaying.secondaryControlsBottomPadding)
    }

    func testControlsCardLayoutCapsArtworkAtContainerWidthWhenHeightAllows() {
        let layout = ControlsCardLayoutMetrics.resolve(for: CGSize(width: 360, height: 900))

        XCTAssertEqual(layout.artworkSize, 360)
    }

    func testChordIconFallsBackForOlderSymbolSets() {
        XCTAssertEqual(
            EnsembleDesign.Icon.chordIconName(modernSymbolSetAvailable: false),
            "music.note.list"
        )
        XCTAssertEqual(
            EnsembleDesign.Icon.chordIconName(modernSymbolSetAvailable: true),
            "apple.classical.pages"
        )
    }

    func testSmartMixIconFallsBackForOlderSymbolSets() {
        XCTAssertEqual(
            EnsembleDesign.Icon.smartMixIconName(modernSymbolSetAvailable: false),
            "sparkles"
        )
        XCTAssertEqual(
            EnsembleDesign.Icon.smartMixIconName(modernSymbolSetAvailable: true),
            "circle.dotted.and.circle"
        )
    }

    func testArtworkResolverSchedulesPersistentCacheHintAfterImageResolution() async throws {
        let artworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: artworkURL) }

        let hint = PersistentArtworkCacheHint(
            ratingKey: "album-1",
            kind: .album,
            sourcePath: "/library/metadata/album-1/thumb"
        )
        let artworkLoader = RecordingArtworkLoader(url: artworkURL)
        let descriptor = ArtworkResolutionDescriptor(
            path: "/library/metadata/album-1/thumb",
            sourceKey: "plex:server:library",
            ratingKey: "album-1",
            fallbackPath: nil,
            fallbackRatingKey: nil,
            cacheHint: hint,
            fallbackCacheHint: nil,
            size: 44,
            priority: .high
        )

        let resolved = await ArtworkImageResolver.resolvedImage(for: descriptor, artworkLoader: artworkLoader)

        XCTAssertNotNil(resolved)
        let cacheRequests = await artworkLoader.cacheRequests
        XCTAssertEqual(cacheRequests.count, 1)
        XCTAssertEqual(cacheRequests.first?.hint, hint)
        XCTAssertEqual(cacheRequests.first?.minimumPixelDimension, 44)
    }

    func testArtworkResolverFallsBackToLocalCacheWhenResolvedURLFails() async throws {
        let localArtworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: localArtworkURL) }

        let missingArtworkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let artworkLoader = RecordingArtworkLoader(url: missingArtworkURL, localURL: localArtworkURL)
        let descriptor = ArtworkResolutionDescriptor(
            path: "/library/metadata/album-1/thumb",
            sourceKey: "plex:server:library",
            ratingKey: "album-1",
            fallbackPath: nil,
            fallbackRatingKey: nil,
            cacheHint: PersistentArtworkCacheHint(
                ratingKey: "album-1",
                kind: .album,
                sourcePath: "/library/metadata/album-1/thumb"
            ),
            fallbackCacheHint: nil,
            size: 44,
            priority: .high
        )

        let resolved = await ArtworkImageResolver.resolvedImage(for: descriptor, artworkLoader: artworkLoader)

        XCTAssertEqual(resolved?.url, localArtworkURL)
        XCTAssertNotNil(resolved?.image)
        let localRequests = await artworkLoader.localRequests
        XCTAssertEqual(localRequests.count, 1)
        XCTAssertEqual(localRequests.first?.minimumPixelDimension, nil)
        XCTAssertEqual(localRequests.first?.allowStaleIdentity, true)
        let cacheRequests = await artworkLoader.cacheRequests
        XCTAssertTrue(cacheRequests.isEmpty)
    }

    @MainActor
    func testTrackArtworkThumbnailLoaderUsesResolverLocalFallback() async throws {
        let localArtworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: localArtworkURL) }

        let missingArtworkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        let artworkLoader = RecordingArtworkLoader(url: missingArtworkURL, localURL: localArtworkURL)
        let track = Track(
            id: "track-1",
            key: "/library/metadata/track-1",
            title: "Track One",
            thumbPath: "/library/metadata/track-1/thumb",
            fallbackThumbPath: "/library/metadata/album-1/thumb",
            fallbackRatingKey: "album-1",
            sourceCompositeKey: "plex:server:library"
        )

        let image = await TrackArtworkThumbnailLoader.image(
            for: track,
            artworkLoader: artworkLoader,
            isCurrent: { true }
        )

        XCTAssertNotNil(image)
        let localRequests = await artworkLoader.localRequests
        XCTAssertEqual(localRequests.count, 1)
        XCTAssertEqual(localRequests.first?.minimumPixelDimension, nil)
        XCTAssertEqual(localRequests.first?.allowStaleIdentity, true)
    }

    func testArtworkPreBlurUsesVisibleArtworkSchedulerByDefault() async throws {
        let artworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: artworkURL) }
        let image = try XCTUnwrap(makePlatformImage(from: artworkURL))
        let scheduler = await MainActor.run { RecordingForegroundWorkScheduler() }

        let blurredImage = await ArtworkImageResolver.preBlurredImage(
            for: image,
            cacheKey: "test-visible-blur-\(UUID().uuidString)",
            scheduler: scheduler
        )

        XCTAssertNotNil(blurredImage)
        let waitCalls = await scheduler.waitCalls
        XCTAssertEqual(waitCalls.map(\.kind), [.visibleArtworkRetry])
        XCTAssertEqual(waitCalls.map(\.policy), [.immediate])
    }

    func testChordLineSegmentsPreserveManualReturnsBeforeWrapping() {
        let line = LyricsLine(
            timestamp: 12,
            text: "First lyric line\nsecond physical lyric line",
            chords: [
                ParsedChord(symbol: "C", column: 0, offsetFromLyricStart: 0),
                ParsedChord(symbol: "G", column: 6, offsetFromLyricStart: 6)
            ]
        )

        let rows = ChordLineSegments.rows(for: line, maxColumns: 80)

        XCTAssertEqual(rows, [
            ChordLineSegments.Row(chords: "C     G", lyric: "First lyric line"),
            ChordLineSegments.Row(chords: "", lyric: "second physical lyric line")
        ])
    }

    func testChordLineSegmentWhitespaceOnlyLyricIsPlaceholderEligible() {
        let row = ChordLineSegments.Row(chords: "C", lyric: "   ")

        XCTAssertTrue(row.hasVisibleChords)
        XCTAssertFalse(row.hasVisibleLyric)
    }

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

        XCTAssertEqual(provider.suggestedName, "05. Track - Artist")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "mp3")!.identifier))
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

        XCTAssertEqual(provider.suggestedName, "Lossless - Artist")
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType(filenameExtension: "flac")!.identifier))
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
    func testMediaDragPayloadPasteboardItemExposesJSONFallbackWithoutStringFallback() throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let expected = MediaDragPayload.track(track)
        let item = try XCTUnwrap(MediaDragPayload.track(track).pasteboardItem())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()

        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType(MediaDragPayload.typeIdentifier)))
        XCTAssertTrue(item.types.contains(NSPasteboard.PasteboardType(UTType.json.identifier)))
        XCTAssertFalse(item.types.contains(.string))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        XCTAssertTrue(MediaDragPayload.canLoad(from: pasteboard))
        XCTAssertEqual(MediaDragPayload.load(from: pasteboard), expected)
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
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType(UTType.json.identifier)))
        XCTAssertTrue(types.contains(promiseContentType))
        XCTAssertFalse(types.contains(.string))
        XCTAssertTrue(
            [promisedFileNameType, promisedSuggestedFileNameType].contains { type in
                writer.pasteboardPropertyList(forType: type) as? String == "Track.mp3"
            }
        )

        let data = try XCTUnwrap(writer.pasteboardPropertyList(forType: customType) as? Data)
        let decoded = try JSONDecoder().decode(MediaDragPayload.self, from: data)
        XCTAssertEqual(decoded, expected)

        let jsonData = try XCTUnwrap(writer.pasteboardPropertyList(forType: NSPasteboard.PasteboardType(UTType.json.identifier)) as? Data)
        let jsonDecoded = try JSONDecoder().decode(MediaDragPayload.self, from: jsonData)
        XCTAssertEqual(jsonDecoded, expected)
    }

    func testMacTrailingSwipeSlotsUseAppKitOrdering() {
        let configured: [TrackSwipeAction?] = [.favoriteToggle, .addToPlaylist]

        XCTAssertEqual(
            MacNativeTrackTableView.appKitRowActionSlots(for: configured, edge: .leading),
            [.favoriteToggle, .addToPlaylist]
        )
        XCTAssertEqual(
            MacNativeTrackTableView.appKitRowActionSlots(for: configured, edge: .trailing),
            [.addToPlaylist, .favoriteToggle]
        )
    }

    #endif

    func testArtworkSizeValues() {
        XCTAssertEqual(ArtworkSize.thumbnail.rawValue, 100)
        XCTAssertEqual(ArtworkSize.small.rawValue, 200)
        XCTAssertEqual(ArtworkSize.medium.rawValue, 300)
        XCTAssertEqual(ArtworkSize.large.rawValue, 500)
        XCTAssertEqual(ArtworkSize.extraLarge.rawValue, 800)
        XCTAssertEqual(ArtworkSize.detail.rawValue, 1000)
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
        XCTAssertEqual(TrackListLayoutMetrics.queueHorizontalGutter, 20)
        XCTAssertEqual(TrackListLayoutMetrics.queueOuterContentPadding, 20)
        XCTAssertGreaterThan(TrackListLayoutMetrics.durationColumnWidth, TrackListLayoutMetrics.durationMinimumWidth)
        XCTAssertEqual(TrackListLayoutMetrics.miniPlayerBottomSpacing, 140)
        XCTAssertEqual(TrackListLayoutMetrics.compactMiniPlayerBottomSpacing, 110)
        XCTAssertEqual(TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 0), 20)
        XCTAssertEqual(TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 20), 32)
        XCTAssertEqual(TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0), 52)
        XCTAssertEqual(TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 34), 52)
    }

    func testTrackListLayoutMetricsRowInsets() {
        let insets = TrackListLayoutMetrics.rowInsets(showArtwork: true, showTrackNumbers: false)

        XCTAssertEqual(insets.top, TrackListLayoutMetrics.rowVerticalPadding)
        XCTAssertEqual(insets.leading, TrackListLayoutMetrics.rowHorizontalPadding)
        XCTAssertEqual(insets.bottom, TrackListLayoutMetrics.rowVerticalPadding)
        XCTAssertEqual(insets.trailing, TrackListLayoutMetrics.rowHorizontalPadding)
    }

    func testTrackListLayoutMetricsDividerTokens() {
        XCTAssertEqual(TrackListLayoutMetrics.nativeDividerAlpha, 0.18)
        _ = TrackListLayoutMetrics.dividerColor
        #if os(iOS) || os(macOS)
        _ = TrackListLayoutMetrics.nativeSeparatorColor
        #endif
    }

    func testRootChromeLayoutUsesRootViewportWhenIPadSidebarIsNotVisible() {
        let transientDetailLayout = RootChromeLayout(
            frame: CGRect(x: 140, y: 0, width: 416, height: 800),
            bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: transientDetailLayout,
            rootFallback: rootFallback,
            sidebarRegistration: .hidden,
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved, rootFallback)
    }

    func testRootChromeLayoutInfersContentViewportWhenSidebarVisibilityIsUnknown() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: CGRect(x: 184, y: 0, width: 372, height: 800),
                bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 0),
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .absent,
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 184, y: 0, width: 372, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootChromeLayoutUsesContentViewportWhenIPadSidebarOverlaysDetail() {
        let overlayDetailLayout = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: overlayDetailLayout,
            rootFallback: rootFallback,
            sidebarRegistration: .visible(frame: CGRect(x: 0, y: 0, width: 184, height: 800)),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 184, y: 0, width: 372, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootChromeLayoutUsesVisibleSidebarFallbackWidthWhenFrameIsUnavailable() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 900, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: rootFallback.frame,
                bottomPadding: rootFallback.bottomPadding,
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .visible(fallbackWidth: 260),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 260, y: 0, width: 640, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootChromeLayoutUsesRootFallbackWhenSidebarIsHidden() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 900, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: CGRect(x: 300, y: 0, width: 600, height: 800),
                bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 20),
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .hidden,
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, rootFallback.frame)
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootChromeLayoutIgnoresResolvedLayoutWhenSidebarIsVisible() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 900, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: rootFallback.frame,
                bottomPadding: rootFallback.bottomPadding,
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .visible(fallbackWidth: 260),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 260, y: 0, width: 640, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootChromeLayoutIgnoresTransientDetailFrameWhenSidebarFrameIsUnavailable() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 900, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: CGRect(x: 180, y: 0, width: 720, height: 760),
                bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 20),
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .visible(fallbackWidth: 260),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 260, y: 0, width: 640, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testRootSidebarChromeRegistrationFreezesEqualPriorityFrameDuringSameRootSize() {
        let current = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 184, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.inferredPriority
        )
        let pushedFrame = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 220, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.inferredPriority
        )

        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: current,
            next: pushedFrame,
            rootSizeChanged: false
        )

        XCTAssertEqual(stabilized, current)
    }

    func testRootSidebarChromeRegistrationKeepsCurrentWhenPreferenceIsAbsent() {
        let current = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 184, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.measuredPriority
        )

        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: current,
            next: .absent,
            rootSizeChanged: false
        )

        XCTAssertEqual(stabilized, current)
    }

    func testRootSidebarChromeRegistrationAcceptsMeasuredSidebarOverInferredFrame() {
        let inferred = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 220, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.inferredPriority
        )
        let measured = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 184, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.measuredPriority
        )

        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: inferred,
            next: measured,
            rootSizeChanged: false
        )

        XCTAssertEqual(stabilized, measured)
    }

    func testRootSidebarChromeRegistrationAcceptsFrameAfterRootSizeChange() {
        let current = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 184, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.inferredPriority
        )
        let rotated = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 260, height: 556),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.inferredPriority
        )

        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: current,
            next: rotated,
            rootSizeChanged: true
        )

        XCTAssertEqual(stabilized, rotated)
    }

    func testRootSidebarChromeRegistrationClearsWhenSidebarIsHidden() {
        let current = RootSidebarChromeRegistration.visible(
            frame: CGRect(x: 0, y: 0, width: 184, height: 800),
            fallbackWidth: 260,
            priority: RootSidebarChromeRegistration.measuredPriority
        )

        let stabilized = RootSidebarChromeRegistration.stabilized(
            current: current,
            next: .hidden,
            rootSizeChanged: false
        )

        XCTAssertEqual(stabilized, .hidden)
    }

    func testRootChromeLayoutIgnoresIPadDetailFrameChangesWhenSidebarIsStable() {
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )
        let sidebarFrame = CGRect(x: 0, y: 0, width: 184, height: 800)

        let rootResolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: rootFallback.frame,
                bottomPadding: rootFallback.bottomPadding,
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .visible(frame: sidebarFrame),
            rootBounds: rootFallback.frame
        )
        let pushedResolved = RootChromeLayoutResolver.resolvePadLayout(
            from: RootChromeLayout(
                frame: CGRect(x: 128, y: 0, width: 428, height: 760),
                bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 20),
                horizontalOffset: 0,
                showsMiniPlayer: true
            ),
            rootFallback: rootFallback,
            sidebarRegistration: .visible(frame: sidebarFrame),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(rootResolved, pushedResolved)
    }

    func testRootChromeLayoutUsesDetailSpanWhenIPadSidebarIsAdjacent() {
        let detailLayout = RootChromeLayout(
            frame: CGRect(x: 184, y: 0, width: 372, height: 556),
            bottomPadding: TrackListLayoutMetrics.detailMiniPlayerBottomLift(safeAreaBottom: 20),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )
        let rootFallback = RootChromeLayout(
            frame: CGRect(x: 0, y: 0, width: 556, height: 800),
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 0),
            horizontalOffset: 0,
            showsMiniPlayer: true
        )

        let resolved = RootChromeLayoutResolver.resolvePadLayout(
            from: detailLayout,
            rootFallback: rootFallback,
            sidebarRegistration: .visible(frame: CGRect(x: 0, y: 0, width: 184, height: 800)),
            rootBounds: rootFallback.frame
        )

        XCTAssertEqual(resolved.frame, CGRect(x: 184, y: 0, width: 372, height: 800))
        XCTAssertEqual(resolved.bottomPadding, rootFallback.bottomPadding)
        XCTAssertEqual(resolved.horizontalOffset, 0)
        XCTAssertTrue(resolved.showsMiniPlayer)
    }

    func testNativeTrackListFlatteningPreservesTrackIndexesAcrossSupplementaryRows() {
        let firstTrack = Track(id: "track-1", key: "/tracks/1", title: "Track 1")
        let secondTrack = Track(id: "track-2", key: "/tracks/2", title: "Track 2")
        let thirdTrack = Track(id: "track-3", key: "/tracks/3", title: "Track 3")

        let rows = NativeTrackListFlattening.rows(
            sections: [
                NativeTrackListSection(id: "disc-1", title: "Disc 1", tracks: [firstTrack, secondTrack]),
                NativeTrackListSection(id: "disc-2", title: "Disc 2", tracks: [thirdTrack])
            ],
            hasHeader: true,
            hasFooter: true,
            bottomContentInset: 18
        )

        XCTAssertEqual(rows.count, 8)
        XCTAssertEqual(rows[0], .header)
        XCTAssertEqual(rows[1], .section(id: "disc-1", title: "Disc 1"))
        XCTAssertEqual(rows[2], .track(firstTrack, globalIndex: 0))
        XCTAssertEqual(rows[3], .track(secondTrack, globalIndex: 1))
        XCTAssertEqual(rows[4], .section(id: "disc-2", title: "Disc 2"))
        XCTAssertEqual(rows[5], .track(thirdTrack, globalIndex: 2))
        XCTAssertEqual(rows[6], .footer)
        XCTAssertEqual(rows[7], .bottomSpacer(18))
    }

    func testScrollIndexCompactTrailingPaddingDoesNotOverlapViewportEdge() {
        XCTAssertGreaterThanOrEqual(EnsembleScaffold.ScrollIndex.compactTrailingPadding, 0)
    }

    func testScrollIndexHitStripStaysClearOfTrailingRowActions() {
        XCTAssertLessThanOrEqual(EnsembleScaffold.ScrollIndex.hitTargetWidth, 14)
    }

    func testScrollIndexMapsLetterCentersToContainingSlot() {
        let letterHeight = EnsembleScaffold.ScrollIndex.letterHeight
        let letterSpacing = EnsembleScaffold.ScrollIndex.letterSpacing
        let verticalPadding = EnsembleScaffold.ScrollIndex.verticalPadding
        let slotHeight = letterHeight + letterSpacing

        for index in 0..<26 {
            let centerY = verticalPadding + (CGFloat(index) * slotHeight) + (letterHeight / 2)
            XCTAssertEqual(
                ScrollIndex.letterIndex(
                    for: centerY,
                    letterCount: 26,
                    letterHeight: letterHeight,
                    letterSpacing: letterSpacing,
                    verticalPadding: verticalPadding
                ),
                index
            )
        }
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

    func testTrackRowInteractionModelCheapStateMatchesResolvedActions() {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            rating: 4,
            sourceCompositeKey: "plex:account:server:lib"
        )

        let model = TrackRowInteractionModel(
            onAddToRecentPlaylist: { _ in },
            isTrackFavorited: { $0.id == "track-1" },
            canAddToRecentPlaylist: { $0.id == "track-1" },
            recentPlaylistTitle: "Road Trip"
        )

        let resolved = model.resolve(for: track)

        XCTAssertEqual(model.isFavorited(track), resolved.isFavorited)
        XCTAssertEqual(model.hasContextMenu(for: track), resolved.hasContextMenu)
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

    func testTrackRowInteractionModelCallbacksReceiveSourceScopedTrack() {
        let subscriberTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:subscriber:server:music"
        )
        let freeAccountTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:free:server:music"
        )
        var toggledIdentities: [String] = []

        let model = TrackRowInteractionModel(
            onToggleFavorite: { track in
                toggledIdentities.append(track.sourceScopedID)
            },
            isTrackFavorited: { $0.sourceScopedID == freeAccountTrack.sourceScopedID }
        )

        let subscriberActions = model.resolve(for: subscriberTrack)
        let freeAccountActions = model.resolve(for: freeAccountTrack)
        subscriberActions.onToggleFavorite?()
        freeAccountActions.onToggleFavorite?()

        XCTAssertFalse(subscriberActions.isFavorited)
        XCTAssertTrue(freeAccountActions.isFavorited)
        XCTAssertEqual(toggledIdentities, [
            subscriberTrack.sourceScopedID,
            freeAccountTrack.sourceScopedID
        ])
    }

    func testMediaTrackListIdentityOrderUsesSourceScopedTrackID() {
        let subscriberTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:subscriber:server:music"
        )
        let freeAccountTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:free:server:music"
        )

        XCTAssertTrue(trackIdentityOrderMatches([subscriberTrack], [subscriberTrack]))
        XCTAssertFalse(trackIdentityOrderMatches([subscriberTrack], [freeAccountTrack]))
    }

    func testMediaMenuCatalogTrackLibraryContextIncludesBaseAndEditingActions() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .library,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .playlist, .navigation, .sharing, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .playlist), [.addToRecentPlaylist, .addToPlaylist, .favorite])
        XCTAssertEqual(sections.actions(in: .navigation), [.goToAlbum, .goToArtist])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareLink, .shareAudioFile])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .deleteTrack])
        XCTAssertEqual(sections.role(for: .deleteTrack), .destructive)
    }

    func testMediaMenuCatalogTrackMiniPlayerAddsTransportWithoutEditing() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: .full
        )

        XCTAssertEqual(sections.actions(in: .transport), [.toggleShuffle, .repeatAll, .repeatOne])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo])
        XCTAssertEqual(sections.role(for: .deleteTrack), nil)
    }

    func testMediaMenuCatalogQueueAndHistoryTrackContextsDivergeOnlyForRemoval() {
        let queue = MediaMenuCatalog.sections(
            for: .track,
            context: .queue(canRemove: true),
            availability: .full
        )
        let history = MediaMenuCatalog.sections(
            for: .track,
            context: .history,
            availability: .full
        )

        XCTAssertEqual(queue.actions(in: .destructive), [.removeFromQueue])
        XCTAssertEqual(queue.role(for: .removeFromQueue), .destructive)
        XCTAssertNil(history.first { $0.id == .destructive })
        XCTAssertEqual(queue.actions(in: .playback), history.actions(in: .playback))
        XCTAssertEqual(queue.actions(in: .playlist), history.actions(in: .playlist))
    }

    func testMediaMenuCatalogPlaylistTrackAddsRemoveFromPlaylist() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .playlistTrack(canRemove: true),
            availability: .full
        )

        XCTAssertEqual(sections.actions(in: .destructive), [.removeFromPlaylist])
        XCTAssertEqual(sections.role(for: .removeFromPlaylist), .destructive)
        XCTAssertEqual(sections.actions(in: .playback), [.playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .deleteTrack])
    }

    func testMediaMenuCatalogAlbumLibraryContextIncludesSharedActions() {
        let sections = MediaMenuCatalog.sections(
            for: .album,
            context: .library,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .playlist, .navigation, .sharing, .offline, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .radio, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .playlist), [.addToRecentPlaylist, .addToPlaylist])
        XCTAssertEqual(sections.actions(in: .navigation), [.goToArtist])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .deleteAlbum])
        XCTAssertEqual(sections.role(for: .deleteAlbum), .destructive)
    }

    func testMediaMenuCatalogArtistSearchContextKeepsSafeBaseActionsOnly() {
        let sections = MediaMenuCatalog.sections(
            for: .artist,
            context: .search,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .offline])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .radio])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertNil(sections.first { $0.id == .management })
    }

    func testMediaMenuCatalogSearchPlaylistIsNonDestructive() {
        let sections = MediaMenuCatalog.sections(
            for: .playlist(isSmart: false),
            context: .search,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .offline, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo])
    }

    func testMediaMenuCatalogLibraryPlaylistManagementExcludesSmartPlaylists() {
        let regular = MediaMenuCatalog.sections(
            for: .playlist(isSmart: false),
            context: .library,
            availability: .full
        )
        let smart = MediaMenuCatalog.sections(
            for: .playlist(isSmart: true),
            context: .library,
            availability: .full
        )

        XCTAssertEqual(regular.actions(in: .management), [.getInfo, .rename, .editPlaylist, .deletePlaylist])
        XCTAssertEqual(regular.role(for: .deletePlaylist), .destructive)
        XCTAssertEqual(smart.actions(in: .management), [.getInfo])
    }

    func testMediaMenuCatalogPinnedMergedPlaylistAddsUnpinAll() {
        let sections = MediaMenuCatalog.sections(
            for: .mergedPlaylist(isSmart: false),
            context: .pinned,
            availability: .full
        )

        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .pinning), [.unpinAll])
        XCTAssertEqual(sections.role(for: .unpinAll), .destructive)
        XCTAssertEqual(sections.actions(in: .management), [.renameAll, .deleteAll])
    }

    func testTrackActionPresentationUsesSharedFavoriteState() {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let resolved = TrackRowInteractionModel(
            onPlayNext: { _ in },
            onToggleFavorite: { _ in },
            isTrackFavorited: { _ in true }
        )
        .resolve(for: track)

        XCTAssertTrue(TrackActionPresentation.isSupported(.playNext, resolvedActions: resolved))
        XCTAssertTrue(TrackActionPresentation.isSupported(.favoriteToggle, resolvedActions: resolved))
        XCTAssertEqual(TrackActionPresentation.title(for: .favoriteToggle, resolvedActions: resolved), "Unfavorite")
        XCTAssertEqual(
            TrackActionPresentation.systemImage(for: .favoriteToggle, resolvedActions: resolved),
            EnsembleDesign.Icon.favoriteRemoveFilled
        )
        XCTAssertEqual(
            TrackActionPresentation.confirmationToast(for: .playNext, track: track, dedupeNamespace: "test")?.dedupeKey,
            "test-swipe-play-next-track-1"
        )
    }

    func testTrackActionPresentationDedupeKeysUseSourceScopedTrackIdentity() {
        let track = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:free:server:music"
        )

        XCTAssertEqual(
            TrackActionPresentation.confirmationToast(for: .playNext, track: track, dedupeNamespace: "test")?.dedupeKey,
            "test-swipe-play-next-plex:free:server:music||7551"
        )
        XCTAssertEqual(
            TrackActionPresentation.favoriteLoadingToast(for: track, willFavorite: true, dedupeNamespace: "test").dedupeKey,
            "test-favorite-toggle-loading-plex:free:server:music||7551"
        )
    }

    #if os(macOS)
    func testAppKitTrackContextMenuUsesSharedCatalogOrder() throws {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: "album-1",
            artistRatingKey: "artist-1"
        )
        let resolved = TrackRowInteractionModel(
            onPlayNext: { _ in },
            onPlayLast: { _ in },
            onAddToPlaylist: { _ in },
            onAddToRecentPlaylist: { _ in },
            onToggleFavorite: { _ in },
            onGoToAlbum: { _ in },
            onGoToArtist: { _ in },
            onGetInfo: { _ in },
            onEditMetadata: { _ in },
            onShareLink: { _ in },
            onShareFile: { _ in },
            onDeleteTrack: { _ in },
            isTrackFavorited: { _ in false },
            recentPlaylistTitle: "Road Trip"
        )
        .resolve(for: track)

        let menu = try XCTUnwrap(NativeMediaTableActionBuilder.contextMenu(for: track, resolvedActions: resolved))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(
            titles,
            [
                "Play Next",
                "Play Last",
                "Add to Road Trip",
                "Add to Playlist…",
                "Favorite",
                "Go to Album",
                "Go to Artist",
                "Share Link…",
                "Share Audio File…",
                "Get Info…",
                "Edit Metadata…",
                "Delete Track"
            ]
        )
    }

    func testAppKitQueueContextMenuAddsRemoveFromQueueThroughCatalog() throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let resolved = TrackRowInteractionModel(
            onPlayNext: { _ in },
            onPlayLast: { _ in }
        )
        .resolve(for: track)

        let menu = try XCTUnwrap(
            NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolved,
                context: .queue(canRemove: true),
                onRemoveFromQueue: {}
            )
        )
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(titles, ["Play Next", "Play Last", "Remove from Queue"])
    }

    func testAppKitPlaylistTrackContextMenuAddsRemoveFromPlaylistThroughCatalog() throws {
        let track = Track(id: "track-1", key: "/tracks/1", title: "Track")
        let resolved = TrackRowInteractionModel(
            onPlayNext: { _ in },
            onPlayLast: { _ in }
        )
        .resolve(for: track)

        let menu = try XCTUnwrap(
            NativeMediaTableActionBuilder.contextMenu(
                for: track,
                resolvedActions: resolved,
                context: .playlistTrack(canRemove: true),
                onRemoveFromPlaylist: {}
            )
        )
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(titles, ["Play Next", "Play Last", "Remove from Playlist"])
    }
    #endif
}

private extension Array where Element == MediaMenuSection {
    var ids: [MediaMenuSectionID] {
        map(\.id)
    }

    func actions(in sectionID: MediaMenuSectionID) -> [MediaMenuActionID] {
        first { $0.id == sectionID }?.actions.map(\.id) ?? []
    }

    func role(for actionID: MediaMenuActionID) -> MediaMenuActionDescriptor.Role? {
        flatMap(\.actions).first { $0.id == actionID }?.role
    }
}

private func makeTemporaryPNG() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("png")
    let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")!
    try data.write(to: url)
    return url
}

private func makePlatformImage(from url: URL) -> PlatformImage? {
    #if os(macOS)
        return NSImage(contentsOf: url)
    #else
        return UIImage(contentsOfFile: url.path)
    #endif
}

@MainActor
private final class RecordingForegroundWorkScheduler: ForegroundWorkScheduling, @unchecked Sendable {
    struct WaitCall: Equatable {
        let kind: ForegroundWorkKind
        let policy: ForegroundWorkPolicy
    }

    var isIdleForNonessentialWork = true
    private(set) var waitCalls: [WaitCall] = []

    func beginInteraction(_ state: ForegroundInteractionState) {}

    func endInteraction(_ state: ForegroundInteractionState) {}

    func setStartupSyncInFlight(_ inFlight: Bool) {}

    func setForegroundActive(_ active: Bool) {}

    func waitUntilAllowed(_ kind: ForegroundWorkKind, policy: ForegroundWorkPolicy) async -> Bool {
        waitCalls.append(WaitCall(kind: kind, policy: policy))
        return true
    }
}

private actor RecordingArtworkLoader: ArtworkLoaderProtocol {
    struct LocalRequest: Equatable {
        let minimumPixelDimension: Int?
        let allowStaleIdentity: Bool
    }

    let url: URL?
    let localURL: URL?
    private(set) var cacheRequests: [(hint: PersistentArtworkCacheHint?, minimumPixelDimension: Int?)] = []
    private(set) var localRequests: [LocalRequest] = []

    init(url: URL?, localURL: URL? = nil) {
        self.url = url
        self.localURL = localURL
    }

    func artworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        size: Int
    ) async -> URL? {
        url
    }

    func localArtworkURLAsync(
        for path: String?,
        sourceKey: String?,
        ratingKey: String?,
        fallbackPath: String?,
        fallbackRatingKey: String?,
        minimumPixelDimension: Int?,
        allowStaleIdentity: Bool
    ) async -> URL? {
        localRequests.append(
            LocalRequest(
                minimumPixelDimension: minimumPixelDimension,
                allowStaleIdentity: allowStaleIdentity
            )
        )
        return localURL
    }

    func cacheResolvedArtwork(
        from url: URL,
        cacheHint: PersistentArtworkCacheHint?,
        minimumPixelDimension: Int?
    ) async {
        cacheRequests.append((cacheHint, minimumPixelDimension))
    }

    func invalidateURLCache() async {}
}
