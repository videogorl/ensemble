import EnsembleCore
import SwiftUI

/// Root view that renders the main content directly (no auth gate)
@available(iOS 15.0, macOS 12.0, watchOS 8.0, *)
public struct RootView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public init() {}

    public var body: some View {
        mainContentView
        #if canImport(UIKit) && !os(watchOS)
        // Global keyboard shortcut host (space = play/pause)
        .background(KeyCommandHost().frame(width: 0, height: 0))
        #endif
        .accentColor(settingsManager.accentColor.color)
        .onAppear {
            updateAppearance()
        }
        .onChange(of: settingsManager.accentColor) { _ in
            updateAppearance()
        }
        .onChange(of: settingsManager.auroraVisualizationEnabled) { _ in
            updateAppearance()
        }
        .task {
            let deps = DependencyContainer.shared
            deps.accountManager.loadAccounts()
            deps.syncCoordinator.refreshProviders()
            _ = await deps.siriMediaIndexStore.rebuildIndex()
        }
    }

    private func updateAppearance() {
        #if canImport(UIKit) && !os(watchOS)
        let navAppearance = UINavigationBarAppearance()
        let tabBarAppearance = UITabBarAppearance()

        if settingsManager.auroraVisualizationEnabled {
            // Transparent backgrounds for aurora visibility
            navAppearance.configureWithTransparentBackground()
            tabBarAppearance.configureWithTransparentBackground()
        } else {
            // Default opaque backgrounds
            navAppearance.configureWithDefaultBackground()
            tabBarAppearance.configureWithDefaultBackground()
        }

        // iOS 15 fix: scrollEdgeAppearance via appearance proxy doesn't reliably
        // apply, leaving tab bar/toolbar with no background. Explicitly set a blur
        // effect so content doesn't scroll behind chrome.
        if #available(iOS 16.0, *) {
            // iOS 16+ handles this correctly — no extra work needed
        } else {
            let bgAlpha: CGFloat = settingsManager.auroraVisualizationEnabled ? 0.3 : 0.85
            let blurStyle: UIBlurEffect.Style = .systemChromeMaterial

            // Nav bar
            navAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            navAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

            // Tab bar
            tabBarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            tabBarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)

            // Toolbar
            let toolbarAppearance = UIToolbarAppearance()
            toolbarAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)
            toolbarAppearance.backgroundColor = .systemBackground.withAlphaComponent(bgAlpha)
            UIToolbar.appearance().standardAppearance = toolbarAppearance
            UIToolbar.appearance().scrollEdgeAppearance = toolbarAppearance
        }

        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
        #endif
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
