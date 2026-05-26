import EnsembleCore
import SwiftUI

/// NavigationView fallback used by iOS 15 root tabs.
struct NestedNavigationLink: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    @ObservedObject var navigationCoordinator: NavigationCoordinator
    let prefix: [NavigationCoordinator.Destination]
    let destinationBuilder: (NavigationCoordinator.Destination) -> AnyView

    init(
        path: [NavigationCoordinator.Destination],
        tab: TabItem,
        navigationCoordinator: NavigationCoordinator,
        prefix: [NavigationCoordinator.Destination] = [],
        destinationBuilder: @escaping (NavigationCoordinator.Destination) -> AnyView
    ) {
        self.path = path
        self.tab = tab
        self.navigationCoordinator = navigationCoordinator
        self.prefix = prefix
        self.destinationBuilder = destinationBuilder
    }

    var body: some View {
        let currentPath = navigationCoordinator.pathSnapshot(for: tab)
        if let next = Self.nextDestination(in: currentPath, after: prefix) {
            let activePrefix = prefix + [next]
            NavigationLink(
                isActive: Binding(
                    get: { Self.pathStarts(navigationCoordinator.pathSnapshot(for: tab), with: activePrefix) },
                    set: { isActive in
                        guard !isActive else { return }
                        navigationCoordinator.setPath(prefix, for: tab)
                    }
                ),
                destination: {
                    destinationBuilder(next)
                        .background(
                            NestedNavigationLink(
                                path: path,
                                tab: tab,
                                navigationCoordinator: navigationCoordinator,
                                prefix: activePrefix,
                                destinationBuilder: destinationBuilder
                            )
                        )
                }
            ) {
                EmptyView()
            }
        }
    }

    static func nextDestination(
        in path: [NavigationCoordinator.Destination],
        after prefix: [NavigationCoordinator.Destination]
    ) -> NavigationCoordinator.Destination? {
        guard pathStarts(path, with: prefix),
              path.count > prefix.count else {
            return nil
        }

        return path[prefix.count]
    }

    static func pathStarts(
        _ path: [NavigationCoordinator.Destination],
        with prefix: [NavigationCoordinator.Destination]
    ) -> Bool {
        guard path.count >= prefix.count else { return false }
        return Array(path.prefix(prefix.count)) == prefix
    }
}
