import Combine

/// A section's committed browse value, observed independently of other sections.
@MainActor
public final class BrowseSnapshotCache<Snapshot: Equatable>: ObservableObject {
    @Published public private(set) var snapshot: Snapshot

    init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    func update(_ snapshot: Snapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}
