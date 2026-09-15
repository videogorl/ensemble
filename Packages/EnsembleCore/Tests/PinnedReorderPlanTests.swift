@testable import EnsembleCore
import Testing

@Suite("Pinned reorder plan")
struct PinnedReorderPlanTests {
    @Test("Moves one or more pins before a destination and preserves source order")
    func movesPins() {
        let cases: [([String], [String], String?, [String])] = [
            (["a", "b", "c", "d"], ["b"], "d", ["a", "c", "b", "d"]),
            (["a", "b", "c", "d"], ["b", "c"], "a", ["b", "c", "a", "d"]),
            (["a", "b", "c", "d"], ["a"], nil, ["b", "c", "d", "a"]),
            (["a", "b"], ["missing"], "a", ["a", "b"])
        ]

        for (current, moving, destination, expected) in cases {
            #expect(
                PinnedReorderPlan.orderedIDs(
                    currentIDs: current,
                    movingIDs: moving,
                    before: destination
                ) == expected
            )
        }
    }
}
