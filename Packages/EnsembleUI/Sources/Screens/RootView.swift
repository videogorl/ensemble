import EnsembleCore
import SwiftUI

/// Root view that renders the main content directly (no auth gate)
@available(iOS 16.0, macOS 13.0, *)
public struct RootView: View {
    public init() {}

    public var body: some View {
        mainContentView
            .task {
                let deps = DependencyContainer.shared
                deps.accountManager.loadAccounts()
                await deps.syncCoordinator.refreshProviders()
                try? await deps.syncCoordinator.syncAll()
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            SidebarView()
        } else {
            MainTabView()
        }
        #elseif os(macOS)
        SidebarView()
        #else
        MainTabView()
        #endif
    }
}
