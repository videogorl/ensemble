import Combine
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

    func testBatchPublishesOnceAndPersistsUnhideTombstones() throws {
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
        var publications = 0
        let observation = store.$snapshot.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let start = Date(timeIntervalSince1970: 100)
        store.setHidden(true, candidates: candidates, at: start)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(store.snapshot.identities, Set(candidates.map(\.identity)))
        store.setHidden(false, candidates: candidates, at: start.addingTimeInterval(-1))
        XCTAssertEqual(publications, 1, "Older changes must not overwrite the batch")
        store.removeMissing(kind: .track, sourceKey: source, survivingItemIDs: ["0"])
        XCTAssertEqual(publications, 2, "Cleanup is also a single batch")
        let reloaded = HiddenMediaStore(defaults: defaults)
        XCTAssertEqual(reloaded.snapshot.identities, [candidates[0].identity])
        XCTAssertEqual(reloaded.exportMutations().count, 100, "Unhide tombstones must survive persistence")
        XCTAssertTrue(reloaded.exportMutations().allSatisfy { $0.relatedCatalogID != nil })
    }

    func testMediaIdentitiesRejectEmptySourceKeys() {
        XCTAssertNil(HiddenMediaIdentity(Track(id: "track", key: "/track", title: "Track", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Album(id: "album", key: "/album", title: "Album", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Artist(id: "artist", key: "/artist", name: "Artist", sourceCompositeKey: "")))
        XCTAssertNil(HiddenMediaIdentity(Playlist(id: "playlist", key: "/playlist", title: "Playlist", sourceCompositeKey: "")))
    }
}
