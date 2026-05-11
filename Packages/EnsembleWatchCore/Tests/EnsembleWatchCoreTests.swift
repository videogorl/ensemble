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

    func testClockFormatting() {
        XCTAssertEqual(TimeInterval(65).ensembleWatchClockText, "1:05")
    }
}
