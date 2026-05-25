import EnsembleCore
import SwiftUI

/// NavigationView fallback used by iOS 15 root tabs.
struct NestedNavigationLink: View {
    let path: [NavigationCoordinator.Destination]
    let tab: TabItem
    let navigationCoordinator: NavigationCoordinator
    let destinationBuilder: (NavigationCoordinator.Destination) -> AnyView

    var body: some View {
        if let first = path.first {
            NavigationLink(
                isActive: Binding(
                    get: { !path.isEmpty },
                    set: { if !$0 { navigationCoordinator.popToRoot(tab: tab) } }
                ),
                destination: {
                    destinationBuilder(first)
                }
            ) {
                EmptyView()
            }
        }
    }
}
