@testable import EnsembleCore
import XCTest

final class PinManagerSyncTests: XCTestCase {

    @MainActor
    func testApplyRemotePinsReplacesLocalSnapshot() {
        let manager = PinManager()

        // Clear any leftover pins
        while !manager.pinnedItems.isEmpty {
            manager.unpin(id: manager.pinnedItems[0].id)
        }

        // Add local pins
        manager.pin(id: "local1", sourceKey: "src1", type: .album, title: "Local Album")
        manager.pin(id: "shared", sourceKey: "src1", type: .artist, title: "Shared Artist Local")

        // Remote pins
        let remotePins = [
            PinnedItem(id: "remote1", sourceCompositeKey: "src1", type: .playlist, title: "Remote Playlist"),
            PinnedItem(id: "shared", sourceCompositeKey: "src1", type: .artist, title: "Shared Artist Remote")
        ]

        manager.applyRemotePins(remotePins)

        XCTAssertEqual(manager.pinnedItems.count, 2)
        XCTAssertEqual(manager.pinnedItems[0].id, "remote1")
        XCTAssertEqual(manager.pinnedItems[1].id, "shared")
        XCTAssertEqual(manager.pinnedItems[1].title, "Shared Artist Remote", "Remote should win on conflict")
    }

    @MainActor
    func testExportPinsDataRoundTrips() {
        let manager = PinManager()

        // Clear
        while !manager.pinnedItems.isEmpty {
            manager.unpin(id: manager.pinnedItems[0].id)
        }

        manager.pin(id: "a1", sourceKey: "src1", type: .album, title: "Album One")
        manager.pin(id: "a2", sourceKey: "src2", type: .artist, title: "Artist Two")

        guard let data = manager.exportPinsData() else {
            XCTFail("Export should produce data")
            return
        }

        let decoded = try? JSONDecoder().decode([PinnedItem].self, from: data)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(decoded?[0].id, "a1")
        XCTAssertEqual(decoded?[1].id, "a2")
    }

    @MainActor
    func testApplyEmptyRemotePinsClearsLocalPins() {
        let manager = PinManager()

        while !manager.pinnedItems.isEmpty {
            manager.unpin(id: manager.pinnedItems[0].id)
        }

        manager.pin(id: "local1", sourceKey: "src1", type: .album, title: "Local")

        manager.applyRemotePins([])

        XCTAssertTrue(manager.pinnedItems.isEmpty)
    }

    @MainActor
    func testUpdateTitleChangesPinnedDisplayName() {
        let manager = PinManager()

        while !manager.pinnedItems.isEmpty {
            manager.unpin(id: manager.pinnedItems[0].id)
        }

        manager.pin(id: "playlist-1", sourceKey: "src1", type: .playlist, title: "Old Title")
        manager.updateTitle(id: "playlist-1", title: "New Title")

        XCTAssertEqual(manager.pinnedItems.first?.title, "New Title")
    }
}
