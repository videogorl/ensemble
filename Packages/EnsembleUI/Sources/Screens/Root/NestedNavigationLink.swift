import EnsembleCore
import SwiftUI

/// NavigationView fallback used by iOS 15 root tabs.
struct NestedNavigationLink: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    @ObservedObject var navigationCoordinator: NavigationCoordinator
    let destinationBuilder: (NavigationCoordinator.Destination) -> AnyView

    init(
        path: [NavigationCoordinator.Destination],
        tab: TabItem,
        navigationCoordinator: NavigationCoordinator,
        destinationBuilder: @escaping (NavigationCoordinator.Destination) -> AnyView
    ) {
        self.path = path
        self.tab = tab
        self.navigationCoordinator = navigationCoordinator
        self.destinationBuilder = destinationBuilder
    }

    var body: some View {
        let currentPath = navigationCoordinator.pathSnapshot(for: tab)
        if let first = Self.firstDestination(in: currentPath) {
            NavigationLink(
                isActive: Binding(
                    get: { !navigationCoordinator.pathSnapshot(for: tab).isEmpty },
                    set: { isActive in
                        guard !isActive else { return }
                        navigationCoordinator.popToRoot(tab: tab)
                    }
                ),
                destination: {
                    destinationBuilder(first)
                }
            ) {
                EmptyView()
            }
        }
    }

    static func firstDestination(
        in path: [NavigationCoordinator.Destination]
    ) -> NavigationCoordinator.Destination? {
        path.first
    }
}
