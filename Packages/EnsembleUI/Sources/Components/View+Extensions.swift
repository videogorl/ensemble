import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Applies aurora background transparency in dark mode only.
/// In light mode the system grouped background is preserved so list row
/// backgrounds remain visible against the near-white aurora backdrop.
private struct AuroraBackgroundSupportModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if colorScheme == .dark {
            if #available(iOS 16.0, macOS 13.0, *) {
                content
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
            } else {
                content.background(Color.clear)
            }
        } else {
            // Light mode: keep system backgrounds so list rows are distinguishable
            content.background(Color.clear)
        }
    }
}

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
    
    /// Conditionally applies a view modifier if both optional values are non-nil
    /// Used for namespace-based matched geometry effects
    @ViewBuilder
    func ifLet<V, ID, T: View>(_ value: V?, _ id: ID?, transform: (Self, V, ID) -> T) -> some View {
        if let value = value, let id = id {
            transform(self, value, id)
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

    /// Enables/disables landscape rotation support while this view is active.
    @ViewBuilder
    func coverFlowRotationSupport(isEnabled: Bool) -> some View {
        #if os(iOS)
        self.modifier(CoverFlowRotationSupportModifier(isEnabled: isEnabled))
        #else
        self
        #endif
    }

    /// Adds bottom spacing for the mini player/tab bar area.
    /// Uses safeAreaInset on all platforms so scrollable content can scroll
    /// past the mini player overlay without getting clipped.
    @ViewBuilder
    func miniPlayerBottomSpacing(_ height: CGFloat = 140) -> some View {
        self.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: height)
        }
    }

    /// Apply a wiggle animation to the view, useful for edit modes
    func wiggle(isWiggling: Bool) -> some View {
        self.modifier(WiggleModifier(isWiggling: isWiggling))
    }

    /// Makes the view's background transparent so the aurora visualization shows through.
    /// In dark mode, hides the scroll content background so list rows are visible against
    /// the dark aurora. In light mode, keeps the system background — the aurora backdrop
    /// is near-white and hiding it would make list row backgrounds invisible.
    func auroraBackgroundSupport() -> some View {
        self.modifier(AuroraBackgroundSupportModifier())
    }
}

#if os(iOS)
private struct CoverFlowRotationSupportModifier: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .onAppear {
                postRotationSupport(isEnabled)
            }
            .onChange(of: isEnabled) { enabled in
                postRotationSupport(enabled)
            }
            .onDisappear {
                postRotationSupport(false)
            }
    }

    private func postRotationSupport(_ isEnabled: Bool) {
        NotificationCenter.default.post(
            name: AppOrientationNotifications.coverFlowRotationSupportChanged,
            object: isEnabled
        )
    }
}

#endif

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
