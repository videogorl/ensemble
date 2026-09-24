import XCTest
@testable import EnsembleCore

final class CachedStringSortTests: XCTestCase {
    private struct Item: Identifiable {
        let id: String
        let title: String
        let count: Int
    }

    func testSortedByCachedStringKeyUsesStableIDTieBreaker() {
        let items = [
            Item(id: "b", title: "Alpha", count: 1),
            Item(id: "a", title: "Alpha", count: 1),
            Item(id: "c", title: "Beta", count: 2)
        ]

        XCTAssertEqual(items.sortedByCachedStringKey(\.title, ascending: true).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(items.sortedByCachedStringKey(\.title, ascending: false).map(\.id), ["c", "a", "b"])
    }

    func testSortedByComparableKeyUsesStableIDTieBreaker() {
        let items = [
            Item(id: "b", title: "Beta", count: 1),
            Item(id: "a", title: "Alpha", count: 1),
            Item(id: "c", title: "Gamma", count: 2)
        ]

        XCTAssertEqual(items.sortedByComparableKey(\.count, ascending: true).map(\.id), ["a", "b", "c"])
        XCTAssertEqual(items.sortedByComparableKey(\.count, ascending: false).map(\.id), ["c", "a", "b"])
    }
}
