import SwiftUI

// MARK: - Generic Swipe Helpers

public extension View {
    /// Standard trailing destructive swipe action used across list rows.
    @ViewBuilder
    func standardDeleteSwipeAction(
        allowsFullSwipe: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        #if os(iOS) || os(macOS)
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
            Button(role: .destructive, action: action) {
                Label("Delete", systemImage: EnsembleDesign.Icon.delete)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - ClearScrollContentBackgroundModifier

/// Removes the default opaque background from List/ScrollView on macOS 13+ / iOS 16+.
/// Falls through on older OS versions where scrollContentBackground is unavailable.
struct ClearScrollContentBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, iOS 16.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
