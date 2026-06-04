import SwiftUI
import EnsembleCore

@MainActor
public extension NavigationCoordinator {
    func pathBinding(for tab: TabItem) -> Binding<[Destination]> {
        Binding(
            get: { self.pathSnapshot(for: tab) },
            set: { self.setPath($0, for: tab) }
        )
    }
}
