import XCTest
@testable import EnsembleCore

@MainActor
final class HiddenMediaStoreTests: XCTestCase {
    func testExactRootsDeriveAndUseLastWriterWins() throws {
        let suiteName = "HiddenMediaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HiddenMediaStore(defaults: defaults)
        let source = "plex:account:server:library"
        let artist = HiddenMediaIdentity(kind: .artist, itemID: "artist", sourceCompositeKey: source)
        let album = HiddenMediaIdentity(kind: .album, itemID: "album", sourceCompositeKey: source)
        let track = Track(
            id: "track",
            key: "/track",
            title: "Track",
            albumRatingKey: album.itemID,
            artistRatingKey: artist.itemID,
            sourceCompositeKey: source
        )
        let start = Date(timeIntervalSince1970: 100)

        store.setHidden(true, identity: artist, at: start)
        XCTAssertTrue(store.snapshot.isHidden(track))

        store.setHidden(true, identity: album, at: start.addingTimeInterval(1))
        store.setHidden(false, identity: artist, at: start.addingTimeInterval(2))
        XCTAssertTrue(store.snapshot.isHidden(track), "An explicit child survives a parent unhide")

        store.applyRemote([
            HiddenMediaMutation(identity: album, isHidden: false, modifiedAt: start),
            HiddenMediaMutation(identity: album, isHidden: false, modifiedAt: start.addingTimeInterval(3))
        ])
        XCTAssertFalse(store.snapshot.isHidden(track))

        let readded = Track(id: "new-track", key: "/new-track", title: "Track", sourceCompositeKey: source)
        store.setHidden(true, identity: try XCTUnwrap(HiddenMediaIdentity(track)), at: start.addingTimeInterval(4))
        XCTAssertTrue(store.snapshot.isHidden(track))
        XCTAssertFalse(store.snapshot.isHidden(readded), "A re-added item with a new library ID is visible")

        store.removeMissing(kind: .track, sourceKey: source, survivingItemIDs: [readded.id])
        XCTAssertFalse(store.snapshot.isHidden(track))
    }

    /// Each row makes one change; a hide on another source follows as a
    /// sentinel, so a row that emits more (or less) than expected is caught.
    func testSnapshotStreamTransitionsAndPersistence() async throws {
        let suiteName = "HiddenMediaStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = HiddenMediaStore(defaults: defaults)
        let source = "plex:account:server:library"
        let candidates = (0..<100).map { index in
            HiddenMediaCandidate(
                identity: HiddenMediaIdentity(kind: .track, itemID: "\(index)", sourceCompositeKey: source),
                title: "Track", source: source, relatedCatalogID: "catalog-\(index)"
            )
        }
        let start = Date(timeIntervalSince1970: 100)
        let rows: [(name: String, change: () -> Void, emits: Bool)] = [
            ("batch hide", { store.setHidden(true, candidates: candidates, at: start) }, true),
            ("older unhide", { store.setHidden(false, candidates: candidates, at: start.addingTimeInterval(-1)) }, false),
            ("cleanup", { store.removeMissing(kind: .track, sourceKey: source, survivingItemIDs: ["0"]) }, true),
        ]
        var iterator = store.snapshots().makeAsyncIterator()
        _ = await iterator.next()
        for (index, row) in rows.enumerated() {
            row.change()
            let changed = store.snapshot
            if row.emits {
                let received = await iterator.next()
                XCTAssertEqual(received, changed, row.name)
            }
            store.setHidden(
                true,
                identity: HiddenMediaIdentity(kind: .album, itemID: "sentinel-\(index)", sourceCompositeKey: "other"),
                at: start
            )
            let sentinel = await iterator.next()
            XCTAssertEqual(sentinel, store.snapshot, "\(row.name) emitted unexpectedly")
        }

        XCTAssertEqual(store.snapshot.identities.filter { $0.sourceCompositeKey == source }, [candidates[0].identity])
        let reloaded = HiddenMediaStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot.identities.filter { $0.sourceCompositeKey == source }, [candidates[0].identity])
        let tombstones = reloaded.exportMutations().filter { $0.identity.sourceCompositeKey == source }
        XCTAssertEqual(tombstones.count, 100, "Unhide tombstones must survive persistence")
        XCTAssertTrue(tombstones.allSatisfy { $0.relatedCatalogID != nil })
    }

    func testMediaIdentitiesRejectEmptySourceKeys() {
        XCTAssertNil(HiddenMediaIdentity(Track(id: "track", key: "/track", title: "Track", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Album(id: "album", key: "/album", title: "Album", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Artist(id: "artist", key: "/artist", name: "Artist", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Playlist(id: "playlist", key: "/playlist", title: "Playlist", sourceCompositeKey: "")))
    }
}
