import XCTest
@testable import EnsemblePlex

final class EnsemblePlexTests: XCTestCase {
    func testSourceKeyIncludesAccountServerAndLibrary() {
        XCTAssertEqual(
            EnsemblePlexSourceKey.build(accountId: "a", serverId: "s", libraryKey: "3"),
            "plex:a:s:3"
        )
    }
}
