import XCTest
@testable import EnsembleCore

final class CachedStringSortTests: XCTestCase {
    private struct Item: Identifiable {
        let id: String
        let title: String
    }

    func testSortedByCachedStringKeyUsesStableIDTieBreaker() {
        let items = [
            Item(id: "b", title: "Alpha"),
            Item(id: "a", title: "Alpha"),
            Item(id: "c", title: "Beta")
        ]

        XCTAssertEqual(items.sortedByCachedStringKey(\.title, ascending: true).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(items.sortedByCachedStringKey(\.title, ascending: false).map(\.id), ["c", "a", "b"])
    }
}
