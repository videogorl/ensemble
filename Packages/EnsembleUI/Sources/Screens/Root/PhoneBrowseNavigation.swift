import EnsembleCore
import Foundation

/// Translates split-column roots into compact pushes without duplicating their route state.
struct PhoneBrowseNavigation {
    static func usesSidebar(size: CGSize) -> Bool {
        size.width >= 768 && size.height >= 500
    }

    private var projectedRoots: [TabItem: NavigationCoordinator.Destination] = [:]
    private var sidebarSelection: SidebarSelection?
    private var projectedSidebarRoot: NavigationCoordinator.Destination?

    @MainActor
    mutating func enterTabs(
        coordinator: NavigationCoordinator,
        selection: SidebarSelection?,
        browseRoots: [TabItem: NavigationCoordinator.Destination],
        sidebarDestination: NavigationCoordinator.Destination? = nil
    ) {
        sidebarSelection = selection
        projectedRoots = browseRoots
        projectedSidebarRoot = sidebarDestination ?? selection?.compactDestination
        if let destination = projectedSidebarRoot {
            let tab = selection?.correspondingTab ?? .settings
            projectedRoots[tab] = destination
            coordinator.selectedTab = tab
        }
        coordinator.routesHiddenTabsThroughMore = true
        for (tab, root) in projectedRoots {
            coordinator.setPath([root] + coordinator.pathSnapshot(for: tab), for: tab)
        }
    }

    @MainActor
    func enterSidebar(coordinator: NavigationCoordinator) -> (selection: SidebarSelection, clearedRoots: Set<TabItem>) {
        coordinator.routesHiddenTabsThroughMore = false
        // Restore even an inactive More stack before the compact root disappears.
        if case .view(let tab) = coordinator.settingsPath.first {
            coordinator.setPath(Array(coordinator.settingsPath.dropFirst()), for: tab)
            coordinator.settingsPath = []
            if coordinator.selectedTab == .settings { coordinator.selectedTab = tab }
        }
        var selection = SidebarSelection.library(coordinator.selectedTab)
        var clearedRoots: Set<TabItem> = []
        for (tab, root) in projectedRoots {
            let path = coordinator.pathSnapshot(for: tab)
            if path.first == root {
                coordinator.setPath(Array(path.dropFirst()), for: tab)
                if tab == coordinator.selectedTab, projectedSidebarRoot == root,
                   let sidebarSelection {
                    selection = sidebarSelection
                }
            } else {
                // The user popped or replaced this detail while compact.
                clearedRoots.insert(tab)
            }
        }
        return (selection, clearedRoots)
    }
}
