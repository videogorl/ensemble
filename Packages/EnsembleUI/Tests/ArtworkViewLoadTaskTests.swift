import XCTest
@testable import EnsembleUI

final class ArtworkViewLoadTaskTests: XCTestCase {
    /// A re-signed URL keeps `loadID` stable. A view with no image runs its load again when the raw path
    /// changes, so a failed load recovers from a refreshed URL; a view that shows its image does not reload.
    func testLoadTaskReRunsForANewPathOnlyWhileUnresolved() {
        func id(_ path: String?, resolved: Bool, token: Int = 0) -> String {
            ArtworkView.loadTaskID(loadID: "stable", invalidationToken: token, rawPath: path, isResolved: resolved)
        }
        XCTAssertNotEqual(id("https://x/a?X-Amz-Signature=1", resolved: false), id("https://x/a?X-Amz-Signature=2", resolved: false))
        XCTAssertEqual(id("https://x/a?X-Amz-Signature=1", resolved: true), id("https://x/a?X-Amz-Signature=2", resolved: true))
        XCTAssertNotEqual(id("https://x/a", resolved: true, token: 0), id("https://x/a", resolved: true, token: 1))
        XCTAssertEqual(id(nil, resolved: false), id("", resolved: false))
    }
}
