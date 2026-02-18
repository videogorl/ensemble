import SwiftUI

public extension View {
    /// Conditionally apply a modifier based on a condition
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, @ViewBuilder transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func hideTabBarIfAvailable(isHidden: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.toolbar(isHidden ? .hidden : .visible, for: .tabBar)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Adds bottom spacing for the mini player/tab bar area.
    /// Uses a clear safe-area inset so content can scroll above the mini player.
    @ViewBuilder
    func miniPlayerBottomSpacing(_ height: CGFloat = 140) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: height)
            }
        } else {
            // iOS 15: avoid safeAreaInset host-preference recursion.
            // Use layout padding (not overlay) to keep this path stable.
            self.padding(.bottom, height)
        }
        #else
        self.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: height)
        }
        #endif
    }

    /// Apply a wiggle animation to the view, useful for edit modes
    func wiggle(isWiggling: Bool) -> some View {
        self.modifier(WiggleModifier(isWiggling: isWiggling))
    }
}

private struct WiggleModifier: ViewModifier {
    let isWiggling: Bool
    @State private var isAnimating = false
    
    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isWiggling ? (isAnimating ? 1.0 : -1.0) : 0))
            .offset(x: isWiggling ? (isAnimating ? 0.3 : -0.3) : 0, 
                    y: isWiggling ? (isAnimating ? -0.3 : 0.3) : 0)
            .onAppear {
                if isWiggling {
                    withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                        isAnimating = true
                    }
                }
            }
            .onChange(of: isWiggling) { newValue in
                if newValue {
                    withAnimation(.easeInOut(duration: 0.12).repeatForever(autoreverses: true)) {
                        isAnimating = true
                    }
                } else {
                    isAnimating = false
                }
            }
    }
}

public extension ToolbarItemPlacement {
    /// Returns primaryAction on macOS and navigationBarTrailing on other platforms
    static var primaryActionIfAvailable: ToolbarItemPlacement {
        #if os(macOS)
        return .primaryAction
        #else
        return .navigationBarTrailing
        #endif
    }
}
