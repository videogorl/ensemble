import SwiftUI

extension View {
    /// Apply .sidebarAdaptable or .automatic TabView style.
    @ViewBuilder
    func applyTabViewStyle(sidebarAdaptable: Bool, prefersSidebar: Bool) -> some View {
        #if os(iOS)
        if sidebarAdaptable {
            if #available(iOS 27.0, *) {
                tabViewStyle(.sidebarAdaptable)
                    .defaultTabBarPlacement(prefersSidebar ? .sidebar : .tabBar)
            } else if #available(iOS 18.0, *) {
                tabViewStyle(.sidebarAdaptable)
            } else {
                tabViewStyle(.automatic)
            }
        } else {
            tabViewStyle(.automatic)
        }
        #else
        tabViewStyle(.automatic)
        #endif
    }
}

extension View {
    @ViewBuilder
    func adaptiveTabChrome(isSelected: Bool, showsMiniPlayer: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 27.0, *) {
            background {
                if isSelected {
                    // Native tab content already excludes the sidebar and tab bar.
                    RootChromeFrameRegistrationView(
                        bottomPadding: TrackListLayoutMetrics.miniPlayerAdditionalBottomPadding,
                        showsMiniPlayer: showsMiniPlayer,
                        priority: 100,
                        ownsContentFrame: true
                    )
                }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
