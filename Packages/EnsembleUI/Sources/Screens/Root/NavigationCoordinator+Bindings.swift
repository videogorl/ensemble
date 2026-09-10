import SwiftUI
import EnsembleCore

@MainActor
public extension NavigationCoordinator {
    func pathBinding(for tab: TabItem, isActive: @escaping () -> Bool = { true }) -> Binding<[Destination]> {
        Binding(
            get: { self.pathSnapshot(for: tab) },
            set: { path in
                guard isActive() else { return }
                self.setPath(path, for: tab)
            }
        )
    }
}
