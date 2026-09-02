import EnsembleDesignTokens
import EnsembleDomain
import SwiftUI
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
    func testSceneScrollRestorationClampsOffsetsToContent() {
        let cases: [(requested: CGFloat, maximum: CGFloat, expected: CGFloat)] = [
            (-10, 100, 0),
            (40, 100, 40),
            (120, 100, 100),
            (40, -1, 0)
        ]

        for testCase in cases {
            XCTAssertEqual(
                SceneScrollRestoration.clampedOffset(
                    testCase.requested,
                    maximumOffset: testCase.maximum
                ),
                testCase.expected
            )
        }
    }

    func testMediaDetailSourceLabelsUseProviderOrLibraryAndServer() {
        let appleMusic = MusicSourcePresentation(
            capabilities: MusicSourceType.appleMusic.capabilities,
            serverName: "Apple Music",
            libraryName: "Apple Music",
            accountName: "This Device"
        )
        let plex = MusicSourcePresentation(
            capabilities: MusicSourceType.plex.capabilities,
            serverName: "Minibar",
            libraryName: "Music",
            accountName: "Plex Account"
        )

        XCTAssertEqual(
            mediaDetailSourceLabel(
                sourceType: .appleMusic,
                presentation: appleMusic,
                demoModeEnabled: false
            ),
            "Apple Music"
        )
        XCTAssertEqual(
            mediaDetailSourceLabel(
                sourceType: .plex,
                presentation: plex,
                demoModeEnabled: false
            ),
            "Music · Minibar"
        )
        XCTAssertEqual(
            mediaDetailSourceLabel(
                sourceType: .plex,
                presentation: plex,
                demoModeEnabled: true
            ),
            "Music · Plex Server"
        )
    }

    func testDuplicateProfileFocusServerTitleIncludesAccountEmail() {
        XCTAssertEqual(
            ProfileToolbarButton.serverSectionTitle(
                "Server Name",
                email: "email@domain.com",
                isDuplicate: true
            ),
            "Server Name (email@domain.com)"
        )
    }

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

    func testNowPlayingWidePanelQueueTitleReflectsHistoryMode() {
        XCTAssertEqual(NowPlayingPanelPage.queue.title(showsHistory: false), "Queue")
        XCTAssertEqual(NowPlayingPanelPage.queue.title(showsHistory: true), "History")
        XCTAssertEqual(NowPlayingPanelPage.lyrics.title(showsHistory: true), "Lyrics")
        XCTAssertEqual(NowPlayingPanelPage.info.title(showsHistory: true), "Info")
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

    func testAccentPalettePreservesTheExistingPinkColor() {
        XCTAssertEqual(
            AppAccentColor.pink.color,
            Color(red: 1, green: 0, blue: 1)
        )
    }

    func testMediaHeaderArtworkIdentityIsSourceScopedAndTracksFallbackRelinking() throws {
        let path = "/library/metadata/shared/thumb"
        let firstHeader = MediaHeaderData(
            title: "Playlist",
            metadataLine: "",
            artworkPath: path,
            sourceKey: "plex:account-a:server:library",
            ratingKey: "shared"
        )
        let secondHeader = MediaHeaderData(
            title: "Playlist",
            metadataLine: "",
            artworkPath: path,
            sourceKey: "plex:account-b:server:library",
            ratingKey: "shared"
        )
        let firstPrimary = try XCTUnwrap(makeMediaHeaderArtworkRequest(
            headerData: firstHeader,
            mediaType: .playlist
        ))
        let secondPrimary = try XCTUnwrap(makeMediaHeaderArtworkRequest(
            headerData: secondHeader,
            mediaType: .playlist
        ))
        XCTAssertNotEqual(firstPrimary.stableBlurCacheKey, secondPrimary.stableBlurCacheKey)

        func fallbackDescriptor(sourceKey: String?) -> ArtworkRequest {
            ArtworkRequest(
                path: path,
                sourceKey: sourceKey,
                ratingKey: "album-1",
                fallbackPath: nil,
                fallbackRatingKey: nil,
                identity: nil,
                fallbackIdentity: nil,
                tier: .hero,
                priority: .high
            )
        }

        XCTAssertNotEqual(
            mediaHeaderArtworkLoadIdentity(
                primary: firstPrimary,
                fallback: fallbackDescriptor(sourceKey: firstHeader.sourceKey)
            ),
            mediaHeaderArtworkLoadIdentity(
                primary: firstPrimary,
                fallback: fallbackDescriptor(sourceKey: secondHeader.sourceKey)
            )
        )
    }

    func testMediaHeaderBlurCacheKeyUsesResolvedFallbackIdentity() {
        let primary = ArtworkRequest(
            path: "/playlists/playlist-1/composite",
            sourceKey: "plex:account:server",
            ratingKey: "playlist-1",
            fallbackPath: nil,
            fallbackRatingKey: nil,
            identity: nil,
            fallbackIdentity: nil,
            tier: .hero,
            priority: .high
        )
        let fallback = ArtworkRequest(
            path: "https://example.com/album/{w}x{h}.jpg",
            sourceKey: "appleMusic:device:system:library",
            ratingKey: "album-1",
            fallbackPath: nil,
            fallbackRatingKey: nil,
            identity: nil,
            fallbackIdentity: nil,
            tier: .hero,
            priority: .high
        )

        XCTAssertNil(mediaHeaderBlurCacheKey(
            resolvedBlurCacheKey: nil,
            requests: [primary, fallback]
        ))
        XCTAssertEqual(
            mediaHeaderBlurCacheKey(
                resolvedBlurCacheKey: fallback.stableBlurCacheKey,
                requests: [primary, fallback]
            ),
            fallback.stableBlurCacheKey
        )
    }

    func testPlaylistHeaderUsesPersistedFallbackWhenCompositeIsMissing() throws {
        let sourceKey = "appleMusic:device:system:library"
        let fallbackPath = "https://example.com/album/{w}x{h}.jpg"
        let playlist = Playlist(
            id: "playlist-1",
            key: "playlist-1",
            title: "Sleepy Ambient",
            fallbackArtworkPath: fallbackPath,
            fallbackArtworkRatingKey: "album-1",
            fallbackArtworkSourceCompositeKey: sourceKey,
            sourceCompositeKey: sourceKey
        )

        let request = try XCTUnwrap(makePlaylistHeaderFallbackArtworkRequest(
            playlist: playlist,
            track: nil,
            fallbackSourceKey: nil
        ))

        XCTAssertEqual(request.path, fallbackPath)
        XCTAssertEqual(request.ratingKey, "album-1")
        XCTAssertEqual(request.sourceKey, sourceKey)
        XCTAssertEqual(request.identity?.kind, .album)
        XCTAssertEqual(request.identity?.ratingKey, "album-1")
        XCTAssertEqual(request.identity?.sourceCompositeKey, sourceKey)
    }

    func testPlaylistHeaderStillFallsBackToLoadedTrackArtwork() throws {
        let artworkPath = "/library/metadata/album-1/thumb"
        let track = Track(
            id: "track-1",
            key: "track-1",
            title: "Track",
            albumRatingKey: "album-1",
            thumbPath: artworkPath,
            fallbackThumbPath: artworkPath,
            sourceCompositeKey: "plex:account:server:library"
        )

        let request = try XCTUnwrap(makePlaylistHeaderFallbackArtworkRequest(
            playlist: nil,
            track: track,
            fallbackSourceKey: nil
        ))

        XCTAssertEqual(request.path, artworkPath)
        XCTAssertEqual(request.ratingKey, "track-1")
        XCTAssertEqual(request.fallbackPath, artworkPath)
        XCTAssertEqual(request.fallbackRatingKey, "album-1")
        XCTAssertEqual(request.fallbackIdentity?.kind, .album)
        XCTAssertEqual(request.fallbackIdentity?.ratingKey, "album-1")
        XCTAssertEqual(request.fallbackIdentity?.sourceCompositeKey, "plex:account:server:library")
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
        XCTAssertEqual(localRequests.first?.minimumPixelDimension, ArtworkSize.thumbnail.requestPixelDimension)
        XCTAssertEqual(localRequests.first?.allowStaleIdentity, true)
    }

    func testArtworkPreBlurUsesVisibleArtworkSchedulerByDefault() async throws {
        let artworkURL = try makeTemporaryPNG()
        defer { try? FileManager.default.removeItem(at: artworkURL) }
        let image = try XCTUnwrap(makePlatformImage(from: artworkURL))
        let scheduler = await MainActor.run { RecordingForegroundWorkScheduler() }

        let artworkLoader = RecordingArtworkLoader(url: nil)
        let blurredImage = await artworkLoader.blurredImage(
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
        let localFilePath = NSTemporaryDirectory() + "lossless_\(UUID().uuidString).FLAC"
        FileManager.default.createFile(atPath: localFilePath, contents: Data("audio".utf8))
        defer { try? FileManager.default.removeItem(atPath: localFilePath) }

        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Lossless",
            artistName: "Artist",
            localFilePath: localFilePath,
            downloadedQuality: "original"
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

    @MainActor
    func testMacSidebarPlaylistDropRegistryTargetsAndDisablesRows() {
        let registry = MacSidebarPlaylistDropRegistry.shared
        let acceptableID = UUID()
        let duplicateID = UUID()
        let payload = MediaDragPayload.track(Track(id: "track", key: "/tracks/1", title: "Track"))
        var acceptableTargeted = false
        var duplicateDisabled = false
        var didDrop = false
        defer {
            registry.endDragging()
            registry.remove(id: acceptableID)
            registry.remove(id: duplicateID)
        }

        registry.update(
            id: acceptableID,
            frame: NSRect(x: 0, y: 0, width: 100, height: 40),
            canAccept: { _ in true },
            onTargetedChange: { acceptableTargeted = $0 },
            onDisabledChange: { _ in },
            onDrop: { _ in
                didDrop = true
                return true
            }
        )
        registry.update(
            id: duplicateID,
            frame: NSRect(x: 0, y: 50, width: 100, height: 40),
            canAccept: { _ in false },
            onTargetedChange: { _ in XCTFail("Duplicate target should not highlight") },
            onDisabledChange: { duplicateDisabled = $0 },
            onDrop: { _ in
                XCTFail("Duplicate target should not receive a drop")
                return false
            }
        )

        registry.beginDragging(payload)
        XCTAssertTrue(duplicateDisabled)

        registry.updateTarget(at: NSPoint(x: 20, y: 20))
        XCTAssertTrue(acceptableTargeted)
        XCTAssertTrue(registry.performDrop(at: NSPoint(x: 20, y: 20)))
        XCTAssertTrue(didDrop)

        registry.updateTarget(at: NSPoint(x: 20, y: 60))
        XCTAssertFalse(acceptableTargeted)
        XCTAssertFalse(registry.performDrop(at: NSPoint(x: 20, y: 60)))
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
        XCTAssertEqual(
            TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                safeAreaBottom: 0,
                tabBarBottomClearance: 74
            ),
            86
        )
        XCTAssertEqual(
            TrackListLayoutMetrics.rootMiniPlayerBottomLift(
                safeAreaBottom: 34,
                tabBarBottomClearance: 83
            ),
            61
        )
        XCTAssertEqual(TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20), 0)
    }

    func testTrackListLayoutMetricsRowInsets() {
        let insets = TrackListLayoutMetrics.rowInsets()

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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            bottomPadding: TrackListLayoutMetrics.rootMiniPlayerBottomLift(safeAreaBottom: 20),
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
            recentPlaylistTitle: "Global Road Trip",
            recentPlaylistTitleForTrack: { _ in "Source Road Trip" }
        )

        let resolved = model.resolve(for: track)

        XCTAssertNotNil(resolved.onPlayNext)
        XCTAssertNotNil(resolved.onAddToRecentPlaylist)
        XCTAssertNotNil(resolved.onToggleFavorite)
        XCTAssertEqual(resolved.recentPlaylistTitle, "Source Road Trip")
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
            onPlayNext: { _ in },
            onAddToRecentPlaylist: { _ in },
            isTrackFavorited: { $0.id == "track-1" },
            canAddToRecentPlaylist: { $0.id == "track-1" },
            recentPlaylistTitle: "Road Trip"
        )

        let resolved = model.resolve(for: track)

        XCTAssertEqual(model.isFavorited(track), resolved.isFavorited)
        XCTAssertEqual(model.hasContextMenu(for: track), resolved.hasContextMenu)
        XCTAssertTrue(model.hasHandler(for: .playNext))
        XCTAssertFalse(model.hasHandler(for: .favoriteToggle))
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

    func testMergedTrackFollowUpActionsSelectSourceAndOfferAllOnlyForHide() {
        let first = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            sourceCompositeKey: "plex:account:server:library-1"
        )
        let second = Track(
            id: "track-2",
            key: "/tracks/2",
            title: "Track",
            sourceCompositeKey: "plex:account:server:library-2"
        )
        var selections: [(title: String, includesAll: Bool)] = []
        let model = TrackRowInteractionModel(
            onAddToPlaylist: { _ in },
            onToggleHidden: { _ in },
            mutationCandidates: { _ in [first, second] },
            onSelectMutationSource: { title, _, allAction, _ in
                selections.append((title, allAction != nil))
            }
        )

        let resolved = model.resolve(for: first)
        resolved.onAddToPlaylist?()
        resolved.onToggleHidden?()

        XCTAssertEqual(selections.map(\.title), ["Add Song to Playlist", "Hide Song"])
        XCTAssertEqual(selections.map(\.includesAll), [false, true])
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
        let tracks = [subscriberTrack]
        let sharedTracks = tracks
        let copiedTracks = tracks.map { $0 }

        XCTAssertTrue(trackIdentityOrderMatches([subscriberTrack], [subscriberTrack]))
        XCTAssertFalse(trackIdentityOrderMatches([subscriberTrack], [freeAccountTrack]))
        XCTAssertTrue(arraysShareStorage(tracks, sharedTracks))
        XCTAssertFalse(arraysShareStorage(tracks, copiedTracks))
    }

    func testMediaTrackListStateComparisonFindsDownloadChangesInOnePass() {
        let remoteTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            sourceCompositeKey: "plex:subscriber:server:music"
        )
        let downloadedTrack = Track(
            id: "7551",
            key: "/tracks/7551",
            title: "Techno Jeep",
            localFilePath: "/tmp/7551.flac",
            sourceCompositeKey: "plex:subscriber:server:music"
        )

        let comparison = compareTrackListState([remoteTrack], [downloadedTrack])

        XCTAssertTrue(comparison.identityOrderMatches)
        XCTAssertTrue(comparison.downloadStateChanged)
    }

    func testMediaMenuCatalogTrackLibraryContextIncludesBaseAndEditingActions() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .library,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .playlist, .navigation, .sharing, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .playlist), [.addToLibrary, .addToPlaylist, .addToRecentPlaylist, .favorite])
        XCTAssertEqual(sections.actions(in: .navigation), [.goToAlbum, .goToArtist])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareEnsembleLink, .shareLink, .shareAudioFile])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .toggleHidden, .deleteTrack])
        XCTAssertEqual(sections.role(for: .deleteTrack), .destructive)
    }

    func testMediaMenuCatalogTrackMiniPlayerAddsTransportWithoutEditing() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: .full
        )

        XCTAssertEqual(sections.actions(in: .transport), [.toggleShuffle, .repeatAll, .repeatOne])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .toggleHidden])
        XCTAssertEqual(sections.role(for: .deleteTrack), nil)
    }

    func testTrackRowInteractionModelAddsOnlyCatalogAppleMusicTracksToLibrary() {
        let source = MusicSourceIdentifier.appleMusic.compositeKey
        let catalog = Track(id: "song", key: "apple-catalog", title: "Song", sourceCompositeKey: source)
        let library = Track(id: "library-song", key: "apple-library:song", title: "Song", sourceCompositeKey: source)
        let model = TrackRowInteractionModel(onAddToLibrary: { _ in })

        XCTAssertNotNil(model.resolve(for: catalog).onAddToLibrary)
        XCTAssertNil(model.resolve(for: library).onAddToLibrary)
    }

    func testTrackRowInteractionModelHidesAcceptedLibraryAdd() {
        let source = MusicSourceIdentifier.appleMusic.compositeKey
        let track = Track(id: "song", key: "apple-catalog", title: "Song", sourceCompositeKey: source)
        var canAdd = true
        let model = TrackRowInteractionModel(
            onAddToLibrary: { _ in },
            canAddToLibrary: { _ in canAdd }
        )

        XCTAssertNotNil(model.resolve(for: track).onAddToLibrary)
        canAdd = false
        XCTAssertNil(model.resolve(for: track).onAddToLibrary)
    }

    func testTrackRowInteractionModelUsesNormalizedAppleMusicActionAvailability() {
        let track = Track(
            id: "apple-song",
            key: "apple-library:apple-song",
            title: "Song",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let model = TrackRowInteractionModel(
            onToggleFavorite: { _ in },
            onEditMetadata: { _ in },
            onDeleteTrack: { _ in },
            isTrackFavorited: { _ in true }
        )

        let resolved = model.resolve(for: track)

        XCTAssertNotNil(resolved.onToggleFavorite)
        XCTAssertNotNil(resolved.onEditMetadata)
        XCTAssertNotNil(resolved.onDeleteTrack)
        XCTAssertFalse(resolved.favoriteAvailability.isAvailable)
        XCTAssertFalse(resolved.editMetadataAvailability.isAvailable)
        XCTAssertFalse(resolved.deleteAvailability.isAvailable)
        XCTAssertTrue(model.hasContextMenu(for: track))
    }

    func testMediaMenuCatalogRetainsDisabledModelActionAndReason() throws {
        let availability = MusicItemActionAvailability.readOnly(reason: "This playlist is read-only.")
        let sections = MediaMenuCatalog.sections(
            for: .playlist(isSmart: false),
            context: .library,
            availability: MediaMenuAvailability(
                canRename: true,
                itemActions: [.rename: availability]
            )
        )

        let rename = try XCTUnwrap(sections.flatMap(\.actions).first { $0.id == .rename })
        XCTAssertEqual(rename.availability, availability)
        XCTAssertFalse(rename.availability.isAvailable)
        XCTAssertEqual(rename.availability.reason, "This playlist is read-only.")
    }

    func testMediaMenuCatalogRetainsUnavailableAppleUnfavoriteForMiniPlayer() throws {
        let availability = MusicItemActionAvailability.unavailable(
            reason: "Apple Music favorites cannot be removed in Ensemble."
        )
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: MediaMenuAvailability(
                canFavorite: true,
                itemActions: [.favorite: availability]
            )
        )
        let renderable = MediaMenuCatalog.renderableSections(
            sections,
            state: MediaMenuState(isFavorited: true),
            handlers: MediaMenuHandlers(favorite: {})
        )

        let favorite = try XCTUnwrap(renderable.flatMap(\.actions).first { $0.id == .favorite })
        XCTAssertEqual(favorite.label(state: MediaMenuState(isFavorited: true))?.title, "Unfavorite")
        XCTAssertEqual(favorite.availability, availability)
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
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .toggleHidden, .deleteTrack])
    }

    func testMediaMenuCatalogAlbumLibraryContextIncludesSharedActions() {
        let sections = MediaMenuCatalog.sections(
            for: .album,
            context: .library,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .playlist, .navigation, .sharing, .offline, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .radio, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .playlist), [.addToPlaylist, .addToRecentPlaylist])
        XCTAssertEqual(sections.actions(in: .navigation), [.goToArtist])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareEnsembleLink, .shareLink])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .editMetadata, .toggleHidden, .deleteAlbum])
        XCTAssertEqual(sections.role(for: .deleteAlbum), .destructive)
    }

    func testMediaMenuCatalogArtistSearchContextKeepsSafeBaseActionsOnly() {
        let sections = MediaMenuCatalog.sections(
            for: .artist,
            context: .search,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .offline, .sharing, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .radio])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareEnsembleLink])
        XCTAssertEqual(sections.actions(in: .management), [.toggleHidden])
    }

    func testMediaMenuCatalogSearchPlaylistIsNonDestructive() {
        let sections = MediaMenuCatalog.sections(
            for: .playlist(isSmart: false),
            context: .search,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .offline, .sharing, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareEnsembleLink])
        XCTAssertEqual(sections.actions(in: .management), [.getInfo, .toggleHidden])
    }

    func testMediaMenuCatalogSearchMergedPlaylistIsNonDestructive() {
        let sections = MediaMenuCatalog.sections(
            for: .mergedPlaylist(isSmart: false),
            context: .search,
            availability: .full
        )

        XCTAssertEqual(sections.ids, [.playback, .offline, .sharing, .management])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .offline), [.download])
        XCTAssertEqual(sections.actions(in: .sharing), [.shareEnsembleLink])
        XCTAssertEqual(sections.actions(in: .management), [.toggleHidden])
    }

    func testMediaMenuCatalogRetainsSmartPlaylistManagementActionsAsReadOnly() throws {
        let regular = MediaMenuCatalog.sections(
            for: .playlist(isSmart: false),
            context: .library,
            availability: .full
        )
        let readOnly = MusicItemActionAvailability.readOnly(reason: "Smart playlists are read-only.")
        let smart = MediaMenuCatalog.sections(
            for: .playlist(isSmart: true),
            context: .library,
            availability: MediaMenuAvailability(
                itemActions: [
                    .rename: readOnly,
                    .editPlaylist: readOnly,
                    .deletePlaylist: readOnly
                ]
            )
        )

        XCTAssertEqual(regular.actions(in: .management), [.getInfo, .rename, .editPlaylist, .toggleHidden, .deletePlaylist])
        XCTAssertEqual(regular.role(for: .deletePlaylist), .destructive)
        XCTAssertEqual(smart.actions(in: .management), [.getInfo, .rename, .editPlaylist, .toggleHidden, .deletePlaylist])
        for actionID in [MediaMenuActionID.rename, .editPlaylist, .deletePlaylist] {
            let action = try XCTUnwrap(smart.flatMap(\.actions).first { $0.id == actionID })
            XCTAssertEqual(action.availability, readOnly)
        }
    }

    func testMediaMenuCatalogOmitsSmartPlaylistManagementWithoutHandlers() {
        let sections = MediaMenuCatalog.sections(
            for: .playlist(isSmart: true),
            context: .library,
            availability: .full
        )
        let renderable = MediaMenuCatalog.renderableSections(
            sections,
            state: MediaMenuState(),
            handlers: MediaMenuHandlers(getInfo: {})
        )

        XCTAssertEqual(renderable.actions(in: .management), [.getInfo])
    }

    func testMediaMenuCatalogRetainsMergedSmartManagementActionsAsReadOnly() throws {
        let readOnly = MusicItemActionAvailability.readOnly(reason: "Smart playlists are read-only.")
        let sections = MediaMenuCatalog.sections(
            for: .mergedPlaylist(isSmart: true),
            context: .library,
            availability: MediaMenuAvailability(
                itemActions: [
                    .rename: readOnly,
                    .deletePlaylist: readOnly
                ]
            )
        )

        XCTAssertEqual(sections.actions(in: .management), [.rename, .toggleHidden, .deletePlaylist])
        for actionID in [MediaMenuActionID.rename, .deletePlaylist] {
            let action = try XCTUnwrap(sections.flatMap(\.actions).first { $0.id == actionID })
            XCTAssertEqual(action.availability, readOnly)
        }
    }

    func testDownloadMenuKeepsLocalRemovalAvailableWhenSourceSyncIsUnavailable() {
        let sourceAvailability = MusicItemActionAvailability.unavailable(
            reason: "This source is unavailable."
        )

        XCTAssertEqual(
            resolvedDownloadMenuAvailability(
                isDownloaded: true,
                sourceAvailability: sourceAvailability
            ),
            .available
        )
        XCTAssertEqual(
            resolvedDownloadMenuAvailability(
                isDownloaded: false,
                sourceAvailability: sourceAvailability
            ),
            sourceAvailability
        )
    }

    func testDetailMenuKeepsUnknownDownloadVisibleButUnavailable() {
        let album = Album(id: "legacy", key: "/album/legacy", title: "Legacy")
        let availability = album.actionAvailability(for: .download)

        XCTAssertEqual(
            resolvedDownloadMenuAvailability(
                isDownloaded: false,
                sourceAvailability: availability
            ),
            .unavailable(reason: "This item’s music source is unknown.")
        )
    }

    func testPlaylistDetailEditAvailabilityPreservesModelReasonAndLocalReadiness() {
        let readOnly = MusicItemActionAvailability.readOnly(reason: "Smart playlists are read-only.")
        XCTAssertEqual(
            resolvedPlaylistDetailEditAvailability(
                actionAvailability: readOnly,
                canEditContents: true,
                unavailableReason: "Playlist contents are not available to edit."
            ),
            readOnly
        )
        XCTAssertEqual(
            resolvedPlaylistDetailEditAvailability(
                actionAvailability: .available,
                canEditContents: false,
                unavailableReason: "Playlist contents are not available to edit."
            ),
            .unavailable(reason: "Playlist contents are not available to edit.")
        )
    }

    func testMergedDetailDownloadUsesAnyDownloadableOrDownloadedConstituent() {
        let apple = Playlist(
            id: "apple",
            key: "apple",
            title: "Mix",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let plex = Playlist(
            id: "plex",
            key: "/playlists/plex",
            title: "Mix",
            sourceCompositeKey: "plex:account:server"
        )
        let sourceAvailabilities = [
            apple.actionAvailability(for: .download),
            plex.actionAvailability(for: .download)
        ]

        XCTAssertEqual(
            resolvedMergedDownloadMenuAvailability(
                isAnyDownloaded: false,
                sourceAvailabilities: sourceAvailabilities
            ),
            .available
        )
        XCTAssertEqual(
            resolvedMergedDownloadMenuAvailability(
                isAnyDownloaded: true,
                sourceAvailabilities: [.unavailable(reason: "New downloads are unavailable.")]
            ),
            .available
        )
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
        XCTAssertEqual(sections.actions(in: .management), [.rename, .toggleHidden, .deletePlaylist])
    }

    func testTrackActionPresentationUsesSharedFavoriteState() {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            sourceCompositeKey: "plex:account:server:library"
        )
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
            "test-swipe-play-next-plex:account:server:library||track-1"
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
    func testAppKitTrackMenuRendersUnavailableAppleActionDisabledWithReason() throws {
        let track = Track(
            id: "apple-song",
            key: "apple-library:apple-song",
            title: "Song",
            sourceCompositeKey: MusicSourceIdentifier.appleMusic.compositeKey
        )
        let resolved = TrackRowInteractionModel(
            onToggleFavorite: { _ in },
            isTrackFavorited: { _ in true }
        )
        .resolve(for: track)

        let menu = try XCTUnwrap(NativeMediaTableActionBuilder.contextMenu(for: track, resolvedActions: resolved))
        let favoriteItem = try XCTUnwrap(menu.items.first { $0.title == "Unfavorite" })

        XCTAssertFalse(favoriteItem.isEnabled)
        XCTAssertEqual(favoriteItem.toolTip, "Apple Music favorites cannot be removed in Ensemble.")
    }

    func testAppKitTrackContextMenuUsesSharedCatalogOrder() throws {
        let track = Track(
            id: "track-1",
            key: "/tracks/1",
            title: "Track",
            artistName: "Artist",
            albumName: "Album",
            albumRatingKey: "album-1",
            artistRatingKey: "artist-1",
            sourceCompositeKey: "plex:account-1:server-1:library-1"
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
            onShareEnsembleLink: { _ in },
            onShareLink: { _ in },
            onShareFile: { _ in },
            onDeleteTrack: { _ in },
            onToggleHidden: { _ in },
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
                "Add to Playlist…",
                "Add to Road Trip",
                "Favorite",
                "Go to Album",
                "Go to Artist",
                "Share Ensemble Link…",
                "Share Link…",
                "Share Audio File…",
                "Get Info…",
                "Edit Metadata…",
                "Hide",
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
        let path: String?
        let sourceKey: String?
        let ratingKey: String?
        let minimumPixelDimension: Int?
        let allowStaleIdentity: Bool
    }

    let url: URL?
    let localURL: URL?
    private(set) var localRequests: [LocalRequest] = []

    init(
        url: URL?,
        localURL: URL? = nil
    ) {
        self.url = url
        self.localURL = localURL
    }

    func resolve(
        _ request: ArtworkRequest,
        policy: ArtworkResolutionPolicy
    ) async -> ArtworkImageResolutionOutcome {
        let resolvedURL = localURL ?? (policy == .allowRemote ? url : nil)
        if localURL != nil {
            localRequests.append(LocalRequest(
                path: request.path,
                sourceKey: request.sourceKey,
                ratingKey: request.ratingKey,
                minimumPixelDimension: request.tier.rawValue,
                allowStaleIdentity: true
            ))
        }
        guard let resolvedURL else { return .unavailable(.noArtworkURL) }
        #if canImport(UIKit)
        let image = UIImage(contentsOfFile: resolvedURL.path)
        #else
        let image = NSImage(contentsOf: resolvedURL)
        #endif
        guard let image else { return .unavailable(.imageLoadFailed(resolvedURL)) }
        return .resolved(ArtworkResolvedImage(
            url: resolvedURL,
            image: image,
            blurCacheKey: request.stableBlurCacheKey,
            identityKey: request.stableIdentityKey
        ))
    }

    func invalidateURLCache() async {}

    @MainActor
    func clearCaches() async throws {}
}
