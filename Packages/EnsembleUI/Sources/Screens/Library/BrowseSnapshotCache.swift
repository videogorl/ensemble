import Combine

final class BrowseSnapshotCache<Snapshot: Equatable>: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    var snapshot: Snapshot {
        willSet {
            guard snapshot != newValue else { return }
            objectWillChange.send()
        }
    }

    init(_ snapshot: Snapshot) {
        self.snapshot = snapshot
    }
}
