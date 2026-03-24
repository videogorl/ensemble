import SwiftUI

public extension View {
    /// Standard trailing swipe actions container used across list rows.
    @ViewBuilder
    func standardTrailingSwipeActions<Actions: View>(
        allowsFullSwipe: Bool = false,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        #if os(iOS) || os(macOS)
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
            actions()
        }
        #else
        self
        #endif
    }

    /// Standard trailing destructive swipe action used across list rows.
    @ViewBuilder
    func standardDeleteSwipeAction(
        allowsFullSwipe: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        standardTrailingSwipeActions(allowsFullSwipe: allowsFullSwipe) {
            Button(role: .destructive, action: action) {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
