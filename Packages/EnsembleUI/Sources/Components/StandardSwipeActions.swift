import SwiftUI

public extension View {
    /// Standard trailing destructive swipe action used across list rows.
    @ViewBuilder
    func standardDeleteSwipeAction(
        allowsFullSwipe: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        swipeActions(edge: .trailing, allowsFullSwipe: allowsFullSwipe) {
            Button(role: .destructive, action: action) {
                Label("Delete", systemImage: "trash")
            }
        }
        #else
        self
        #endif
    }
}
