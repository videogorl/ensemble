import XCTest
import EnsemblePersistence
@testable import EnsembleCore

/// The writer's playlist deletion and body contract, on an on-disk store: in-memory stores do not
/// enforce the membership uniqueness constraint across contexts.
final class LibraryWriterPlaylistTests: XCTestCase {
    /// Plex playlists belong to the server, so the scope is a server key.
    private let scope = "plex:acct:srv"
    private let otherScope = "plex:acct:other"
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private struct Fixture {
        let writer: LibraryWriter
        let playlists: PlaylistRepository
        let cursors: SyncCursorRepository
        let pending: PendingMutationRepository
        let targets: OfflineDownloadTargetRepository
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let stack = CoreDataStack.onDisk(at: directory.appendingPathComponent("Ensemble.sqlite"))
        let playlists = PlaylistRepository(coreDataStack: stack)
        let cursors = SyncCursorRepository(coreDataStack: stack)
        let pending = PendingMutationRepository(coreDataStack: stack)
        return Fixture(
            writer: LibraryWriter(
                libraryRepository: LibraryRepository(coreDataStack: stack), playlistRepository: playlists,
                syncCursorRepository: cursors, pendingMutationRepository: pending
            ),
            playlists: playlists, cursors: cursors, pending: pending,
            targets: OfflineDownloadTargetRepository(coreDataStack: stack)
        )
    }

    // MARK: - Inputs

    private func header(_ id: String, at seconds: TimeInterval? = 100, count: Int? = 0, title: String? = nil) -> PlaylistUpsertInput {
        PlaylistUpsertInput(
            ratingKey: id, key: "/playlists/\(id)", title: title ?? "Playlist \(id)", summary: nil, compositePath: nil, isSmart: false,
            duration: 0, trackCount: count, dateAdded: nil, dateModified: seconds.map { Date(timeIntervalSince1970: $0) }, lastPlayed: nil
        )
    }

    private func tracks(_ ids: String...) -> [PlaylistTrackSnapshot] {
        ids.enumerated().map { PlaylistTrackSnapshot(ratingKey: $1, playlistItemID: "item-\($0)", title: "Track \($1)") }
    }

    /// A read of the whole list: the given playlists, with bodies for those named, and an inventory when `complete`.
    private func list(
        _ ids: [String], bodies: [String: [PlaylistTrackSnapshot]] = [:], complete: Bool = true, at date: Date, modified: TimeInterval = 100
    ) throws -> PlaylistBatch {
        PlaylistBatch(
            entries: ids.map { PlaylistEntry(header: header($0, at: modified, count: bodies[$0]?.count ?? 0), body: bodies[$0]) },
            inventory: complete ? try PlaylistInventory(playlistIDs: ids) : nil,
            readsFullList: true,
            queryStartedAt: date
        )
    }

    private func storedIDs(_ f: Fixture, _ scope: String) async throws -> Set<String> {
        Set(try await f.playlists.fetchPlaylistSyncStates(forSource: scope).keys)
    }

    private func body(_ f: Fixture, _ id: String, scope: String? = nil) async throws -> [String] {
        let playlist = try await f.playlists.fetchPlaylist(ratingKey: id, sourceCompositeKey: scope ?? self.scope)
        return (playlist?.playlistItemsArray ?? []).compactMap(\.trackRatingKey)
    }

    private func cursor(_ f: Fixture) async throws -> SyncCursorRecord? {
        try await f.cursors.fetchCursor(scopeKey: scope, scopeType: .serverPlaylists)
    }

    // MARK: - Deletion decisions

    func testACompleteListDeletesOnlyMissingPlaylistsAndOnlyFromItsOwnScope() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2", "p3"], at: t0), for: scope)
        try await f.writer.apply(list(["p1", "p2", "p3"], at: t0), for: otherScope)

        let result = try await f.writer.apply(list(["p1", "p3"], at: t0 + 10), for: scope)

        let mine = try await storedIDs(f, scope)
        XCTAssertEqual(mine, ["p1", "p3"])
        let theirs = try await storedIDs(f, otherScope)
        XCTAssertEqual(theirs, ["p1", "p2", "p3"])
        XCTAssertEqual(result.removedPlaylists, 1)
    }

    /// A playlist a response did not list must survive unless a complete, non-empty inventory says it is gone.
    func testNothingIsDeletedWithoutACompleteNonEmptyInventory() async throws {
        let cases: [(name: String, batch: PlaylistBatch)] = [
            ("unproven list with fewer playlists", try list(["p1"], complete: false, at: t0 + 10)),
            ("complete but empty list", try list([], complete: true, at: t0 + 10)),
            ("empty unproven list", try list([], complete: false, at: t0 + 10)),
            ("targeted read of one playlist", PlaylistBatch(entries: [PlaylistEntry(header: header("p1"))], queryStartedAt: t0 + 10)),
        ]
        for testCase in cases {
            let f = try makeFixture()
            try await f.writer.apply(list(["p1", "p2"], at: t0), for: scope)

            let result = try await f.writer.apply(testCase.batch, for: scope)

            let ids = try await storedIDs(f, scope)
            XCTAssertEqual(ids, ["p1", "p2"], testCase.name)
            XCTAssertEqual(result.removedPlaylists, 0, testCase.name)
        }
    }

    func testAnInventoryNeedsUniqueNonBlankIDs() {
        for ids in [["p1", "p1"], ["p1", " "], [""]] {
            XCTAssertThrowsError(try PlaylistInventory(playlistIDs: ids), "\(ids)")
        }
        XCTAssertNoThrow(try PlaylistInventory(playlistIDs: []))
    }

    func testACancelledPassWritesNothingAndLeavesTheCursor() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a")], at: t0), for: scope)

        do {
            // A deadline already in the past cancels at the writer's first check.
            _ = try await RefreshExecution.$deadline.withValue(0) {
                try await f.writer.apply(self.list(["p1"], bodies: ["p1": self.tracks("a", "b")], at: self.t0 + 10, modified: 200), for: self.scope)
            }
            XCTFail("expected cancellation")
        } catch is CancellationError {}

        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, ["p1", "p2"])
        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a"])
        let record = try await cursor(f)
        XCTAssertEqual(record?.lastInventorySyncAt, t0)
    }

    // MARK: - Bodies

    func testACompleteEmptyBodyEmptiesThePlaylistAndAnUnprovenBodyLeavesIt() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a", "b"), "p2": tracks("c")], at: t0), for: scope)

        // Both playlists changed on the server (date 200). p1's body was read and is empty; p2's was not read.
        let batch = PlaylistBatch(
            entries: [
                PlaylistEntry(header: header("p1", at: 200, count: 0), body: []),
                PlaylistEntry(header: header("p2", at: 200, count: 1), body: nil),
            ],
            inventory: try PlaylistInventory(playlistIDs: ["p1", "p2"]), readsFullList: true, queryStartedAt: t0 + 10
        )
        try await f.writer.apply(batch, for: scope)

        let emptied = try await body(f, "p1")
        XCTAssertEqual(emptied, [])
        let kept = try await body(f, "p2")
        XCTAssertEqual(kept, ["c"])
        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.dateModified, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(states["p2"]?.dateModified, Date(timeIntervalSince1970: 100), "the date stays until its body is committed, so the next pass reads it again")
        let needed = try await f.writer.playlistsNeedingBodies([header("p1", at: 200, count: 0), header("p2", at: 200, count: 1)], for: scope)
        XCTAssertEqual(needed.map(\.ratingKey), ["p2"])
    }

    func testABodyWithABlankTrackIDIsNotProofAndKeepsTheStoredBody() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", "b")], at: t0), for: scope)

        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", " ")], at: t0 + 10, modified: 200), for: scope)

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "b"])
    }

    func testRepeatedTracksAndOrderArePreserved() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", "b", "a", "c", "a")], at: t0), for: scope)
        let first = try await body(f, "p1")
        XCTAssertEqual(first, ["a", "b", "a", "c", "a"])

        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("c", "a", "a")], at: t0 + 10, modified: 200), for: scope)
        let second = try await body(f, "p1")
        XCTAssertEqual(second, ["c", "a", "a"])
    }

    /// Issue #98: a smart playlist's header counts 1,595 tracks while its complete body holds 3,460.
    func testAnUnchangedPlaylistWhoseHeaderCountDisagreesWithItsBodyIsNotReadAgain() async throws {
        let f = try makeFixture()
        let ids = (0..<30).map { "t\($0)" }
        let body = ids.enumerated().map { PlaylistTrackSnapshot(ratingKey: $1, playlistItemID: "i\($0)") }
        try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("smart", at: 100, count: 10), body: body)],
            inventory: try PlaylistInventory(playlistIDs: ["smart"]), readsFullList: true, queryStartedAt: t0
        ), for: scope)

        let needed = try await f.writer.playlistsNeedingBodies([header("smart", at: 100, count: 10)], for: scope)

        XCTAssertTrue(needed.isEmpty)
    }

    func testWhichPlaylistsNeedABody() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["full", "empty", "undated"], bodies: ["full": tracks("a"), "empty": []], at: t0), for: scope)
        try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("undated", at: nil, count: 1), body: tracks("a"))], queryStartedAt: t0 + 5
        ), for: scope)
        // A header with tracks but no stored body, as when a body read once failed.
        try await f.playlists.upsertPlaylist(header("bodyless", at: 100, count: 3), sourceCompositeKey: scope)

        let cases: [(name: String, header: PlaylistUpsertInput, needed: Bool)] = [
            ("new playlist", header("new"), true),
            ("unchanged", header("full", at: 100, count: 1), false),
            ("date changed", header("full", at: 101, count: 1), true),
            ("date went missing", header("full", at: nil, count: 1), true),
            ("date appeared", header("undated", at: 100, count: 1), true),
            ("undated header: nothing says it is unchanged", header("undated", at: nil, count: 1), true),
            ("older than the stored one", header("full", at: 99, count: 1), false),
            ("legitimately empty", header("empty", at: 100, count: 0), false),
            ("no stored body under a non-empty header", header("bodyless", at: 100, count: 3), true),
        ]
        for testCase in cases {
            let needed = try await f.writer.playlistsNeedingBodies([testCase.header], for: scope)
            XCTAssertEqual(!needed.isEmpty, testCase.needed, testCase.name)
        }
    }

    func testAnOlderHeaderChangesNothing() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0, modified: 200), for: scope)

        try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("p1", at: 150, count: 2, title: "Old title"), body: tracks("a", "b"))], queryStartedAt: t0 + 10
        ), for: scope)

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a"])
        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.title, "Playlist p1")
    }

    // MARK: - Local edits and queued mutations

    func testALocalEditSurvivesAReadThatBeganBeforeIt() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let readBegan = Date().addingTimeInterval(-5)

        // The user adds b and a new playlist while an older read of the server is in flight.
        try await f.writer.applyLocalEdit(PlaylistEntry(header: header("p1", at: 100, count: 2), body: tracks("a", "b")), for: scope)
        try await f.writer.applyLocalEdit(PlaylistEntry(header: header("new", at: nil, count: 1), body: tracks("x")), for: scope)
        let result = try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("p1", at: 150, count: 1), body: tracks("a"))],
            inventory: try PlaylistInventory(playlistIDs: ["p1"]), readsFullList: true, queryStartedAt: readBegan
        ), for: scope)

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "b"], "the older read cannot undo the add")
        let created = try await body(f, "new")
        XCTAssertEqual(created, ["x"], "the older inventory cannot delete the new playlist")
        XCTAssertEqual(result.removedPlaylists, 0)

        // A read that began after the edit applies as usual.
        try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("p1", at: 150, count: 2), body: tracks("a", "b", "c"))],
            inventory: try PlaylistInventory(playlistIDs: ["p1"]), readsFullList: true, queryStartedAt: Date().addingTimeInterval(5)
        ), for: scope)
        let later = try await body(f, "p1")
        XCTAssertEqual(later, ["a", "b", "c"])
        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, ["p1"], "a complete inventory read after the edit does delete a playlist the server lacks")
    }

    func testAnOptimisticAddKeepsTheServersDateSoTheNextReadReplacesTheBody() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        try await f.writer.applyLocalEdit(PlaylistEntry(header: header("p1", at: 100, count: 2), body: tracks("a", "b")), for: scope)

        let needed = try await f.writer.playlistsNeedingBodies([header("p1", at: 101, count: 2)], for: scope)

        XCTAssertEqual(needed.map(\.ratingKey), ["p1"])
    }

    func testAQueuedRenameKeepsTheLocalTitleUntilItUploads() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], at: t0), for: scope)
        try await f.playlists.updatePlaylistTitle(ratingKey: "p1", sourceCompositeKey: scope, title: "Renamed", dateModified: Date(timeIntervalSince1970: 100))
        let payload = try JSONEncoder().encode(PlaylistRenameMutationPayload(playlistRatingKey: "p1", playlistSourceCompositeKey: scope, newTitle: "Renamed"))
        try await f.pending.enqueueMutation(id: "m1", type: .playlistRename, payload: payload, sourceCompositeKey: scope)

        try await f.writer.apply(list(["p1"], at: t0 + 10, modified: 100), for: scope)
        var states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.title, "Renamed")

        try await f.pending.deleteMutation(id: "m1")
        try await f.writer.apply(list(["p1"], at: t0 + 20, modified: 100), for: scope)
        states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.title, "Playlist p1", "once uploaded the server's title applies")
    }

    func testOfflineTargetsSurviveBodyRewritesAndDeletions() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
        let key = "offline:playlist:\(scope):*:p1"
        _ = try await f.targets.upsertTarget(key: key, kind: .playlist, ratingKey: "p1", sourceCompositeKey: scope, displayName: "Playlist p1")

        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", "c")], at: t0 + 10, modified: 200), for: scope)

        let target = try await f.targets.fetchTarget(key: key)
        XCTAssertNotNil(target)
        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, ["p1"])
    }

    // MARK: - Cursors

    func testTheCursorMovesOnlyForAFullListAndOnlyAnInventoryMovesItsInventoryDate() async throws {
        let f = try makeFixture()
        try await f.writer.apply(PlaylistBatch(entries: [PlaylistEntry(header: header("p1"))], queryStartedAt: t0), for: scope)
        let targeted = try await cursor(f)
        XCTAssertNil(targeted, "a targeted read moves no cursor")

        try await f.writer.apply(list(["p1"], complete: false, at: t0 + 10), for: scope)
        var record = try await cursor(f)
        XCTAssertEqual(record?.lastIncrementalSyncAt, t0 + 10)
        XCTAssertNil(record?.lastInventorySyncAt)

        try await f.writer.apply(list(["p1"], at: t0 + 20), for: scope)
        record = try await cursor(f)
        XCTAssertEqual(record?.lastInventorySyncAt, t0 + 20)
        let inventoryAt = try await f.writer.lastPlaylistInventoryAt(scope)
        XCTAssertEqual(inventoryAt, t0 + 20)

        try await f.writer.apply(list([], at: t0 + 30), for: scope)
        record = try await cursor(f)
        XCTAssertEqual(record?.lastInventorySyncAt, t0 + 20, "an empty inventory deletes nothing, so it is no inventory")

        try await f.writer.removePlaylistCursor(scope)
        let removed = try await cursor(f)
        XCTAssertNil(removed)
    }
}
