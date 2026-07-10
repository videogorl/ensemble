import XCTest
@testable import EnsemblePersistence

final class SyncCursorRepositoryTests: XCTestCase {
    func testRecordFullSyncCreatesDurableCursor() async throws {
        let repository = SyncCursorRepository(coreDataStack: .inMemory())
        let date = Date(timeIntervalSince1970: 1_000)

        try await repository.recordFullSync(
            scopeKey: "plex:account:server",
            scopeType: .serverPlaylists,
            at: date
        )

        let cursor = try await repository.fetchCursor(
            scopeKey: "plex:account:server",
            scopeType: .serverPlaylists
        )
        XCTAssertEqual(cursor?.lastFullSyncAt, date)
        XCTAssertEqual(cursor?.lastInventorySyncAt, date)
        XCTAssertEqual(cursor?.lastSuccessfulSyncAt, date)
    }

    func testRecordInventorySyncUpdatesDurableCursor() async throws {
        let repository = SyncCursorRepository(coreDataStack: .inMemory())
        let scopeKey = "plex:account:server"
        let date = Date(timeIntervalSince1970: 2_000)

        try await repository.recordInventorySync(
            scopeKey: scopeKey,
            scopeType: .serverPlaylists,
            at: date
        )

        let cursor = try await repository.fetchCursor(
            scopeKey: scopeKey,
            scopeType: .serverPlaylists
        )
        XCTAssertEqual(cursor?.lastInventorySyncAt, date)
        XCTAssertEqual(cursor?.lastSuccessfulSyncAt, date)
    }

    func testDeleteCursorRemovesOnlyMatchingScope() async throws {
        let repository = SyncCursorRepository(coreDataStack: .inMemory())
        try await repository.recordIncrementalSync(
            scopeKey: "plex:account:server-a",
            scopeType: .serverPlaylists,
            at: Date(timeIntervalSince1970: 1)
        )
        try await repository.recordIncrementalSync(
            scopeKey: "plex:account:server-b",
            scopeType: .serverPlaylists,
            at: Date(timeIntervalSince1970: 2)
        )

        try await repository.deleteCursor(
            scopeKey: "plex:account:server-a",
            scopeType: .serverPlaylists
        )

        let removed = try await repository.fetchCursor(
            scopeKey: "plex:account:server-a",
            scopeType: .serverPlaylists
        )
        let retained = try await repository.fetchCursor(
            scopeKey: "plex:account:server-b",
            scopeType: .serverPlaylists
        )
        XCTAssertNil(removed)
        XCTAssertEqual(retained?.lastIncrementalSyncAt, Date(timeIntervalSince1970: 2))
    }

    func testOlderCompletionDoesNotRegressCursor() async throws {
        let repository = SyncCursorRepository(coreDataStack: .inMemory())
        let scopeKey = "plex:account:server"
        let newerDate = Date(timeIntervalSince1970: 2_000)

        try await repository.recordIncrementalSync(
            scopeKey: scopeKey,
            scopeType: .serverPlaylists,
            at: newerDate
        )
        try await repository.recordFullSync(
            scopeKey: scopeKey,
            scopeType: .serverPlaylists,
            at: Date(timeIntervalSince1970: 1_000)
        )

        let cursor = try await repository.fetchCursor(
            scopeKey: scopeKey,
            scopeType: .serverPlaylists
        )
        XCTAssertEqual(cursor?.lastIncrementalSyncAt, newerDate)
        XCTAssertEqual(cursor?.lastInventorySyncAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(cursor?.lastSuccessfulSyncAt, newerDate)
        XCTAssertEqual(cursor?.updatedAt, newerDate)
    }
}
