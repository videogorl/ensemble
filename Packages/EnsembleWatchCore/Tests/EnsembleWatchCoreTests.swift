import XCTest
@testable import EnsembleWatchCore

final class EnsembleWatchCoreTests: XCTestCase {
    func testLibraryFlagEntryDecodesFromAppKVSShape() throws {
        let data = """
        [{"key":"account:server:3","isEnabled":true}]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([WatchLibraryFlagEntry].self, from: data)

        XCTAssertEqual(entries, [WatchLibraryFlagEntry(key: "account:server:3", isEnabled: true)])
    }

    func testWatchCatalogStorePersistsLibraryFlagsInStableOrder() {
        let suiteName = "EnsembleWatchCoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WatchCatalogStore(defaults: defaults)

        store.saveLibraryFlags([
            "account:server:2": false,
            "account:server:1": true
        ])

        XCTAssertEqual(store.loadLibraryFlags(), [
            "account:server:1": true,
            "account:server:2": false
        ])
    }

    func testWatchSourceLibraryFlagKeyMatchesAppKVSShape() {
        XCTAssertEqual(
            WatchSourceLibraryRow.flagKey(accountId: "account", serverId: "server", libraryKey: "3"),
            "account:server:3"
        )
    }

    func testClockFormatting() {
        XCTAssertEqual(TimeInterval(65).ensembleWatchClockText, "1:05")
    }
}
