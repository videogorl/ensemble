import XCTest
import EnsemblePersistence
@testable import EnsembleCore

/// Apple Music library sync through the fetcher and `LibraryWriter`, with a fake MusicKit/REST source on an
/// on-disk store (in-memory stores do not enforce the uniqueness constraints sync relies on).
final class AppleMusicLibraryFetcherTests: XCTestCase {
    private let apple = MusicSourceIdentifier.appleMusic
    private let plex = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A source whose reads can fail or change between passes. `authorization` is consumed one answer per
    /// check; the last answer repeats.
    private final class FakeSource: AppleMusicLibrarySource, @unchecked Sendable {
        var songs: Result<AppleMusicSongList, Error>
        var native: Result<NativeLibraryMetadataSnapshot, Error>
        var authorization: [Bool] = [true]
        private(set) var songReads = 0

        init(songs: Result<AppleMusicSongList, Error>, native: Result<NativeLibraryMetadataSnapshot, Error>) {
            self.songs = songs
            self.native = native
        }

        func isAuthorized() async -> Bool { authorization.count > 1 ? authorization.removeFirst() : authorization[0] }
        func songs() async throws -> AppleMusicSongList {
            songReads += 1
            return try songs.get()
        }
        func nativeMetadata() async throws -> NativeLibraryMetadataSnapshot { try native.get() }
    }

    private struct Fixture {
        let writer: LibraryWriter
        let repository: LibraryRepository
        let cursors: SyncCursorRepository
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let repository = LibraryRepository(coreDataStack: stack)
        let cursors = SyncCursorRepository(coreDataStack: stack)
        return Fixture(
            writer: LibraryWriter(libraryRepository: repository, syncCursorRepository: cursors),
            repository: repository,
            cursors: cursors
        )
    }

    // MARK: - Inputs

    /// s1 and s2 on album A by artist X, s3 on album B by artist Y.
    private let allSongs = ["s1": "A", "s2": "A", "s3": "B"]

    private func song(_ id: String, album: String) throws -> LibrarySong {
        let json = #"""
        {"id": "\#(id)", "attributes": {"name": "Song \#(id)", "artistName": "Artist \#(album)", "albumName": "Album \#(album)"},
         "relationships": {"albums": {"data": [{"id": "\#(album)"}]}, "artists": {"data": [{"id": "artist-\#(album)"}]}}}
        """#
        return try JSONDecoder().decode(LibrarySong.self, from: Data(json.utf8))
    }

    private func list(_ ids: [String], total: Int? = nil) throws -> AppleMusicSongList {
        AppleMusicSongList(songs: try ids.map { try song($0, album: allSongs[$0] ?? "A") }, reportedTotal: total ?? ids.count)
    }

    private func native(_ ids: [String], playCount: Int? = nil) -> NativeLibraryMetadataSnapshot {
        NativeLibraryMetadataSnapshot(
            songs: ids.map { NativeLibrarySongMetadata(itemID: $0, dateAdded: nil, lastPlayed: nil, playCount: playCount) },
            albums: [], artists: [], elapsedMilliseconds: 0
        )
    }

    private func source(_ ids: [String], total: Int? = nil) throws -> FakeSource {
        FakeSource(songs: .success(try list(ids, total: total)), native: .success(native(ids)))
    }

    /// One writer pass for `identifier` as the coordinator runs it: plan, fetch, apply.
    @discardableResult
    private func pass(
        _ f: Fixture, _ fake: FakeSource, at date: Date, since: Date? = nil, plan now: Date? = nil
    ) async throws -> LibrarySyncResult {
        let plan = try await f.writer.libraryPlan(for: apple, since: since, now: now ?? date)
        let fetch = try await AppleMusicLibraryFetcher(source: fake).fetch(plan: plan, pendingFavoriteCatalogIDs: [], now: date)
        return try await f.writer.apply(fetch.batch, to: apple)
    }

    private func storedTracks(_ f: Fixture, _ identifier: MusicSourceIdentifier) async throws -> Set<String> {
        Set(try await f.repository.fetchTrackSummaries(forSource: identifier.compositeKey).keys)
    }

    private func inventoryDate(_ f: Fixture) async throws -> Date? {
        try await f.cursors.fetchCursor(scopeKey: apple.compositeKey, scopeType: .library)?.lastInventorySyncAt
    }

    // MARK: - Deletion

    func testACompleteInventoryDeletesOnlyWhatTheLibraryNoLongerHolds() async throws {
        let f = try makeFixture()
        try await pass(f, try source(["s1", "s2", "s3"]), at: t0)
        let storedAlbums = try await f.repository.fetchAlbumSyncMetadata(forSource: apple.compositeKey).keys
        XCTAssertEqual(Set(storedAlbums), ["apple-album:A", "apple-album:B"])

        let result = try await pass(f, try source(["s1", "s2"]), at: t0 + 10)

        let tracks = try await storedTracks(f, apple)
        XCTAssertEqual(tracks, ["s1", "s2"])
        XCTAssertEqual(result.removedTrackRatingKeys, ["s3"])
        let albums = try await f.repository.fetchAlbumSyncMetadata(forSource: apple.compositeKey).keys
        XCTAssertEqual(Set(albums), ["apple-album:A"])
    }

    /// Anything short of a proven-complete read must leave every stored row and the inventory date alone.
    func testNothingIsDeletedUnlessTheReadIsProvedComplete() async throws {
        enum Failure: Error { case page }
        let revokedMidFetch = try source(["s1", "s2"])
        revokedMidFetch.authorization = [true, false]
        let revokedBefore = try source(["s1", "s2"])
        revokedBefore.authorization = [false]
        let cases: [(name: String, source: FakeSource, throwsOnFetch: Bool)] = [
            // Written as a delta: the rows are valid, only the claim of completeness is withheld.
            ("MusicKit lists a song the list lacks (list ended early)",
             FakeSource(songs: .success(try list(["s1", "s2"])), native: .success(native(["s1", "s2", "s3"]))), false),
            ("API total larger than the songs received", try source(["s1", "s2"], total: 3), false),
            ("a page failed", FakeSource(songs: .failure(Failure.page), native: .success(native([]))), true),
            ("request cancelled", FakeSource(songs: .failure(CancellationError()), native: .success(native([]))), true),
            ("MusicKit read failed", FakeSource(songs: .success(try list(["s1", "s2"])), native: .failure(Failure.page)), true),
            ("authorization revoked mid-fetch", revokedMidFetch, true),
            ("authorization revoked before the fetch", revokedBefore, true),
        ]
        for (index, testCase) in cases.enumerated() {
            let f = try makeFixture()
            try await pass(f, try source(["s1", "s2", "s3"]), at: t0)
            let before = try await inventoryDate(f)

            do {
                try await pass(f, testCase.source, at: t0 + 10 + TimeInterval(index))
                XCTAssertFalse(testCase.throwsOnFetch, "\(testCase.name): expected the pass to fail")
            } catch {
                XCTAssertTrue(testCase.throwsOnFetch, "\(testCase.name): unexpected \(error)")
            }

            let tracks = try await storedTracks(f, apple)
            XCTAssertEqual(tracks, ["s1", "s2", "s3"], testCase.name)
            let after = try await inventoryDate(f)
            XCTAssertEqual(after, before, "\(testCase.name): the inventory stays due")
        }
    }

    func testAnEmptyLibraryDeletesNothing() async throws {
        let f = try makeFixture()
        try await pass(f, try source(["s1", "s2", "s3"]), at: t0)

        let result = try await pass(f, try source([]), at: t0 + 10)

        let tracks = try await storedTracks(f, apple)
        XCTAssertEqual(tracks, ["s1", "s2", "s3"])
        XCTAssertEqual(result.removedTracks + result.removedAlbums + result.removedArtists, 0)
    }

    func testAnApplePassAndAPlexPassNeverTouchEachOthersRows() async throws {
        let f = try makeFixture()
        // Plex holds tracks with the same rating keys.
        let plexBatch = LibraryBatch(
            artists: [ArtistUpsertInput(ratingKey: "p1", key: "/a", name: "P", summary: nil, thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: nil)],
            albums: [AlbumUpsertInput(ratingKey: "pa", key: "/b", title: "PA", artistName: nil, albumArtist: nil, artistRatingKey: "p1", summary: nil, thumbPath: nil, artPath: nil, year: nil, trackCount: 2, dateAdded: nil, dateModified: nil, rating: nil)],
            tracks: ["s1", "s2"].map {
                TrackUpsertInput(ratingKey: $0, key: "/t/\($0)", title: $0, artistName: nil, albumName: nil, albumRatingKey: "pa", trackNumber: nil, discNumber: nil, duration: nil, thumbPath: nil, streamKey: nil, dateAdded: nil, dateModified: nil, lastPlayed: nil, rating: nil, playCount: nil)
            },
            inventory: try LibraryInventory(artistIDs: ["p1"], albumIDs: ["pa"], tracks: [("s1", "pa"), ("s2", "pa")]),
            queryStartedAt: t0
        )
        try await f.writer.apply(plexBatch, to: plex)
        try await pass(f, try source(["s1", "s2", "s3"]), at: t0)

        // An Apple pass that drops everything it can leaves Plex's rows.
        try await pass(f, try source(["s1"]), at: t0 + 10)
        let plexTracks = try await storedTracks(f, plex)
        XCTAssertEqual(plexTracks, ["s1", "s2"])
        let appleTracks = try await storedTracks(f, apple)
        XCTAssertEqual(appleTracks, ["s1"])

        // And a Plex pass that deletes a track leaves Apple's.
        try await f.writer.apply(LibraryBatch(
            artists: plexBatch.artists, albums: plexBatch.albums, tracks: [plexBatch.tracks[0]],
            inventory: try LibraryInventory(artistIDs: ["p1"], albumIDs: ["pa"], tracks: [("s1", "pa")]),
            queryStartedAt: t0 + 20
        ), to: plex)
        let plexAfter = try await storedTracks(f, plex)
        XCTAssertEqual(plexAfter, ["s1"])
        let appleAfter = try await storedTracks(f, apple)
        XCTAssertEqual(appleAfter, ["s1"])
        let appleAlbums = try await f.repository.fetchAlbumSyncMetadata(forSource: apple.compositeKey).keys
        XCTAssertEqual(Set(appleAlbums), ["apple-album:A"])
    }

    // MARK: - Writes

    func testAnUnchangedLibraryWritesNothing() async throws {
        let f = try makeFixture()
        let first = try await pass(f, try source(["s1", "s2", "s3"]), at: t0)
        XCTAssertEqual([first.changedArtists, first.changedAlbums, first.changedTracks], [2, 2, 3])

        let second = try await pass(f, try source(["s1", "s2", "s3"]), at: t0 + 10)

        XCTAssertEqual([second.changedArtists, second.changedAlbums, second.changedTracks], [0, 0, 0])
        let sources = try await f.repository.fetchMusicSources()
        let row = try XCTUnwrap(sources.first { $0.compositeKey == apple.compositeKey })
        XCTAssertEqual([row.displayName, row.accountName], ["Apple Music", "This Device"])
    }

    func testAPassNotDueForAnInventoryReadsNothing() async throws {
        let f = try makeFixture()
        let fake = try source(["s1", "s2", "s3"])
        try await pass(f, fake, at: t0)
        XCTAssertEqual(fake.songReads, 1)

        let recent = try await pass(f, fake, at: t0 + 3_600, since: t0 - 5)
        XCTAssertEqual(fake.songReads, 1, "the inventory is under a day old")
        XCTAssertEqual(recent.changedTracks, 0)
        let sources = try await f.repository.fetchMusicSources()
        let row = try XCTUnwrap(sources.first { $0.compositeKey == apple.compositeKey })
        XCTAssertEqual([row.displayName, row.accountName], ["Apple Music", "This Device"], "a pass that reads nothing keeps the names")

        try await pass(f, fake, at: t0 + 86_400, since: t0 - 5)
        XCTAssertEqual(fake.songReads, 2, "a day later the inventory is due again")
    }

    func testStoredPlayHistoryIsKeptWhenMusicKitHasNoneForASong() async throws {
        let f = try makeFixture()
        let withHistory = FakeSource(songs: .success(try list(["s1"])), native: .success(native(["s1"], playCount: 12)))
        try await pass(f, withHistory, at: t0)

        let withoutHistory = FakeSource(songs: .success(try list(["s1"])), native: .success(native([])))
        try await pass(f, withoutHistory, at: t0 + 10)

        let stored = try await f.repository.fetchTrackSyncMetadata(forSource: apple.compositeKey)
        XCTAssertEqual(stored["s1"]?.playCount, 12)
    }
}
