import EnsembleCore
import SwiftUI

/// NavigationView fallback used by iOS 15 root tabs.
struct NestedNavigationLink: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    @ObservedObject var navigationCoordinator: NavigationCoordinator
    let destinationBuilder: (NavigationCoordinator.Destination) -> AnyView
    private let depth: Int

    init(
        path: [NavigationCoordinator.Destination],
        tab: TabItem,
        navigationCoordinator: NavigationCoordinator,
        destinationBuilder: @escaping (NavigationCoordinator.Destination) -> AnyView,
        depth: Int = 0
    ) {
        self.path = path
        self.tab = tab
        self.navigationCoordinator = navigationCoordinator
        self.destinationBuilder = destinationBuilder
        self.depth = depth
    }

    var body: some View {
        let currentPath = navigationCoordinator.pathSnapshot(for: tab)
        if let destination = Self.destination(in: currentPath, at: depth) {
            NavigationLink(
                isActive: Binding(
                    get: { navigationCoordinator.pathSnapshot(for: tab).count > depth },
                    set: { isActive in
                        guard !isActive else { return }
                        navigationCoordinator.setPath(
                            Self.pathAfterDeactivatingLink(at: depth, in: navigationCoordinator.pathSnapshot(for: tab)),
                            for: tab
                        )
                    }
                ),
                destination: {
                    destinationBuilder(destination)
                        .background(
                            NestedNavigationLink(
                                path: currentPath,
                                tab: tab,
                                navigationCoordinator: navigationCoordinator,
                                destinationBuilder: destinationBuilder,
                                depth: depth + 1
                            )
                        )
                }
            ) {
                EmptyView()
            }
        }
    }

    static func firstDestination(
        in path: [NavigationCoordinator.Destination]
    ) -> NavigationCoordinator.Destination? {
        destination(in: path, at: 0)
    }

    static func destination(
        in path: [NavigationCoordinator.Destination],
        at depth: Int
    ) -> NavigationCoordinator.Destination? {
        guard depth >= 0, path.indices.contains(depth) else { return nil }
        return path[depth]
    }

    static func pathAfterDeactivatingLink(
        at depth: Int,
        in path: [NavigationCoordinator.Destination]
    ) -> [NavigationCoordinator.Destination] {
        Array(path.prefix(max(depth, 0)))
    }
}
