import XCTest
@testable import EnsembleCore

@MainActor
final class PlaylistDropResolverTests: XCTestCase {
    private let resolver = PlaylistDropResolver()

    func testResolvesTrackAlbumAndPlaylistDropsWithDedupe() async throws {
        let target = makePlaylist(id: "target", title: "Road Trip")
        let sourcePlaylist = makePlaylist(id: "source", title: "Source")
        let album = makeAlbum(id: "album")
        let trackOne = makeTrack(id: "track-1")
        let trackTwo = makeTrack(id: "track-2")
        let trackThree = makeTrack(id: "track-3")

        let resolution = try await resolver.resolve(
            references: [
                .init(kind: .track, id: trackOne.id, sourceKey: trackOne.sourceCompositeKey, title: trackOne.title),
                .init(kind: .album, id: album.id, sourceKey: album.sourceCompositeKey, title: album.title),
                .init(kind: .playlist, id: sourcePlaylist.id, sourceKey: sourcePlaylist.sourceCompositeKey, title: sourcePlaylist.title)
            ],
            target: makeTarget(target),
            tracks: [trackOne, trackTwo, trackThree],
            albums: [album],
            playlists: [target, sourcePlaylist],
            loadAlbumTracks: { _ in [trackTwo, trackOne] },
            loadPlaylistTracks: { playlist in
                playlist.id == sourcePlaylist.id ? [trackThree, trackTwo] : []
            }
        )

        XCTAssertEqual(resolution.targetPlaylist.id, target.id)
        XCTAssertEqual(resolution.tracks.map(\.id), ["track-1", "track-2", "track-3"])
    }

    func testExcludesCachedTargetTracksAndRejectsAnAllDuplicateDrop() async throws {
        let target = makePlaylist(id: "target", title: "Road Trip")
        let existingTrack = makeTrack(id: "existing")
        let newTrack = makeTrack(id: "new")

        let resolution = try await resolver.resolve(
            references: [
                .init(kind: .track, id: existingTrack.id, sourceKey: existingTrack.sourceCompositeKey, title: existingTrack.title),
                .init(kind: .track, id: newTrack.id, sourceKey: newTrack.sourceCompositeKey, title: newTrack.title)
            ],
            target: makeTarget(target),
            tracks: [existingTrack, newTrack],
            albums: [],
            playlists: [target],
            loadAlbumTracks: { _ in [] },
            loadPlaylistTracks: { _ in [existingTrack] }
        )

        XCTAssertEqual(resolution.tracks.map(\.id), [newTrack.id])

        await assertDropError(
            expected: .alreadyContainsSelection(playlistTitle: target.title),
            references: [
                .init(kind: .track, id: existingTrack.id, sourceKey: existingTrack.sourceCompositeKey, title: existingTrack.title)
            ],
            target: makeTarget(target),
            tracks: [existingTrack],
            playlists: [target],
            loadPlaylistTracks: { _ in [existingTrack] }
        )
    }

    func testRejectsMergedSmartAndUnresolvedTargets() async throws {
        let regularTarget = makePlaylist(id: "target", title: "Road Trip")
        let smartTarget = makePlaylist(id: "smart", title: "Smart Mix", isSmart: true)

        await assertDropError(
            expected: .mergedTarget(title: "Merged"),
            target: .init(id: "target", sourceKey: regularTarget.sourceCompositeKey, title: "Merged", isSmart: false, isMerged: true),
            playlists: [regularTarget]
        )

        await assertDropError(
            expected: .smartTarget(title: smartTarget.title),
            target: makeTarget(smartTarget),
            playlists: [smartTarget]
        )

        await assertDropError(
            expected: .unresolvedTarget(title: "Missing"),
            target: .init(id: "missing", sourceKey: "plex:account:server", title: "Missing", isSmart: false, isMerged: false),
            playlists: [regularTarget]
        )
    }

    func testMergedTargetsSelectACompatibleConstituentThatCanAcceptTheTrack() async throws {
        let foreignTarget = makePlaylist(
            id: "foreign",
            title: "Road Trip",
            sourceCompositeKey: "plex:account:server-a"
        )
        let duplicateTarget = makePlaylist(
            id: "duplicate",
            title: "Road Trip",
            sourceCompositeKey: "plex:account:server-b"
        )
        let availableTarget = makePlaylist(
            id: "available",
            title: "Road Trip",
            sourceCompositeKey: "plex:account:server-b"
        )
        let track = makeTrack(
            id: "track",
            sourceCompositeKey: "plex:account:server-b:library"
        )
        let reference = MediaDropItemReference(
            kind: .track,
            id: track.id,
            sourceKey: track.sourceCompositeKey,
            title: track.title
        )

        XCTAssertFalse(resolver.canAccept(
            references: [reference],
            target: makeTarget(foreignTarget),
            existingTrackIDs: []
        ))
        XCTAssertFalse(resolver.canAccept(
            references: [reference],
            target: makeTarget(duplicateTarget),
            existingTrackIDs: [track.id]
        ))
        XCTAssertTrue(resolver.canAccept(
            references: [reference],
            target: makeTarget(availableTarget),
            existingTrackIDs: []
        ))

        let resolution = try await resolver.resolve(
            references: [reference],
            targets: [
                makeTarget(foreignTarget),
                makeTarget(duplicateTarget),
                makeTarget(availableTarget)
            ],
            tracks: [track],
            albums: [],
            playlists: [foreignTarget, duplicateTarget, availableTarget],
            loadAlbumTracks: { _ in [] },
            loadPlaylistTracks: { playlist in
                playlist.id == duplicateTarget.id ? [track] : []
            }
        )

        XCTAssertEqual(resolution.targetPlaylist.id, availableTarget.id)
        XCTAssertEqual(resolution.tracks.map(\.id), [track.id])
    }

    func testRejectsCrossSourceTrackStrictly() async throws {
        let target = makePlaylist(id: "target", title: "Road Trip", sourceCompositeKey: "plex:account:server-a")
        let foreignTrack = makeTrack(
            id: "foreign",
            title: "Foreign Track",
            sourceCompositeKey: "plex:account:server-b:library"
        )

        await assertDropError(
            expected: .crossSource(itemTitle: foreignTrack.title, playlistTitle: target.title),
            references: [
                .init(kind: .track, id: foreignTrack.id, sourceKey: foreignTrack.sourceCompositeKey, title: foreignTrack.title)
            ],
            target: makeTarget(target),
            tracks: [foreignTrack],
            playlists: [target]
        )
    }

    func testRejectsUnknownTrackSource() async throws {
        let target = makePlaylist(id: "target", title: "Road Trip", sourceCompositeKey: "plex:account:server")

        await assertDropError(
            expected: .crossSource(itemTitle: "Unknown Source", playlistTitle: target.title),
            references: [
                .init(kind: .track, id: "unknown-source", sourceKey: nil, title: "Unknown Source")
            ],
            target: makeTarget(target),
            tracks: [],
            playlists: [target]
        )
    }

    func testRejectsSmartSourcePlaylistAndEmptyExpansions() async throws {
        let target = makePlaylist(id: "target", title: "Road Trip")
        let sourcePlaylist = makePlaylist(id: "source", title: "Source", isSmart: true)
        let album = makeAlbum(id: "album", title: "Empty Album")

        await assertDropError(
            expected: .smartSource(title: sourcePlaylist.title),
            references: [
                .init(
                    kind: .playlist,
                    id: sourcePlaylist.id,
                    sourceKey: sourcePlaylist.sourceCompositeKey,
                    title: sourcePlaylist.title,
                    isSmartPlaylist: true
                )
            ],
            target: makeTarget(target),
            playlists: [target, sourcePlaylist]
        )

        await assertDropError(
            expected: .unresolvedItem(title: album.title),
            references: [
                .init(kind: .album, id: album.id, sourceKey: album.sourceCompositeKey, title: album.title)
            ],
            target: makeTarget(target),
            albums: [album],
            playlists: [target]
        )
    }

    private func assertDropError(
        expected: PlaylistDropResolutionError,
        references: [MediaDropItemReference] = [
            .init(kind: .track, id: "track", sourceKey: "plex:account:server:library", title: "Track")
        ],
        target: PlaylistDropTargetReference,
        tracks: [Track] = [],
        albums: [Album] = [],
        playlists: [Playlist],
        loadPlaylistTracks: @escaping (Playlist) async -> [Track] = { _ in [] },
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await resolver.resolve(
                references: references,
                target: target,
                tracks: tracks,
                albums: albums,
                playlists: playlists,
                loadAlbumTracks: { _ in [] },
                loadPlaylistTracks: loadPlaylistTracks
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as PlaylistDropResolutionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func makeTrack(
        id: String,
        title: String? = nil,
        sourceCompositeKey: String? = "plex:account:server:library"
    ) -> Track {
        Track(
            id: id,
            key: "/library/metadata/\(id)",
            title: title ?? "Track \(id)",
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeAlbum(
        id: String,
        title: String? = nil,
        sourceCompositeKey: String? = "plex:account:server:library"
    ) -> Album {
        Album(
            id: id,
            key: "/library/metadata/\(id)",
            title: title ?? "Album \(id)",
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makePlaylist(
        id: String,
        title: String,
        isSmart: Bool = false,
        sourceCompositeKey: String? = "plex:account:server"
    ) -> Playlist {
        Playlist(
            id: id,
            key: "/playlists/\(id)",
            title: title,
            isSmart: isSmart,
            sourceCompositeKey: sourceCompositeKey
        )
    }

    private func makeTarget(_ playlist: Playlist) -> PlaylistDropTargetReference {
        PlaylistDropTargetReference(
            id: playlist.id,
            sourceKey: playlist.sourceCompositeKey,
            title: playlist.title,
            isSmart: playlist.isSmart,
            isMerged: false
        )
    }
}
