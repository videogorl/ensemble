import XCTest
import EnsemblePersistence
@testable import EnsembleCore

/// The writer's deletion and cursor contract, on an on-disk store: in-memory stores
/// do not enforce uniqueness constraints across contexts.
final class LibraryWriterTests: XCTestCase {
    private let sourceA = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1")
    private let sourceB = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "2")
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private struct Fixture {
        let writer: LibraryWriter
        let repository: LibraryRepository
        let cursors: SyncCursorRepository
        let pending: PendingMutationRepository
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let repository = LibraryRepository(coreDataStack: stack)
        let cursors = SyncCursorRepository(coreDataStack: stack)
        let pending = PendingMutationRepository(coreDataStack: stack)
        return Fixture(
            writer: LibraryWriter(libraryRepository: repository, syncCursorRepository: cursors, pendingMutationRepository: pending),
            repository: repository,
            cursors: cursors,
            pending: pending
        )
    }

    // MARK: - Inputs

    private func artist(_ id: String, name: String? = nil) -> ArtistUpsertInput {
        ArtistUpsertInput(
            ratingKey: id, key: "/artist/\(id)", name: name ?? "Artist \(id)", summary: nil,
            thumbPath: nil, artPath: nil, dateAdded: nil, dateModified: Date(timeIntervalSince1970: 100)
        )
    }

    private func album(_ id: String, artist: String, trackCount: Int? = nil) -> AlbumUpsertInput {
        AlbumUpsertInput(
            ratingKey: id, key: "/album/\(id)", title: "Album \(id)", artistName: nil, albumArtist: nil,
            artistRatingKey: artist, summary: nil, thumbPath: nil, artPath: nil, year: nil, trackCount: trackCount,
            dateAdded: nil, dateModified: Date(timeIntervalSince1970: 100), rating: 0
        )
    }

    private func track(_ id: String, album: String, title: String? = nil, rating: Int = 0) -> TrackUpsertInput {
        TrackUpsertInput(
            ratingKey: id, key: "/track/\(id)", title: title ?? "Track \(id)", artistName: nil, albumName: nil,
            albumRatingKey: album, trackNumber: 1, discNumber: 1, duration: 1_000, thumbPath: nil, streamKey: nil,
            dateAdded: nil, dateModified: Date(timeIntervalSince1970: 100), lastPlayed: nil, rating: rating, playCount: 0
        )
    }

    /// Artists a1 and a2; albums b1 (a1) and b2 (a2); tracks t1 and t2 on b1, t3 on b2.
    private func fullBatch(at date: Date, dropping: Set<String> = []) throws -> LibraryBatch {
        let artists = ["a1", "a2"].filter { !dropping.contains($0) }
        let albums = [("b1", "a1"), ("b2", "a2")].filter { !dropping.contains($0.0) }
        let tracks = [("t1", "b1"), ("t2", "b1"), ("t3", "b2")].filter { !dropping.contains($0.0) }
        return LibraryBatch(
            artists: artists.map { artist($0) },
            albums: albums.map { id, artistID in album(id, artist: artistID, trackCount: tracks.filter { $0.1 == id }.count) },
            tracks: tracks.map { track($0.0, album: $0.1) },
            genres: [GenreUpsertInput(ratingKey: "g1", key: "/genre/g1", title: "Rock"), GenreUpsertInput(ratingKey: "g2", key: "/genre/g2", title: "Jazz")],
            inventory: try LibraryInventory(
                artistIDs: artists, albumIDs: albums.map(\.0), tracks: tracks.map { ($0.0, $0.1) }, genreIDs: ["g1", "g2"]
            ),
            isFullMetadataPass: true,
            queryStartedAt: date
        )
    }

    private func stored(_ f: Fixture, _ source: MusicSourceIdentifier) async throws -> (artists: Set<String>, albums: Set<String>, tracks: Set<String>) {
        let key = source.compositeKey
        return (
            Set(try await f.repository.fetchArtistSyncMetadata(forSource: key).keys),
            Set(try await f.repository.fetchAlbumSyncMetadata(forSource: key).keys),
            Set(try await f.repository.fetchTrackSummaries(forSource: key).keys)
        )
    }

    private func cursor(_ f: Fixture, _ source: MusicSourceIdentifier) async throws -> SyncCursorRecord? {
        try await f.cursors.fetchCursor(scopeKey: source.compositeKey, scopeType: .library)
    }

    private let everything = (artists: Set(["a1", "a2"]), albums: Set(["b1", "b2"]), tracks: Set(["t1", "t2", "t3"]))

    // MARK: - Deletion decisions

    func testInventoryDeletesOnlyWhatIsMissingAndOnlyFromItsOwnSource() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        try await f.writer.apply(fullBatch(at: t0), to: sourceB)

        let result = try await f.writer.apply(fullBatch(at: t0 + 10, dropping: ["t3", "b2", "a2"]), to: sourceA)

        let a = try await stored(f, sourceA)
        XCTAssertEqual(a.artists, ["a1"])
        XCTAssertEqual(a.albums, ["b1"])
        XCTAssertEqual(a.tracks, ["t1", "t2"])
        let b = try await stored(f, sourceB)
        XCTAssertEqual(b.artists, everything.artists)
        XCTAssertEqual(b.albums, everything.albums)
        XCTAssertEqual(b.tracks, everything.tracks)
        XCTAssertEqual(result.removedTrackRatingKeys, ["t3"])
        XCTAssertEqual([result.removedArtists, result.removedAlbums, result.removedTracks], [1, 1, 1])
    }

    /// An inventory that omits an artist an album still references (inventory-only albums carry no
    /// parent, so the initializer cannot catch it) must not cascade-delete that artist's listed rows.
    func testAnArtistAStoredAlbumStillReferencesIsNeverDeleted() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)

        let result = try await f.writer.apply(LibraryBatch(
            inventory: try LibraryInventory(
                artistIDs: ["a2"], albumIDs: ["b1", "b2"], tracks: [("t1", "b1"), ("t2", "b1"), ("t3", "b2")]
            ),
            queryStartedAt: t0 + 10
        ), to: sourceA)

        let a = try await stored(f, sourceA)
        XCTAssertEqual(a.artists, everything.artists, "a1 is still the parent of listed album b1")
        XCTAssertEqual(a.albums, everything.albums)
        XCTAssertEqual(a.tracks, everything.tracks)
        XCTAssertEqual([result.removedArtists, result.removedAlbums, result.removedTracks], [0, 0, 0])
    }

    /// Rows a response did not list must survive unless a complete inventory says they are gone.
    func testNothingIsDeletedWithoutACompleteNonEmptyInventory() async throws {
        let cases: [(name: String, batch: LibraryBatch)] = [
            ("delta with fewer rows than stored", LibraryBatch(tracks: [track("t1", album: "b1")], queryStartedAt: t0 + 10)),
            ("empty delta", LibraryBatch(queryStartedAt: t0 + 10)),
            ("complete but empty inventory", LibraryBatch(
                genres: [], inventory: try LibraryInventory(artistIDs: [], albumIDs: [], tracks: [], genreIDs: []),
                isFullMetadataPass: true, queryStartedAt: t0 + 10
            )),
            ("inventory without tracks", LibraryBatch(
                inventory: try LibraryInventory(artistIDs: ["a1", "a2"], albumIDs: ["b1", "b2"], tracks: []),
                queryStartedAt: t0 + 10
            )),
            ("inventory without artists", LibraryBatch(
                inventory: try LibraryInventory(artistIDs: [], albumIDs: ["b1", "b2"], tracks: [("t1", "b1")]),
                queryStartedAt: t0 + 10
            )),
        ]
        for testCase in cases {
            let f = try makeFixture()
            try await f.writer.apply(fullBatch(at: t0), to: sourceA)

            let result = try await f.writer.apply(testCase.batch, to: sourceA)

            let a = try await stored(f, sourceA)
            XCTAssertEqual(a.artists, everything.artists, testCase.name)
            XCTAssertEqual(a.albums, everything.albums, testCase.name)
            XCTAssertEqual(a.tracks, everything.tracks, testCase.name)
            XCTAssertEqual([result.removedArtists, result.removedAlbums, result.removedTracks], [0, 0, 0], testCase.name)
            // The refused inventory stays due: the full-metadata date did not advance.
            let record = try await cursor(f, sourceA)
            XCTAssertEqual(record?.lastFullSyncAt, self.t0, testCase.name)
        }
    }

    func testAStaleBatchArrivingAfterANewerOneChangesNothing() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        try await f.writer.apply(fullBatch(at: t0 + 100, dropping: ["t3", "b2", "a2"]), to: sourceA)

        // Started before the newer pass but arrived after it: its inventory would resurrect
        // t3 and, with other IDs, could delete rows the newer pass added.
        let stale = try await f.writer.apply(fullBatch(at: t0 + 50), to: sourceA)
        let staleDeleting = try await f.writer.apply(fullBatch(at: t0 + 60, dropping: ["t1", "t2"]), to: sourceA)

        let a = try await stored(f, sourceA)
        XCTAssertEqual(a.tracks, ["t1", "t2"])
        XCTAssertEqual(a.albums, ["b1"])
        XCTAssertFalse(stale.hasMaterialChanges)
        XCTAssertFalse(staleDeleting.hasMaterialChanges)
        let record = try await cursor(f, sourceA)
        XCTAssertEqual(record?.lastFullSyncAt, self.t0 + 100)
    }

    func testACursorDatedInTheFutureDoesNotMakeEveryBatchStale() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: Date().addingTimeInterval(86_400 * 365)), to: sourceA)

        // The clock went backwards after that pass: a batch from "now" is current, not stale.
        let result = try await f.writer.apply(fullBatch(at: Date(), dropping: ["t3", "b2", "a2"]), to: sourceA)

        XCTAssertEqual(result.removedTracks, 1)
    }

    func testAnInventoryThatFailsValidationIsRefusedBeforeAnyWrite() throws {
        let cases: [(name: String, build: () throws -> LibraryInventory)] = [
            ("blank artist ID", { try LibraryInventory(artistIDs: [" "], albumIDs: ["b1"], tracks: [("t1", "b1")]) }),
            ("blank album ID", { try LibraryInventory(artistIDs: ["a1"], albumIDs: [""], tracks: []) }),
            ("repeated album ID", { try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1", "b1"], tracks: []) }),
            ("blank track ID", { try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1"], tracks: [("", "b1")]) }),
            ("repeated track ID", { try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1"], tracks: [("t1", "b1"), ("t1", "b1")]) }),
            ("track whose album is missing", { try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1"], tracks: [("t1", "b9")]) }),
            ("track without an album", { try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1"], tracks: [("t1", nil)]) }),
        ]
        for testCase in cases {
            XCTAssertThrowsError(try testCase.build(), testCase.name) { error in
                guard case LibraryWriterError.invalidInventory = error else { return XCTFail("\(testCase.name): \(error)") }
            }
        }
        // Counts include albums with no tracks.
        XCTAssertEqual(
            try LibraryInventory(artistIDs: [], albumIDs: ["b1", "b2"], tracks: [("t1", "b1")]).trackCounts,
            ["b1": 1, "b2": 0]
        )
    }

    func testGenresAreDeletedOnlyFromANonEmptyGenreInventory() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        var emptyGenres = try fullBatch(at: t0 + 10)
        emptyGenres.genres = []
        emptyGenres.inventory = try LibraryInventory(
            artistIDs: ["a1", "a2"], albumIDs: ["b1", "b2"], tracks: [("t1", "b1"), ("t2", "b1"), ("t3", "b2")], genreIDs: []
        )
        try await f.writer.apply(emptyGenres, to: sourceA)
        let kept = try await f.repository.fetchGenres().count
        XCTAssertEqual(kept, 2)

        var oneGenre = try fullBatch(at: t0 + 20)
        oneGenre.genres = [GenreUpsertInput(ratingKey: "g1", key: "/genre/g1", title: "Rock")]
        oneGenre.inventory = try LibraryInventory(
            artistIDs: ["a1", "a2"], albumIDs: ["b1", "b2"], tracks: [("t1", "b1"), ("t2", "b1"), ("t3", "b2")], genreIDs: ["g1"]
        )
        let result = try await f.writer.apply(oneGenre, to: sourceA)
        let remaining = try await f.repository.fetchGenres().map(\.title)
        XCTAssertEqual(remaining, ["Rock"])
        XCTAssertEqual(result.removedGenres, 1)
    }

    // MARK: - Rows

    func testUnchangedRowsAreNotRewritten() async throws {
        let f = try makeFixture()
        let first = try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        XCTAssertEqual([first.changedArtists, first.changedAlbums, first.changedTracks], [2, 2, 3])

        let unchanged = try await f.writer.apply(fullBatch(at: t0 + 10), to: sourceA)
        XCTAssertEqual([unchanged.changedArtists, unchanged.changedAlbums, unchanged.changedTracks], [0, 0, 0])

        var edited = try fullBatch(at: t0 + 20)
        edited.tracks[1] = track("t2", album: "b1", title: "Renamed")
        edited.artists[0] = artist("a1", name: "Renamed")
        let changed = try await f.writer.apply(edited, to: sourceA)
        XCTAssertEqual([changed.changedArtists, changed.changedAlbums, changed.changedTracks], [1, 0, 1])
        let titles = try await f.repository.fetchTrackSyncMetadata(forSource: sourceA.compositeKey).mapValues(\.title)
        XCTAssertEqual(titles["t2"], "Renamed")
    }

    func testAlbumCountsComeFromTheInventoryIncludingZero() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        // b2 keeps its album but loses its only track.
        var batch = try fullBatch(at: t0 + 10, dropping: ["t3"])
        batch.albums = [album("b1", artist: "a1", trackCount: 2), album("b2", artist: "a2", trackCount: 0)]
        batch.inventory = try LibraryInventory(
            artistIDs: ["a1", "a2"], albumIDs: ["b1", "b2"], tracks: [("t1", "b1"), ("t2", "b1")], genreIDs: ["g1", "g2"]
        )
        try await f.writer.apply(batch, to: sourceA)

        let counts = try await f.repository.fetchAlbumSyncMetadata(forSource: sourceA.compositeKey).mapValues(\.trackCount)
        XCTAssertEqual(counts, ["b1": 2, "b2": 0])
    }

    // MARK: - Cursors

    func testCursorsRecordQueryStartAndAdvanceByPassKind() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        var record = try await cursor(f, sourceA)
        XCTAssertEqual([record?.lastFullSyncAt, record?.lastInventorySyncAt, record?.lastIncrementalSyncAt], [t0, t0, t0])

        var inventoryOnly = try fullBatch(at: t0 + 10)
        inventoryOnly.isFullMetadataPass = false
        try await f.writer.apply(inventoryOnly, to: sourceA)
        record = try await cursor(f, sourceA)
        XCTAssertEqual([record?.lastFullSyncAt, record?.lastInventorySyncAt, record?.lastIncrementalSyncAt], [t0, t0 + 10, t0 + 10])

        try await f.writer.apply(LibraryBatch(queryStartedAt: t0 + 20), to: sourceA)
        record = try await cursor(f, sourceA)
        XCTAssertEqual([record?.lastFullSyncAt, record?.lastInventorySyncAt, record?.lastIncrementalSyncAt], [t0, t0 + 10, t0 + 20])
    }

    func testADeltaThatAddsOrMovesATrackMarksTheInventoryDue() async throws {
        let cases: [(name: String, batch: LibraryBatch, marksDue: Bool)] = [
            ("new track", LibraryBatch(tracks: [track("t9", album: "b1")], queryStartedAt: t0 + 10), true),
            ("track moved to another album", LibraryBatch(tracks: [track("t1", album: "b2")], queryStartedAt: t0 + 10), true),
            ("new album", LibraryBatch(albums: [album("b9", artist: "a1")], queryStartedAt: t0 + 10), true),
            ("retitled track", LibraryBatch(tracks: [track("t1", album: "b1", title: "New")], queryStartedAt: t0 + 10), false),
        ]
        for testCase in cases {
            let f = try makeFixture()
            try await f.writer.apply(fullBatch(at: t0), to: sourceA)
            try await f.writer.applyChanges(testCase.batch, to: sourceA)
            let record = try await cursor(f, sourceA)
            XCTAssertEqual(record?.lastInventorySyncAt == nil, testCase.marksDue, testCase.name)
        }
    }

    func testALiveDeltaNeverDeletesAndMovesNoCursorButInvalidation() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        var delta = LibraryBatch(tracks: [track("t1", album: "b1", title: "New")], queryStartedAt: t0 + 10)
        delta.inventory = try LibraryInventory(artistIDs: ["a1"], albumIDs: ["b1"], tracks: [("t1", "b1")])

        let result = try await f.writer.applyChanges(delta, to: sourceA)

        let a = try await stored(f, sourceA)
        XCTAssertEqual(a.tracks, everything.tracks)
        XCTAssertEqual(result.removedTracks, 0)
        let record = try await cursor(f, sourceA)
        XCTAssertEqual(record?.lastIncrementalSyncAt, t0)
    }

    func testACancelledPassWritesNothingAndLeavesTheCursor() async throws {
        let f = try makeFixture()
        try await f.writer.apply(fullBatch(at: t0), to: sourceA)

        do {
            // A deadline already in the past cancels at the writer's first check.
            _ = try await RefreshExecution.$deadline.withValue(0) {
                try await f.writer.apply(self.fullBatch(at: self.t0 + 10, dropping: ["t3", "b2", "a2"]), to: self.sourceA)
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        let a = try await stored(f, sourceA)
        XCTAssertEqual(a.tracks, everything.tracks)
        let record = try await cursor(f, sourceA)
        XCTAssertEqual([record?.lastFullSyncAt, record?.lastIncrementalSyncAt], [t0, t0])
    }

    func testPlanDueDatesFollowTheCursor() async throws {
        let f = try makeFixture()
        let fresh = try await f.writer.libraryPlan(for: sourceA, since: t0, now: t0)
        XCTAssertTrue(fresh.inventoryDue && fresh.fullMetadataDue, "no cursor means both are due")

        try await f.writer.apply(fullBatch(at: t0), to: sourceA)
        let soon = try await f.writer.libraryPlan(for: sourceA, since: t0, now: t0 + 3_600)
        XCTAssertFalse(soon.inventoryDue || soon.fullMetadataDue)
        XCTAssertEqual(Set(soon.stored.tracks.keys), everything.tracks)
        XCTAssertEqual(soon.stored.tracks["t1"]?.albumRatingKey, "b1")
        let nextDay = try await f.writer.libraryPlan(for: sourceA, since: t0, now: t0 + 86_400)
        XCTAssertTrue(nextDay.inventoryDue && nextDay.fullMetadataDue)
        let clockBehind = try await f.writer.libraryPlan(for: sourceA, since: t0, now: t0 - 100)
        XCTAssertTrue(clockBehind.fullMetadataDue, "a cursor in the future is due")
        let full = try await f.writer.libraryPlan(for: sourceA, since: nil, now: t0 + 3_600)
        XCTAssertTrue(full.inventoryDue && full.fullMetadataDue && full.since == nil)
    }

    /// A favourite whose upload is still queued is newer than the server's rating; sync must not undo it.
    func testASyncDoesNotReplaceARatingWhoseUploadIsStillQueued() async throws {
        let f = try makeFixture()
        let rated = LibraryBatch(
            albums: [album("b1", artist: "a1")],
            tracks: [track("t1", album: "b1", rating: 10), track("t2", album: "b1", rating: 10)],
            queryStartedAt: t0
        )
        try await f.writer.apply(rated, to: sourceA)
        let payload = try JSONEncoder().encode(
            TrackRatingMutationPayload(trackRatingKey: "t1", sourceCompositeKey: sourceA.compositeKey, rating: 10)
        )
        try await f.pending.enqueueMutation(id: "m1", type: .trackRating, payload: payload, sourceCompositeKey: sourceA.compositeKey)

        // The server has not seen the favourite yet and reports 0 for both tracks.
        let server = LibraryBatch(
            tracks: [track("t1", album: "b1", rating: 0), track("t2", album: "b1", rating: 0)],
            queryStartedAt: t0 + 10
        )
        try await f.writer.apply(server, to: sourceA)

        var ratings = try await f.repository.fetchTrackSummaries(forSource: sourceA.compositeKey).mapValues(\.rating)
        XCTAssertEqual(ratings["t1"], 10, "queued favourite kept")
        XCTAssertEqual(ratings["t2"], 0, "no queued mutation, the server's value applies")

        try await f.pending.deleteMutation(id: "m1")
        try await f.writer.apply(LibraryBatch(tracks: server.tracks, queryStartedAt: t0 + 20), to: sourceA)
        ratings = try await f.repository.fetchTrackSummaries(forSource: sourceA.compositeKey).mapValues(\.rating)
        XCTAssertEqual(ratings["t1"], 0, "once uploaded the server's value applies")
    }

    /// A batch without names leaves a source row's names alone, for Plex and Apple Music alike.
    func testABatchWithoutNamesKeepsTheSourceRowsNames() async throws {
        let f = try makeFixture()
        for (source, names) in [(sourceA, ("Music", "tester")), (MusicSourceIdentifier.appleMusic, ("Apple Music", "This Device"))] {
            _ = try await f.repository.upsertMusicSource(
                compositeKey: source.compositeKey, type: source.type.rawValue, accountId: source.accountId,
                serverId: source.serverId, libraryId: source.libraryId, displayName: names.0, accountName: names.1
            )
            try await f.writer.apply(LibraryBatch(queryStartedAt: t0), to: source)
            let row = try await f.repository.fetchMusicSources().first { $0.compositeKey == source.compositeKey }
            XCTAssertEqual([row?.displayName, row?.accountName], [names.0, names.1], "\(source.type)")
        }
    }
}
