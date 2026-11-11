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

    /// Forwards to a real repository and lets a test hold or observe each body write.
    private final class HookedPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        let base: PlaylistRepository
        private let lock = NSLock()
        private var writes = 0
        private var hook: (@Sendable (Int) async -> Void)?

        init(base: PlaylistRepository) { self.base = base }

        /// Runs before each body write, with the number of that write (the first is 1).
        func beforeBodyWrite(_ hook: @escaping @Sendable (Int) async -> Void) { lock.withLock { self.hook = hook } }

        func fetchPlaylists() async throws -> [CDPlaylist] { try await base.fetchPlaylists() }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { try await base.fetchPlaylists(sourceCompositeKey: sourceCompositeKey) }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? { try await base.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey) }
        func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { try await base.searchPlaylists(query: query, map: map) }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { try await base.findPlaylistsByTitle(title, sourceCompositeKeys: sourceCompositeKeys) }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist {
            try await base.upsertPlaylist(ratingKey: ratingKey, key: key, title: title, summary: summary, compositePath: compositePath, isSmart: isSmart, duration: duration, trackCount: trackCount, dateAdded: dateAdded, dateModified: dateModified, lastPlayed: lastPlayed, sourceCompositeKey: sourceCompositeKey)
        }
        func upsertPlaylist(_ input: PlaylistUpsertInput, sourceCompositeKey: String?) async throws -> CDPlaylist { try await base.upsertPlaylist(input, sourceCompositeKey: sourceCompositeKey) }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws { try await base.setPlaylistTracks(trackRatingKeys, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey) }
        func setPlaylistTrackSnapshots(_ snapshots: [PlaylistTrackSnapshot], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {
            let (count, hook) = lock.withLock { writes += 1; return (writes, self.hook) }
            await hook?(count)
            try await base.setPlaylistTrackSnapshots(snapshots, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey)
        }
        func deletePlaylists(sourceCompositeKey: String) async throws { try await base.deletePlaylists(sourceCompositeKey: sourceCompositeKey) }
        func deletePlaylist(ratingKey: String, sourceCompositeKey: String) async throws -> Bool { try await base.deletePlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey) }
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int { try await base.removeOrphanedPlaylists(notIn: validRatingKeys, forSource: sourceKey) }
        func fetchPlaylistSyncStates(forSource sourceKey: String) async throws -> [String: PlaylistSyncState] { try await base.fetchPlaylistSyncStates(forSource: sourceKey) }
    }

    /// Holds a body write until the test lets it go, so a second operation can arrive while the first is mid-write.
    private actor Gate {
        private var started = false
        private var isOpen = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        }
        func waitUntilHeld() async { if !started { await withCheckedContinuation { startWaiters.append($0) } } }
        func release() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private struct Fixture {
        let writer: LibraryWriter
        let playlists: PlaylistRepository
        let hooked: HookedPlaylistRepository
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
        let hooked = HookedPlaylistRepository(base: playlists)
        let cursors = SyncCursorRepository(coreDataStack: stack)
        let pending = PendingMutationRepository(coreDataStack: stack)
        return Fixture(
            writer: LibraryWriter(
                libraryRepository: LibraryRepository(coreDataStack: stack), playlistRepository: hooked,
                syncCursorRepository: cursors, pendingMutationRepository: pending
            ),
            playlists: playlists, hooked: hooked, cursors: cursors, pending: pending,
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

    /// A queued add, remove or delete is an edit the server has not seen: a read leaves that playlist's header and
    /// body alone, reports nothing unresolved, and an inventory that lacks it cannot delete it. A queued rename
    /// is no different for deletion. Once the record is gone the server's state applies.
    func testAPlaylistWithAQueuedMutationIsNotOverwrittenOrDeleted() async throws {
        struct Case { let type: CDPendingMutation.MutationType; let payload: Data }
        func data<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
        let reference = OfflineTrackReference(trackRatingKey: "t", trackSourceCompositeKey: "plex:acct:srv:1")
        let cases = [
            Case(type: .playlistAdd, payload: try data(PlaylistMutationPayload(playlistRatingKey: "p1", playlistSourceCompositeKey: scope, trackReferences: [reference]))),
            Case(type: .playlistRemove, payload: try data(PlaylistMutationPayload(playlistRatingKey: "p1", playlistSourceCompositeKey: scope, trackReferences: [reference]))),
            Case(type: .playlistDelete, payload: try data(PlaylistDeleteMutationPayload(playlistRatingKey: "p1", playlistSourceCompositeKey: scope))),
        ]
        for testCase in cases {
            let f = try makeFixture()
            try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
            try await f.pending.enqueueMutation(id: "m1", type: testCase.type, payload: testCase.payload, sourceCompositeKey: scope)
            // The record names another scope's playlist too, which must not protect this scope.
            try await f.pending.enqueueMutation(
                id: "m2", type: .playlistDelete,
                payload: try data(PlaylistDeleteMutationPayload(playlistRatingKey: "p2", playlistSourceCompositeKey: otherScope)), sourceCompositeKey: otherScope
            )

            // The server's complete list holds only p3: p2 goes, p1 (queued) stays although the list lacks it.
            let changed = try await f.writer.apply(PlaylistBatch(
                entries: [PlaylistEntry(header: header("p3", at: 100, count: 0), body: [])],
                inventory: try PlaylistInventory(playlistIDs: ["p3"]), readsFullList: true, queryStartedAt: t0 + 10
            ), for: scope)
            var ids = try await storedIDs(f, scope)
            XCTAssertEqual(ids, ["p1", "p3"], "\(testCase.type): p1 is queued, so the inventory keeps it; p2 is not")
            XCTAssertEqual(changed.removedPlaylists, 1, "\(testCase.type)")

            let read = try await f.writer.apply(PlaylistBatch(
                entries: [PlaylistEntry(header: header("p1", at: 200, count: 2, title: "Server"), body: tracks("x", "y"))],
                readsFullList: true, queryStartedAt: t0 + 20
            ), for: scope)
            let rows = try await body(f, "p1")
            XCTAssertEqual(rows, ["a"], "\(testCase.type): the read cannot overwrite the body")
            let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
            XCTAssertEqual(states["p1"]?.title, "Playlist p1", "\(testCase.type)")
            XCTAssertEqual(read, PlaylistSyncResult(), "\(testCase.type): skipped, not unresolved")

            try await f.pending.deleteMutation(id: "m1")
            try await f.writer.apply(PlaylistBatch(
                entries: [PlaylistEntry(header: header("p1", at: 200, count: 2, title: "Server"), body: tracks("x", "y"))],
                inventory: try PlaylistInventory(playlistIDs: ["p1"]), readsFullList: true, queryStartedAt: t0 + 30
            ), for: scope)
            let after = try await body(f, "p1")
            XCTAssertEqual(after, ["x", "y"], "\(testCase.type): once uploaded the server's state applies")
            ids = try await storedIDs(f, scope)
            XCTAssertEqual(ids, ["p1"], "\(testCase.type)")
        }
    }

    /// p1 is rewritten and p2 is deleted by the inventory; a target on each keeps its row.
    func testOfflineTargetsSurviveBodyRewritesAndDeletions() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
        let keys = ["p1", "p2"].map { "offline:playlist:\(scope):*:\($0)" }
        for (key, id) in zip(keys, ["p1", "p2"]) {
            _ = try await f.targets.upsertTarget(key: key, kind: .playlist, ratingKey: id, sourceCompositeKey: scope, displayName: "Playlist \(id)")
        }

        let result = try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", "c")], at: t0 + 10, modified: 200), for: scope)

        XCTAssertEqual(result.removedPlaylists, 1)
        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, ["p1"])
        for key in keys {
            let target = try await f.targets.fetchTarget(key: key)
            XCTAssertNotNil(target, key)
        }
    }

    // MARK: - Reads that finish out of order

    /// A read that began before the newest committed list read describes older state, so it changes nothing:
    /// it cannot delete a playlist the newer read listed or bring back one it removed, and a targeted read
    /// cannot overwrite a newer body. A read that began after it applies.
    func testAnOlderReadFinishingLateChangesNothing() async throws {
        let older = t0 + 10
        let cases: [(name: String, batch: PlaylistBatch)] = [
            ("older list that still has the removed playlist", try list(["p1", "p2"], bodies: ["p2": tracks("c")], at: older, modified: 150)),
            ("older list lacking a listed playlist", try list(["p2"], at: older)),
            ("older unproven list", try list(["p1", "p2"], complete: false, at: older, modified: 300)),
            ("older targeted read of the removed playlist", PlaylistBatch(entries: [PlaylistEntry(header: header("p2", at: 150, count: 1), body: tracks("c"))], queryStartedAt: older)),
            ("older targeted read with a newer date and another body", PlaylistBatch(entries: [PlaylistEntry(header: header("p1", at: 300, count: 1), body: tracks("z"))], queryStartedAt: older)),
        ]
        for testCase in cases {
            let f = try makeFixture()
            try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
            try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a", "b")], at: t0 + 20, modified: 200), for: scope)

            let result = try await f.writer.apply(testCase.batch, for: scope)

            XCTAssertEqual(result, PlaylistSyncResult(), testCase.name)
            let ids = try await storedIDs(f, scope)
            XCTAssertEqual(ids, ["p1"], testCase.name)
            let rows = try await body(f, "p1")
            XCTAssertEqual(rows, ["a", "b"], testCase.name)
            let record = try await cursor(f)
            XCTAssertEqual(record?.lastInventorySyncAt, t0 + 20, testCase.name)
        }

        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("p1", at: 300, count: 2), body: tracks("a", "c")), PlaylistEntry(header: header("p3", at: 100, count: 1), body: tracks("x"))],
            queryStartedAt: t0 + 30
        ), for: scope)
        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "c"], "a targeted read that began later applies")
        let created = try await body(f, "p3")
        XCTAssertEqual(created, ["x"])
    }

    /// An operation that arrives while a pass is mid-write waits for it, so the local edit is the last write
    /// instead of being overwritten by the pass's body.
    func testALocalEditArrivingMidPassWaitsForThePass() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let gate = Gate()
        f.hooked.beforeBodyWrite { count in if count == 2 { await gate.hold() } }   // 1 was the seed above

        let pass = Task { try await f.writer.apply(self.list(["p1"], bodies: ["p1": self.tracks("x")], at: Date(), modified: 200), for: self.scope) }
        await gate.waitUntilHeld()
        let edit = Task { try await f.writer.applyLocalEdit(PlaylistEntry(header: self.header("p1", at: 200, count: 2), body: self.tracks("a", "b")), for: self.scope) }
        try await Task.sleep(nanoseconds: 100_000_000)
        await gate.release()
        _ = try await pass.value
        try await edit.value

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "b"])
    }

    /// Two passes started together apply one after the other: the older read is ignored whichever arrives first.
    func testOverlappingPassesEndInTheNewerReadsState() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
        f.hooked.beforeBodyWrite { _ in try? await Task.sleep(nanoseconds: 20_000_000) }
        let now = Date()   // reads began in the past: a cursor dated in the future reads as a clock that went backwards

        let newer = Task { try await f.writer.apply(self.list(["p1", "p3"], bodies: ["p1": self.tracks("a", "n"), "p3": self.tracks("c")], at: now - 5, modified: 200), for: self.scope) }
        let older = Task { try await f.writer.apply(self.list(["p1", "p2"], bodies: ["p1": self.tracks("o"), "p2": self.tracks("b")], at: now - 10, modified: 150), for: self.scope) }
        _ = try await (newer.value, older.value)

        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, ["p1", "p3"])
        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "n"])
        let record = try await cursor(f)
        XCTAssertEqual(record?.lastInventorySyncAt, now - 5)
    }

    /// A pass cancelled between playlists keeps the playlists it finished, deletes nothing and leaves the cursor.
    func testACancelledPassKeepsFinishedPlaylistsAndDeletesNothing() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2", "p3"], bodies: ["p1": tracks("a"), "p2": tracks("b"), "p3": tracks("c")], at: t0), for: scope)
        let gate = Gate()
        f.hooked.beforeBodyWrite { count in if count == 5 { await gate.hold() } }   // 1 to 3 were the seed; 4 is p1

        let pass = Task { try await f.writer.apply(self.list(["p1", "p2"], bodies: ["p1": self.tracks("a", "n"), "p2": self.tracks("b", "n")], at: self.t0 + 10, modified: 200), for: self.scope) }
        await gate.waitUntilHeld()
        pass.cancel()
        await gate.release()
        do { _ = try await pass.value; XCTFail("expected cancellation") } catch is CancellationError {}

        let finished = try await body(f, "p1")
        XCTAssertEqual(finished, ["a", "n"])
        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.dateModified, Date(timeIntervalSince1970: 200), "p1 committed its body and date")
        XCTAssertEqual(states["p2"]?.dateModified, Date(timeIntervalSince1970: 100), "p2's date did not move, so the next pass reads it again")
        XCTAssertEqual(Set(states.keys), ["p1", "p2", "p3"], "the inventory deleted nothing")
        let record = try await cursor(f)
        XCTAssertEqual(record?.lastInventorySyncAt, t0)
    }

    // MARK: - Unresolved bodies

    /// A header that needed a body and got none is reported, whether it is new or changed, and keeps the
    /// stored body and date; unchanged, older and locally edited playlists are not.
    func testPlaylistsWhoseBodyWasNeededButMissingAreReportedUnresolved() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p3", "p4", "p5"], bodies: ["p1": tracks("a"), "p3": tracks("c"), "p4": tracks("d"), "p5": tracks("e")], at: t0, modified: 100), for: scope)
        try await f.writer.apply(PlaylistBatch(entries: [PlaylistEntry(header: header("p4", at: 300, count: 1), body: tracks("d"))], queryStartedAt: t0 + 5), for: scope)
        let readBegan = Date().addingTimeInterval(-5)
        try await f.writer.applyLocalEdit(PlaylistEntry(header: header("p5", at: 100, count: 2), body: tracks("e", "f")), for: scope)

        let result = try await f.writer.apply(PlaylistBatch(
            entries: [
                PlaylistEntry(header: header("p1", at: 200, count: 1)),    // changed, body unread
                PlaylistEntry(header: header("p2", at: 100, count: 1)),    // new, body unread
                PlaylistEntry(header: header("p3", at: 100, count: 1)),    // unchanged
                PlaylistEntry(header: header("p4", at: 100, count: 1)),    // older than stored
                PlaylistEntry(header: header("p5", at: 400, count: 1)),    // edited after the read began
            ],
            readsFullList: true, queryStartedAt: readBegan
        ), for: scope)

        XCTAssertEqual(result.unresolvedPlaylists.sorted(), ["p1", "p2"])
        XCTAssertTrue(result.isPartial)
        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.dateModified, Date(timeIntervalSince1970: 100), "the stored date stays so the body is read again")
        XCTAssertNil(states["p2"]?.dateModified)
        let kept = try await body(f, "p1")
        XCTAssertEqual(kept, ["a"])

        let retry = try await f.writer.apply(PlaylistBatch(
            entries: [PlaylistEntry(header: header("p1", at: 200, count: 1), body: tracks("a2")), PlaylistEntry(header: header("p2", at: 100, count: 1), body: tracks("b"))],
            readsFullList: true, queryStartedAt: Date().addingTimeInterval(5)
        ), for: scope)
        XCTAssertFalse(retry.isPartial)
    }

    // MARK: - Local mutations

    /// Adds made together all land: each reads, merges and saves the body inside one serialized operation.
    func testConcurrentAppendsAllLand() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        f.hooked.beforeBodyWrite { _ in try? await Task.sleep(nanoseconds: 5_000_000) }
        let source = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1").compositeKey
        func track(_ id: String) -> Track { Track(id: id, key: id, title: id, sourceCompositeKey: source) }

        let counts = try await withThrowingTaskGroup(of: Int?.self) { group in
            for index in 0..<8 { group.addTask { try await f.writer.appendLocally([track("t\(index)")], toPlaylist: "p1", for: self.scope) } }
            // A track the playlist already holds adds nothing.
            group.addTask { try await f.writer.appendLocally([track("a")], toPlaylist: "p1", for: self.scope) }
            return try await group.reduce(into: [Int?]()) { $0.append($1) }
        }

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(Set(rows), Set(["a"] + (0..<8).map { "t\($0)" }))
        XCTAssertEqual(counts.compactMap { $0 }.max(), 9)
        let missing = try await f.writer.appendLocally([track("x")], toPlaylist: "gone", for: scope)
        XCTAssertNil(missing, "a playlist that is not stored reports so")
    }

    /// The server confirmed the delete: the playlist goes even when it was the scope's last, where the
    /// empty list that follows deletes nothing. An older read cannot bring it back.
    func testDeletingTheLastPlaylistRemovesItAndAnOlderReadCannotRestoreIt() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: otherScope)

        try await f.writer.removePlaylist("p1", for: scope)
        try await f.writer.removePlaylist("never-stored", for: scope)

        var mine = try await storedIDs(f, scope)
        XCTAssertEqual(mine, [])
        let theirs = try await storedIDs(f, otherScope)
        XCTAssertEqual(theirs, ["p1"])

        // The empty list a refresh reads next deletes nothing and brings nothing back.
        try await f.writer.apply(list([], at: Date().addingTimeInterval(1)), for: scope)
        // A list read before the delete still shows the playlist.
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0 + 10), for: scope)
        mine = try await storedIDs(f, scope)
        XCTAssertEqual(mine, [])
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
