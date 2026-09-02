import Combine

final class BrowseSnapshotCache<Snapshot>: ObservableObject {
    @Published var snapshot: Snapshot

    init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}
