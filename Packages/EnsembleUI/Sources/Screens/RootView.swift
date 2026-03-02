import EnsembleCore
import SwiftUI

/// Root view that renders the main content directly (no auth gate)
@available(iOS 15.0, macOS 12.0, watchOS 8.0, *)
public struct RootView: View {
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager
    private let playbackService = DependencyContainer.shared.playbackService

    public init() {}

    public var body: some View {
        ZStack {
            // Layer 0: Aurora visualization (behind everything)
            if settingsManager.auroraVisualizationEnabled {
                AuroraVisualizationView(
                    playbackService: playbackService,
                    accentColor: settingsManager.accentColor.color
                )
                .zIndex(0)
            }

            // Layer 1: Main content (tabs, navigation)
            mainContentView
                .zIndex(1)
        }
        .accentColor(settingsManager.accentColor.color)
        .onAppear {
            updateAppearance()
        }
        .onChange(of: settingsManager.accentColor) { _ in
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
        #if canImport(UIKit)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()

        // Use default system title colors — accent color is applied via
        // .accentColor() modifier and only affects interactive elements

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
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
