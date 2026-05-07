import EnsembleCore
import SwiftUI

/// Recursive NavigationView fallback used by iOS 15 root tabs.
struct NestedNavigationLink<DestinationView: View>: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    let navigationCoordinator: NavigationCoordinator
    let destinationBuilder: (NavigationCoordinator.Destination) -> DestinationView

    var body: some View {
        if let first = path.first {
            NavigationLink(
                isActive: Binding(
                    get: { !path.isEmpty },
                    set: { if !$0 { navigationCoordinator.popToRoot(tab: tab) } }
                ),
                destination: {
                    destinationBuilder(first)
                        .background(
                            NestedNavigationLink(
                                path: Array(path.dropFirst()),
                                tab: tab,
                                navigationCoordinator: navigationCoordinator,
                                destinationBuilder: destinationBuilder
                            )
                        )
                }
            ) {
                EmptyView()
            }
        }
    }
}
