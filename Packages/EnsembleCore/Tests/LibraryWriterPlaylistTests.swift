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

    /// Forwards to a real repository, logs every call by name, and lets a test hold or fail a call at a named
    /// point. Events: `read` (sync states), `fetch` (one playlist), `body:<track IDs>`, `upsert:<title>`,
    /// `orphans`, `delete`.
    private final class HookedPlaylistRepository: PlaylistRepositoryProtocol, @unchecked Sendable {
        let base: PlaylistRepository
        private let lock = NSLock()
        private var log: [String] = []
        private var hook: (@Sendable (String) async throws -> Void)?

        init(base: PlaylistRepository) { self.base = base }

        /// Runs before each call, after it is logged. It may suspend the call or throw from it.
        func onCall(_ hook: @escaping @Sendable (String) async throws -> Void) { lock.withLock { self.hook = hook } }
        var events: [String] { lock.withLock { log } }
        func count(_ prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }

        private func note(_ event: String) async throws {
            let hook = lock.withLock { log.append(event); return self.hook }
            try await hook?(event)
        }

        func fetchPlaylists() async throws -> [CDPlaylist] { try await base.fetchPlaylists() }
        func fetchPlaylists(sourceCompositeKey: String?) async throws -> [CDPlaylist] { try await base.fetchPlaylists(sourceCompositeKey: sourceCompositeKey) }
        func fetchPlaylist(ratingKey: String, sourceCompositeKey: String?) async throws -> CDPlaylist? {
            try await note("fetch")
            return try await base.fetchPlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)
        }
        func searchPlaylists<Value: Sendable>(query: String, map: @escaping @Sendable ([CDPlaylist]) -> [Value]) async throws -> [Value] { try await base.searchPlaylists(query: query, map: map) }
        func findPlaylistsByTitle(_ title: String, sourceCompositeKeys: Set<String>?) async throws -> [CDPlaylist] { try await base.findPlaylistsByTitle(title, sourceCompositeKeys: sourceCompositeKeys) }
        func upsertPlaylist(ratingKey: String, key: String, title: String, summary: String?, compositePath: String?, isSmart: Bool, duration: Int?, trackCount: Int?, dateAdded: Date?, dateModified: Date?, lastPlayed: Date?, sourceCompositeKey: String?) async throws -> CDPlaylist {
            try await base.upsertPlaylist(ratingKey: ratingKey, key: key, title: title, summary: summary, compositePath: compositePath, isSmart: isSmart, duration: duration, trackCount: trackCount, dateAdded: dateAdded, dateModified: dateModified, lastPlayed: lastPlayed, sourceCompositeKey: sourceCompositeKey)
        }
        func upsertPlaylist(_ input: PlaylistUpsertInput, sourceCompositeKey: String?) async throws -> CDPlaylist {
            try await note("upsert:\(input.title)")
            return try await base.upsertPlaylist(input, sourceCompositeKey: sourceCompositeKey)
        }
        func setPlaylistTracks(_ trackRatingKeys: [String], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws { try await base.setPlaylistTracks(trackRatingKeys, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey) }
        func setPlaylistTrackSnapshots(_ snapshots: [PlaylistTrackSnapshot], forPlaylist playlistRatingKey: String, sourceCompositeKey: String?) async throws {
            try await note("body:" + snapshots.map(\.ratingKey).joined(separator: ","))
            try await base.setPlaylistTrackSnapshots(snapshots, forPlaylist: playlistRatingKey, sourceCompositeKey: sourceCompositeKey)
        }
        func deletePlaylists(sourceCompositeKey: String) async throws { try await base.deletePlaylists(sourceCompositeKey: sourceCompositeKey) }
        func deletePlaylist(ratingKey: String, sourceCompositeKey: String) async throws -> Bool {
            try await note("delete")
            return try await base.deletePlaylist(ratingKey: ratingKey, sourceCompositeKey: sourceCompositeKey)
        }
        func removeOrphanedPlaylists(notIn validRatingKeys: Set<String>, forSource sourceKey: String) async throws -> Int {
            try await note("orphans")
            return try await base.removeOrphanedPlaylists(notIn: validRatingKeys, forSource: sourceKey)
        }
        func fetchPlaylistSyncStates(forSource sourceKey: String) async throws -> [String: PlaylistSyncState] {
            try await note("read")
            return try await base.fetchPlaylistSyncStates(forSource: sourceKey)
        }
    }

    /// Holds a body write until the test lets it go, so a second operation can arrive while the first is mid-write.
    private actor Gate {
        private var started = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func hold() async {
            started = true
            if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        }
        var isHeld: Bool { started }
        func release() { isOpen = true; waiters.forEach { $0.resume() }; waiters.removeAll() }
    }

    private struct Injected: Error {}

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
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

    /// Waits until the writer has been handed `count` playlist operations in all: the call has arrived, and
    /// either waits its turn in the chain or runs.
    private func waitForSubmissions(_ f: Fixture, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        await wait("the writer to be handed \(count) playlist operations", file: file, line: line) { await f.writer.playlistOperationsSubmitted >= count }
    }

    /// Waits for `gate` to hold a call. A hold that never comes fails the test instead of hanging the suite.
    private func waitHeld(_ gate: Gate, file: StaticString = #filePath, line: UInt = #line) async {
        await wait("a call to reach the gate", file: file, line: line) { await gate.isHeld }
    }

    /// Polls `condition` until it holds or ten seconds pass; a timeout is a test failure.
    private func wait(_ what: String, file: StaticString, line: UInt, _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            if ContinuousClock.now > deadline { return XCTFail("Timed out waiting for \(what)", file: file, line: line) }
            await Task.yield()
        }
    }

    /// Gives work that must NOT run yet the chance to run if it wrongly would: polls (each poll is a real store
    /// read, with no clock) until `condition` holds or the budget is spent. With the chain intact the condition
    /// never holds and the budget runs out; without it the condition holds within a few polls.
    private func letOtherWorkRun(_ f: Fixture, budget: Int = 300, until condition: () -> Bool) async {
        for _ in 0..<budget {
            if condition() { return }
            _ = try? await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        }
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
        _ ids: [String], bodies: [String: [PlaylistTrackSnapshot]] = [:], complete: Bool = true, at date: Date, modified: TimeInterval = 100, title: String? = nil
    ) throws -> PlaylistBatch {
        PlaylistBatch(
            entries: ids.map { PlaylistEntry(header: header($0, at: modified, count: bodies[$0]?.count ?? 0, title: title), body: bodies[$0]) },
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

    /// An Apple Music playlist the REST list lacks takes its artwork from MusicKit, whose URL varies per read
    /// around a fixed `aat` asset: an unchanged playlist must not be rewritten each sync, a new image must.
    func testAnUnchangedAppleMusicPlaylistIsNotRewrittenButNewArtworkIs() async throws {
        let f = try makeFixture()
        func listed(_ url: String) -> PlaylistBatch {
            let base = header("native", at: 100, count: 0)
            let input = PlaylistUpsertInput(
                ratingKey: base.ratingKey, key: base.key, title: base.title, summary: nil,
                compositePath: AppleMusicArtworkPath.stable(url), isSmart: false, duration: 0, trackCount: 0,
                dateAdded: nil, dateModified: base.dateModified, lastPlayed: nil
            )
            return PlaylistBatch(entries: [PlaylistEntry(header: input, body: nil)], queryStartedAt: .now)
        }
        let image = "musicKit://artwork/library/a/1200x1200?aat=Music115%2Fv4%2Fcover.png"
        try await f.writer.apply(listed("\(image)&at=item&r=1"), for: scope)
        try await f.writer.apply(listed("\(image)&at=item&r=2"), for: scope)
        XCTAssertEqual(f.hooked.count("upsert:"), 1)

        try await f.writer.apply(listed("musicKit://artwork/library/a/1200x1200?aat=Music115%2Fv4%2Fother.png&r=3"), for: scope)
        XCTAssertEqual(f.hooked.count("upsert:"), 2)
        XCTAssertEqual(AppleMusicArtworkPath.stable("https://example.com/{w}x{h}.jpg"), "https://example.com/{w}x{h}.jpg")
        XCTAssertNil(AppleMusicArtworkPath.stable(nil))
        XCTAssertEqual(AppleMusicArtworkPath.stable("musicKit://artwork/x?at=item"), "musicKit://artwork/x?at=item")
    }

    /// MusicKit may hand back a pre-signed artwork URL that is new on every read. The row keeps the latest URL,
    /// but a signature-only difference is not a change: nothing counts as written, so nothing is published
    /// or re-indexed, and no artwork is invalidated. A different image, or one appearing or going, still is.
    func testASignatureOnlyArtworkChangeRefreshesTheRowWithoutCountingAsAChange() async throws {
        let f = try makeFixture()
        func listed(_ url: String?) -> PlaylistBatch {
            let base = header("signed", at: nil, count: 0)
            let input = PlaylistUpsertInput(
                ratingKey: base.ratingKey, key: base.key, title: base.title, summary: nil,
                compositePath: url, isSmart: false, duration: 0, trackCount: 0,
                dateAdded: nil, dateModified: base.dateModified, lastPlayed: nil
            )
            return PlaylistBatch(entries: [PlaylistEntry(header: input, body: nil)], queryStartedAt: .now)
        }
        func signed(_ image: String, _ signature: String) -> String {
            "https://bucket.s3.amazonaws.com/\(image).jpg?X-Amz-Algorithm=A&X-Amz-Date=\(signature)&X-Amz-Signature=\(signature)&size=1200"
        }
        func storedPath() async throws -> String? {
            try await f.playlists.fetchPlaylistSyncStates(forSource: scope)["signed"]?.compositePath
        }
        let cases: [(name: String, url: String?, changed: Int, invalidations: Int, stored: String?)] = [
            ("first sight", signed("a", "1"), 1, 0, signed("a", "1")),
            ("new signature only", signed("a", "2"), 0, 0, signed("a", "2")),
            ("same string", signed("a", "2"), 0, 0, signed("a", "2")),
            ("different image", signed("b", "3"), 1, 1, signed("b", "3")),
            ("artwork gone", nil, 1, 1, nil),
            ("artwork back", signed("b", "4"), 1, 1, signed("b", "4")),
        ]
        for testCase in cases {
            _ = f.playlists.drainArtworkInvalidationInfo()
            let result = try await f.writer.apply(listed(testCase.url), for: scope)
            let stored = try await storedPath()
            XCTAssertEqual(result.changedPlaylists, testCase.changed, testCase.name)
            XCTAssertEqual(f.playlists.drainArtworkInvalidationInfo().count, testCase.invalidations, testCase.name)
            XCTAssertEqual(stored, testCase.stored, testCase.name)
        }
        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        let state = try XCTUnwrap(states["signed"])
        let incoming = listed(signed("b", "5")).entries[0].header
        XCTAssertEqual(state.headerDifferences(from: incoming), ["compositePath(signature)"])
        XCTAssertEqual(f.hooked.count("upsert:"), 5)
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

            XCTAssertEqual(result, PlaylistSyncResult(rejectedAsStale: true), testCase.name)
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

    /// An operation that arrives while a pass is held mid-write runs after the pass, not inside it: the pass's
    /// last save lands first and the local edit is the final write.
    func testALocalEditArrivingMidPassRunsAfterThePass() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        f.hooked.onCall { event in if event == "body:x" { await gate.hold() } }
        let submitted = await f.writer.playlistOperationsSubmitted

        let pass = Task { try await f.writer.apply(self.list(["p1"], bodies: ["p1": self.tracks("x")], at: Date(), modified: 200), for: self.scope) }
        await waitHeld(gate)
        let edit = Task { try await f.writer.applyLocalEdit(PlaylistEntry(header: self.header("p1", at: 200, count: 2), body: self.tracks("a", "b")), for: self.scope) }
        await waitForSubmissions(f, submitted + 2)
        let reads = f.hooked.count("read")
        await letOtherWorkRun(f) { f.hooked.count("read") > reads }   // the edit's first call, if it ran unchained
        await gate.release()
        _ = try await pass.value
        try await edit.value

        let events = f.hooked.events
        let held = try XCTUnwrap(events.firstIndex(of: "body:x"))
        let passSaved = try XCTUnwrap(events[held...].firstIndex { $0.hasPrefix("upsert:") })
        let editStarted = try XCTUnwrap(events[held...].firstIndex { $0 == "read" })
        XCTAssertLessThan(passSaved, editStarted, "the edit's first store call came after the pass's last save")
        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "b"])
    }

    /// A queued mutation the pass did not see at its start stays unprotected for that pass, so the edit that
    /// queues it and caches its title runs after the pass and its title is the last write.
    func testAMutationQueuedMidPassIsAppliedAfterThePassNotInsideIt() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        f.hooked.onCall { event in if event == "upsert:Server title" { await gate.hold() } }   // the pass's header save
        let submitted = await f.writer.playlistOperationsSubmitted
        let payload = try JSONEncoder().encode(PlaylistRenameMutationPayload(playlistRatingKey: "p1", playlistSourceCompositeKey: scope, newTitle: "Renamed"))

        let pass = Task { try await f.writer.apply(self.list(["p1"], at: Date(), modified: 200, title: "Server title"), for: self.scope) }
        await waitHeld(gate)
        let editRan = Flag()
        let edit = Task {
            try await f.writer.performPlaylistEdit {
                try await f.pending.enqueueMutation(id: "m1", type: .playlistRename, payload: payload, sourceCompositeKey: self.scope)
                try await f.playlists.updatePlaylistTitle(ratingKey: "p1", sourceCompositeKey: self.scope, title: "Renamed")
                editRan.set()
            }
        }
        await waitForSubmissions(f, submitted + 2)
        await letOtherWorkRun(f) { editRan.isSet }   // the edit's whole body, if it ran unchained
        await gate.release()
        _ = try await pass.value
        try await edit.value

        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.title, "Renamed", "the pass's older title did not overwrite the local rename")
        let records = try await f.pending.fetchPendingMutationRecords()
        XCTAssertEqual(records.count, 1)

        // The next pass sees the record from its start and keeps the title.
        try await f.writer.apply(list(["p1"], at: Date().addingTimeInterval(1), modified: 300, title: "Server title"), for: scope)
        let after = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(after["p1"]?.title, "Renamed")
    }

    /// An online rename leaves no queued record, so its chained title write marks the playlist edited instead: a
    /// pass whose read began earlier but reaches the chain after the rename leaves the new title alone.
    func testAPassFetchedBeforeAnOnlineRenameCannotOverwriteItsTitle() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }
        f.hooked.onCall { event in if event == "body:z" { await gate.hold() } }
        let submitted = await f.writer.playlistOperationsSubmitted

        // The chain is busy; the rename is submitted first, then a pass whose read began before the rename.
        let busy = Task { try await f.writer.apply(self.list(["p1"], bodies: ["p1": self.tracks("z")], at: Date().addingTimeInterval(-10), modified: 150), for: self.scope) }
        await waitHeld(gate)
        let rename = Task {
            try await f.writer.performPlaylistEdit(editing: ("p1", self.scope)) {
                try await f.playlists.updatePlaylistTitle(ratingKey: "p1", sourceCompositeKey: self.scope, title: "Renamed")
            }
        }
        await waitForSubmissions(f, submitted + 2)
        let earlier = Task { try await f.writer.apply(self.list(["p1"], at: Date().addingTimeInterval(-5), modified: 200, title: "Server title"), for: self.scope) }
        await waitForSubmissions(f, submitted + 3)
        await gate.release()
        _ = try await busy.value
        try await rename.value
        _ = try await earlier.value

        let states = try await f.playlists.fetchPlaylistSyncStates(forSource: scope)
        XCTAssertEqual(states["p1"]?.title, "Renamed")
        XCTAssertEqual(states["p1"]?.dateModified, Date(timeIntervalSince1970: 150), "the date stays the server's")
    }

    /// Two passes started together apply one after the other: the older read, held mid-write, is rejected by the
    /// newer pass's cursor instead of overwriting it afterwards.
    func testOverlappingPassesEndInTheNewerReadsState() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1", "p2"], bodies: ["p1": tracks("a"), "p2": tracks("b")], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        f.hooked.onCall { event in if event == "body:o" { await gate.hold() } }
        let submitted = await f.writer.playlistOperationsSubmitted
        let now = Date()   // reads began in the past: a cursor dated in the future reads as a clock that went backwards

        let older = Task { try await f.writer.apply(self.list(["p1", "p2"], bodies: ["p1": self.tracks("o"), "p2": self.tracks("b")], at: now - 10, modified: 150), for: self.scope) }
        await waitHeld(gate)
        let newer = Task { try await f.writer.apply(self.list(["p1", "p3"], bodies: ["p1": self.tracks("a", "n"), "p3": self.tracks("c")], at: now - 5, modified: 200), for: self.scope) }
        await waitForSubmissions(f, submitted + 2)
        await letOtherWorkRun(f) { f.hooked.count("body:a,n") > 0 }   // the newer pass's write, if it ran unchained
        await gate.release()
        let results = try await (older.value, newer.value)

        XCTAssertFalse(results.1.rejectedAsStale)
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
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        f.hooked.onCall { event in if event == "body:b,n" { await gate.hold() } }   // p2's body: p1 has committed by now

        let pass = Task { try await f.writer.apply(self.list(["p1", "p2"], bodies: ["p1": self.tracks("a", "n"), "p2": self.tracks("b", "n")], at: self.t0 + 10, modified: 200), for: self.scope) }
        await waitHeld(gate)
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

    /// The chain goes on after an operation is cancelled while queued, cancelled mid-run, or fails on a store error.
    func testTheChainContinuesAfterACancelledQueuedOperationACancelledRunAndAStoreError() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        f.hooked.onCall { event in
            if event == "body:held" { await gate.hold() }
            if event == "body:fails" { throw Injected() }
        }
        let submitted = await f.writer.playlistOperationsSubmitted
        func edit(_ ids: String...) -> Task<Void, Error> {
            Task { try await f.writer.applyLocalEdit(PlaylistEntry(header: self.header("p1", at: 100, count: ids.count), body: ids.enumerated().map { PlaylistTrackSnapshot(ratingKey: $1, playlistItemID: "i\($0)", title: $1) }), for: self.scope) }
        }

        let running = edit("held")                               // runs, then is cancelled while held
        await waitHeld(gate)
        let queuedThenCancelled = edit("never")                  // cancelled while it waits its turn
        let storeError = edit("fails")                           // fails when it runs
        let survivor = edit("a", "survivor")                     // must still run
        await waitForSubmissions(f, submitted + 4)
        queuedThenCancelled.cancel()
        running.cancel()
        await gate.release()

        for (name, task) in [("running", running), ("queued", queuedThenCancelled)] {
            do { try await task.value; XCTFail("\(name) should be cancelled") } catch is CancellationError {}
        }
        do { try await storeError.value; XCTFail("expected the store error") } catch is Injected {}
        try await survivor.value
        let rows = try await body(f, "p1")
        XCTAssertEqual(rows, ["a", "survivor"])
        // And the chain still accepts work afterwards.
        try await f.writer.applyLocalEdit(PlaylistEntry(header: header("p1", at: 100, count: 1), body: tracks("last")), for: scope)
        let last = try await body(f, "p1")
        XCTAssertEqual(last, ["last"])
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

    /// Adds made together all land: each reads, merges and saves the body inside one serialized operation. The
    /// first add is held at its body write while eight more arrive; they must not read the playlist meanwhile.
    func testConcurrentAppendsAllLand() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let gate = Gate()
        defer { Task { await gate.release() } }   // a regression must fail, not hang the suite
        let writes = LockedCounter()
        f.hooked.onCall { event in if event.hasPrefix("body:"), writes.next() == 0 { await gate.hold() } }
        let submitted = await f.writer.playlistOperationsSubmitted
        let source = MusicSourceIdentifier(type: .plex, accountId: "acct", serverId: "srv", libraryId: "1").compositeKey
        func track(_ id: String) -> Track { Track(id: id, key: id, title: id, sourceCompositeKey: source) }
        func append(_ id: String) -> Task<Int?, Error> { Task { try await f.writer.appendLocally([track(id)], toPlaylist: "p1", for: self.scope) } }

        var tasks = [append("t0")]
        await waitHeld(gate)
        tasks += (1..<8).map { append("t\($0)") }
        tasks.append(append("a"))                               // already in the playlist: adds nothing
        await waitForSubmissions(f, submitted + 9)
        let fetches = f.hooked.count("fetch")
        await letOtherWorkRun(f) { f.hooked.count("fetch") > fetches }   // another add's read, if it ran unchained
        await gate.release()
        var counts: [Int?] = []
        for task in tasks { counts.append(try await task.value) }

        let rows = try await body(f, "p1")
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(Set(rows), Set(["a"] + (0..<8).map { "t\($0)" }))
        XCTAssertEqual(counts.compactMap { $0 }.max(), 9)
        let missing = try await f.writer.appendLocally([track("x")], toPlaylist: "gone", for: scope)
        XCTAssertNil(missing, "a playlist that is not stored reports so")
    }

    /// The local delete of a playlist the server already deleted is retried, so one failed save does not leave
    /// the row of a scope's last playlist behind. A persistent failure is reported, and the row stays.
    func testAFailedLocalDeleteIsRetried() async throws {
        let f = try makeFixture()
        try await f.writer.apply(list(["p1"], bodies: ["p1": tracks("a")], at: t0), for: scope)
        let failures = LockedCounter()
        f.hooked.onCall { event in if event == "delete", failures.next() < 2 { throw Injected() } }

        try await f.writer.removePlaylist("p1", for: scope)

        let ids = try await storedIDs(f, scope)
        XCTAssertEqual(ids, [])
        XCTAssertEqual(f.hooked.count("delete"), 3, "two failures, then the delete")

        try await f.writer.apply(list(["p2"], bodies: ["p2": tracks("b")], at: t0 + 10), for: scope)
        f.hooked.onCall { event in if event == "delete" { throw Injected() } }
        do { try await f.writer.removePlaylist("p2", for: scope); XCTFail("expected the failure to surface") } catch is Injected {}
        let kept = try await storedIDs(f, scope)
        XCTAssertEqual(kept, ["p2"])
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
