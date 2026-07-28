import XCTest
import EnsemblePersistence
@testable import EnsembleCore

final class HubRepositorySnapshotTests: XCTestCase {
    func testSaveAndFetchLatestHomeFeedSnapshot() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        let fetchedAt = Date()
        let hub = makeHub(id: "hub-1", context: "hub.music.artist")
        let snapshot = HomeFeedCachedSnapshot(
            id: "snapshot-1",
            sourceScopeKey: "plex:account:server",
            sourceName: "Editing Music",
            createdAt: fetchedAt,
            fetchedAt: fetchedAt,
            refreshReason: "background-refresh",
            freshnessState: .fresh,
            isLastGood: true,
            hubs: [hub]
        )

        try await repository.saveHomeFeedSnapshot(snapshot)

        let fetched = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:server")
        XCTAssertEqual(fetched?.id, "snapshot-1")
        XCTAssertEqual(fetched?.sourceScopeKey, "plex:account:server")
        XCTAssertEqual(fetched?.refreshReason, "background-refresh")
        XCTAssertEqual(fetched?.freshnessState, .fresh)
        XCTAssertEqual(fetched?.hubs.first?.context, "hub.music.artist")
        XCTAssertEqual(fetched?.hubs.first?.items.first?.title, "Track One")
    }

    func testFetchHubsPrefersLatestSnapshotOverLegacyCache() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        try await repository.saveHubs([makeHub(id: "legacy-hub", context: nil)])

        let snapshot = HomeFeedCachedSnapshot(
            id: "snapshot-2",
            sourceScopeKey: "plex:account:server",
            sourceName: "Editing Music",
            fetchedAt: Date(),
            refreshReason: "network",
            freshnessState: .fresh,
            isLastGood: true,
            hubs: [makeHub(id: "snapshot-hub", context: "hub.music.album")]
        )
        try await repository.saveHomeFeedSnapshot(snapshot)

        let hubs = try await repository.fetchHubs()
        XCTAssertEqual(hubs.map(\.id), ["snapshot-hub"])
        XCTAssertEqual(hubs.first?.context, "hub.music.album")
    }

    func testCombinedSnapshotReplacesSourceScopedSnapshots() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "source-snapshot",
                sourceScopeKey: "plex:account:server",
                sourceName: "Editing Music",
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [makeHub(id: "source-hub", context: nil)]
            )
        )
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "combined-snapshot",
                sourceScopeKey: nil,
                sourceName: "Editing Music",
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [makeHub(id: "combined-hub", context: nil)]
            )
        )

        let combined = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: nil)
        let oldScope = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:server")

        XCTAssertEqual(combined?.id, "combined-snapshot")
        XCTAssertNil(oldScope)
    }

    func testDeleteSnapshotsIsSourceScoped() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "snapshot-a",
                sourceScopeKey: "plex:account:a",
                sourceName: "A",
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [makeHub(id: "hub-a", context: nil)]
            )
        )
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "snapshot-b",
                sourceScopeKey: "plex:account:b",
                sourceName: "B",
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [makeHub(id: "hub-b", context: nil)]
            )
        )

        try await repository.deleteHomeFeedSnapshots(sourceScopeKey: "plex:account:a")

        let deleted = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:a")
        let preserved = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:b")
        XCTAssertNil(deleted)
        XCTAssertEqual(preserved?.id, "snapshot-b")
    }

    func testFetchHubsPreservesLastGoodSnapshotOverNewerFailedSnapshot() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        let lastGoodDate = Date().addingTimeInterval(-300)
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "last-good",
                sourceScopeKey: "plex:account:a",
                sourceName: "A",
                createdAt: lastGoodDate,
                fetchedAt: lastGoodDate,
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [makeHub(id: "last-good-hub", context: nil)]
            )
        )
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "failed-newer",
                sourceScopeKey: "plex:account:b",
                sourceName: "B",
                fetchedAt: Date(),
                refreshReason: "background-refresh",
                freshnessState: .failed,
                isLastGood: false,
                hubs: [makeHub(id: "failed-hub", context: nil)]
            )
        )

        let hubs = try await repository.fetchHubs()

        XCTAssertEqual(hubs.map(\.id), ["last-good-hub"])
    }

    func testMarkLastGoodUpdatesFreshnessMetadata() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                id: "stale-snapshot",
                sourceScopeKey: "plex:account:a",
                sourceName: "A",
                fetchedAt: Date(),
                refreshReason: "background-refresh",
                freshnessState: .failed,
                isLastGood: false,
                hubs: [makeHub(id: "hub-a", context: nil)]
            )
        )

        try await repository.markHomeFeedSnapshotLastGood(id: "stale-snapshot", freshnessState: .stale)

        let fetched = try await repository.fetchLatestHomeFeedSnapshot(sourceScopeKey: "plex:account:a")
        XCTAssertTrue(fetched?.isLastGood == true)
        XCTAssertEqual(fetched?.freshnessState, .stale)
        XCTAssertEqual(fetched?.refreshReason, "background-refresh")
    }

    func testDeletingSourceHubsPreservesOtherItemsInCombinedSnapshot() async throws {
        let repository = HubRepository(coreDataStack: .inMemory())
        let appleMusicSource = MusicSourceIdentifier.appleMusic.compositeKey
        let plexSource = "plex:account:server:library"
        let hub = Hub(
            id: "recently-added:merged:album",
            title: "Recently Added",
            type: "album",
            items: [
                HubItem(id: "apple-album", type: "album", title: "Apple Album", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: appleMusicSource),
                HubItem(id: "plex-album", type: "album", title: "Plex Album", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: plexSource),
            ]
        )
        let appleOnlyHub = Hub(
            id: "most-played:apple",
            title: "Most Played",
            type: "track",
            items: [HubItem(id: "apple-track", type: "track", title: "Apple Track", subtitle: nil, thumbPath: nil, year: nil, sourceCompositeKey: appleMusicSource)]
        )
        try await repository.saveHomeFeedSnapshot(
            HomeFeedCachedSnapshot(
                sourceScopeKey: nil,
                sourceName: "Music",
                fetchedAt: Date(),
                refreshReason: "network",
                freshnessState: .fresh,
                isLastGood: true,
                hubs: [hub, appleOnlyHub]
            )
        )

        try await repository.deleteHubs(forSourceCompositeKey: appleMusicSource)

        let fetchedHubs = try await repository.fetchHubs()
        XCTAssertEqual(fetchedHubs.count, 1)
        let fetchedHub = fetchedHubs.first
        XCTAssertEqual(fetchedHub?.items.map(\.id), ["plex-album"])
        XCTAssertEqual(fetchedHub?.items.first?.sourceCompositeKey, plexSource)
    }

    private func makeHub(id: String, context: String?) -> Hub {
        Hub(
            id: id,
            title: "Recently Played",
            type: "mixed",
            items: [
                HubItem(
                    id: "track-1",
                    type: "track",
                    title: "Track One",
                    subtitle: "Artist",
                    thumbPath: "/thumb",
                    year: nil,
                    sourceCompositeKey: "plex:account:server:library"
                )
            ],
            context: context
        )
    }
}
