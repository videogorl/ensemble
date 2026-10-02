import XCTest
@testable import EnsembleCore

@MainActor
final class PinManagerCommandTests: XCTestCase {
    private var savedPinnedItemsData: Data?

    override func setUp() {
        super.setUp()
        savedPinnedItemsData = UserDefaults.standard.data(forKey: "pinnedItems")
        UserDefaults.standard.removeObject(forKey: "pinnedItems")
    }

    override func tearDown() {
        if let savedPinnedItemsData {
            UserDefaults.standard.set(savedPinnedItemsData, forKey: "pinnedItems")
        } else {
            UserDefaults.standard.removeObject(forKey: "pinnedItems")
        }
        savedPinnedItemsData = nil
        super.tearDown()
    }

    func testTogglePinPinsAndUnpinsWithNoOpProtection() {
        let manager = makeEmptyManager()

        manager.togglePin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album",
            isPinned: false
        )

        XCTAssertTrue(manager.isPinned(id: "album-1", sourceKey: "plex:account:server:library"))

        manager.pin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album"
        )

        XCTAssertEqual(manager.pinnedItems.count, 1)

        manager.togglePin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album",
            isPinned: true
        )

        XCTAssertFalse(manager.isPinned(id: "album-1", sourceKey: "plex:account:server:library"))
    }

    func testBatchPinAndUnpinPreserveConstituentIdentities() {
        let manager = makeEmptyManager()

        manager.pinAll(items: [
            (id: "playlist-1", sourceKey: "plex:a:s", type: .playlist, title: "Mix"),
            (id: "playlist-2", sourceKey: "plex:b:s", type: .playlist, title: "Mix")
        ])

        XCTAssertTrue(manager.areAllPinned(identities: [
            PinnedItem.sourceScopedID(id: "playlist-1", sourceKey: "plex:a:s"),
            PinnedItem.sourceScopedID(id: "playlist-2", sourceKey: "plex:b:s")
        ]))

        manager.pinAll(items: [
            (id: "playlist-1", sourceKey: "plex:a:s", type: .playlist, title: "Mix")
        ])

        manager.unpinAll(identities: [
            PinnedItem.sourceScopedID(id: "playlist-1", sourceKey: "plex:a:s"),
            PinnedItem.sourceScopedID(id: "playlist-2", sourceKey: "plex:b:s")
        ])
        XCTAssertTrue(manager.pinnedItems.isEmpty)
    }

    func testTitleAndReorderPreservePinnedItems() {
        let manager = makeEmptyManager()

        manager.pin(id: "a", sourceKey: "src", type: .album, title: "A")
        manager.pin(id: "b", sourceKey: "src", type: .artist, title: "B")
        manager.updateTitle(id: "a", sourceKey: "src", title: "Renamed")
        manager.reorder(identities: [
            PinnedItem.sourceScopedID(id: "b", sourceKey: "src"),
            PinnedItem.sourceScopedID(id: "a", sourceKey: "src")
        ])

        XCTAssertEqual(manager.pinnedItems.map(\.id), ["b", "a"])
        XCTAssertEqual(manager.pinnedItems.last?.title, "Renamed")
    }

    private func makeEmptyManager() -> PinManager {
        let manager = PinManager()
        while let first = manager.pinnedItems.first {
            manager.unpin(identity: first.sourceScopedID)
        }
        return manager
    }
}
