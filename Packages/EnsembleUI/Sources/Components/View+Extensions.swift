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
    /// iOS 16+ uses safeAreaInset for scroll-behind-chrome behavior.
    /// iOS 15 uses additionalSafeAreaInsets on the nearest view controller,
    /// which propagates through NavigationView without triggering SwiftUI's
    /// host-preference recursion that safeAreaInset causes on iOS 15.
    @ViewBuilder
    func miniPlayerBottomSpacing(_ height: CGFloat = 140) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: height)
            }
        } else {
            self.background(
                AdditionalSafeAreaInsetter(bottomInset: height)
            )
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

/// Sets `additionalSafeAreaInsets.bottom` on the nearest parent view controller.
/// This is the UIKit-native way to add safe area insets — it propagates through
/// the entire child view controller hierarchy (including NavigationController
/// children) without triggering SwiftUI preference recursion.
/// Used on iOS 15 where SwiftUI's safeAreaInset causes infinite layout loops
/// in NavigationView contexts.
private struct AdditionalSafeAreaInsetter: UIViewControllerRepresentable {
    let bottomInset: CGFloat

    func makeUIViewController(context: Context) -> InsetViewController {
        InsetViewController(bottomInset: bottomInset)
    }

    func updateUIViewController(_ controller: InsetViewController, context: Context) {
        controller.updateInset(bottomInset)
    }

    /// Tiny child view controller whose only job is to set additionalSafeAreaInsets
    /// on its parent. When SwiftUI hosts this as a background, the VC is added as
    /// a child of the hosting controller, and setting additionalSafeAreaInsets on
    /// the parent propagates to all sibling content views.
    final class InsetViewController: UIViewController {
        private var bottomInset: CGFloat

        init(bottomInset: CGFloat) {
            self.bottomInset = bottomInset
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError() }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyInset()
        }

        func updateInset(_ newInset: CGFloat) {
            guard newInset != bottomInset else { return }
            bottomInset = newInset
            applyInset()
        }

        private func applyInset() {
            // Walk up to find the hosting controller that owns the content area.
            // On iOS 15, SwiftUI wraps each tab's content in a hosting controller
            // inside a UINavigationController. We want the navigation controller's
            // additionalSafeAreaInsets so all pushed views inherit the inset.
            var candidate = parent
            while let vc = candidate {
                if vc is UINavigationController || vc is UITabBarController {
                    break
                }
                candidate = vc.parent
            }

            // Fall back to direct parent if we didn't find a navigation controller
            let target = candidate ?? parent
            guard let target else { return }

            var insets = target.additionalSafeAreaInsets
            if insets.bottom != bottomInset {
                insets.bottom = bottomInset
                target.additionalSafeAreaInsets = insets
            }
        }
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
