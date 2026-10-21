import XCTest

/// Waits for main-actor state to satisfy `condition`, for tests of
/// `@Observable` models that no longer expose Combine publishers.
@MainActor
func waitUntil(
    timeout: TimeInterval = 1,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Condition not met within \(timeout)s", file: file, line: line)
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
