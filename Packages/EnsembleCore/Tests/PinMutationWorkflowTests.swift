import XCTest
@testable import EnsembleCore

@MainActor
final class PinMutationWorkflowTests: XCTestCase {
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
        let workflow = PinMutationWorkflow(pinManager: manager)

        let pinned = workflow.togglePin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album",
            isPinned: false
        )

        XCTAssertTrue(pinned.changed)
        XCTAssertTrue(workflow.isPinned(id: "album-1"))

        let duplicate = workflow.pin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album"
        )

        XCTAssertFalse(duplicate.changed)
        XCTAssertEqual(manager.pinnedItems.count, 1)

        let unpinned = workflow.togglePin(
            id: "album-1",
            sourceKey: "plex:account:server:library",
            type: .album,
            title: "Album",
            isPinned: true
        )

        XCTAssertTrue(unpinned.changed)
        XCTAssertFalse(workflow.isPinned(id: "album-1"))
    }

    func testBatchPinAndUnpinReportChanges() {
        let manager = makeEmptyManager()
        let workflow = PinMutationWorkflow(pinManager: manager)

        let batchPin = workflow.pinAll(items: [
            (id: "playlist-1", sourceKey: "plex:a:s", type: .playlist, title: "Mix"),
            (id: "playlist-2", sourceKey: "plex:b:s", type: .playlist, title: "Mix")
        ])

        XCTAssertTrue(batchPin.changed)
        XCTAssertTrue(workflow.areAllPinned(ids: ["playlist-1", "playlist-2"]))

        let duplicateBatch = workflow.pinAll(items: [
            (id: "playlist-1", sourceKey: "plex:a:s", type: .playlist, title: "Mix")
        ])
        XCTAssertFalse(duplicateBatch.changed)

        let batchUnpin = workflow.unpinAll(ids: ["playlist-1", "playlist-2"])
        XCTAssertTrue(batchUnpin.changed)
        XCTAssertTrue(manager.pinnedItems.isEmpty)
    }

    func testUpdateTitleAndReorderDelegateToPinManager() {
        let manager = makeEmptyManager()
        let workflow = PinMutationWorkflow(pinManager: manager)

        workflow.pin(id: "a", sourceKey: "src", type: .album, title: "A")
        workflow.pin(id: "b", sourceKey: "src", type: .artist, title: "B")
        workflow.updateTitle(id: "a", title: "Renamed")
        workflow.reorder(ids: ["b", "a"])

        XCTAssertEqual(manager.pinnedItems.map(\.id), ["b", "a"])
        XCTAssertEqual(manager.pinnedItems.last?.title, "Renamed")
    }

    private func makeEmptyManager() -> PinManager {
        let manager = PinManager()
        while let first = manager.pinnedItems.first {
            manager.unpin(id: first.id)
        }
        return manager
    }
}
