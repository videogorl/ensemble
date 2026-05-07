import SwiftUI

extension View {
    /// Apply .sidebarAdaptable or .automatic TabView style.
    @ViewBuilder
    func applyTabViewStyle(sidebarAdaptable: Bool) -> some View {
        #if os(iOS)
        if sidebarAdaptable {
            if #available(iOS 18.0, *) {
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

    /// Remove the sidebar toggle button on macOS where the root shell owns sidebar policy.
    @ViewBuilder
    func if_available_removeSidebarToggle() -> some View {
        #if os(macOS)
        if #available(iOS 17.0, macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
