import Observation

/// A section's committed browse value, observed independently of other sections.
@MainActor
@Observable
public final class BrowseSnapshotCache<Snapshot: Equatable> {
    public private(set) var snapshot: Snapshot

    init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    func update(_ snapshot: Snapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}
