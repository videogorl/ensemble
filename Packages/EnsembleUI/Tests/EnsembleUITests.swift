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

    func testTrackListLayoutMetricsDividerTokens() {
        XCTAssertEqual(TrackListLayoutMetrics.nativeDividerAlpha, 0.18)
        _ = TrackListLayoutMetrics.dividerColor
        #if os(iOS) || os(macOS)
        _ = TrackListLayoutMetrics.nativeSeparatorColor
        #endif
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
        XCTAssertEqual(sections.actions(in: .management), [.editMetadata, .deleteTrack])
        XCTAssertEqual(sections.role(for: .deleteTrack), .destructive)
    }

    func testMediaMenuCatalogTrackMiniPlayerAddsTransportWithoutEditing() {
        let sections = MediaMenuCatalog.sections(
            for: .track,
            context: .miniPlayer,
            availability: .full
        )

        XCTAssertEqual(sections.actions(in: .transport), [.toggleShuffle, .repeatAll, .repeatOne])
        XCTAssertNil(sections.first { $0.id == .management })
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
        XCTAssertEqual(sections.actions(in: .management), [.editMetadata, .deleteTrack])
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
        XCTAssertEqual(sections.actions(in: .management), [.editMetadata, .deleteAlbum])
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

        XCTAssertEqual(sections.ids, [.playback, .offline])
        XCTAssertEqual(sections.actions(in: .playback), [.play, .shuffle, .playNext, .playLast])
        XCTAssertEqual(sections.actions(in: .offline), [.download, .pin])
        XCTAssertNil(sections.first { $0.id == .management })
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

        XCTAssertEqual(regular.actions(in: .management), [.rename, .editPlaylist, .deletePlaylist])
        XCTAssertEqual(regular.role(for: .deletePlaylist), .destructive)
        XCTAssertNil(smart.first { $0.id == .management })
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
