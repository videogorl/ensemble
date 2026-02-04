import EnsembleCore
import SwiftUI

/// Root view that renders the main content directly (no auth gate)
@available(iOS 15.0, macOS 12.0, watchOS 8.0, *)
public struct RootView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    
    public init() {}

    public var body: some View {
        mainContentView
            .accentColor(settingsManager.accentColor.color)
            .task {
                let deps = DependencyContainer.shared
                deps.accountManager.loadAccounts()
                deps.syncCoordinator.refreshProviders()
            }
    }

    @ViewBuilder
    private var mainContentView: some View {
        #if os(iOS)
        if #available(iOS 16.0, *), UIDevice.current.userInterfaceIdiom == .pad {
            SidebarView()
        } else {
            MainTabView()
        }
        #elseif os(macOS)
        if #available(macOS 13.0, *) {
            SidebarView()
        } else {
            MainTabView()
        }
        #else
        MainTabView()
        #endif
    }
}
