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
}
