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
    /// iOS 15 is a no-op here — the inset is applied once at the container
    /// level via `miniPlayerContainerInset()` in MainTabView, which sets
    /// additionalSafeAreaInsets on the TabView's hosting controller.
    @ViewBuilder
    func miniPlayerBottomSpacing(_ height: CGFloat = 140) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: height)
            }
        } else {
            // No-op on iOS 15: container-level additionalSafeAreaInsets
            // handles this via miniPlayerContainerInset() in MainTabView
            self
        }
        #else
        self.safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: height)
        }
        #endif
    }

    /// Applies additionalSafeAreaInsets.bottom to the TabView container on iOS 15.
    /// Applied once in MainTabView — propagates to all child navigation controllers
    /// and their content, including pushed views. This is the Apple Music approach:
    /// the mini player controller manages the inset, not each content view.
    @ViewBuilder
    func miniPlayerContainerInset(_ height: CGFloat, isVisible: Bool) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            // iOS 16+ uses per-view safeAreaInset, no container inset needed
            self
        } else {
            self.background(
                MiniPlayerContainerInsetter(bottomInset: isVisible ? height : 0)
            )
        }
        #else
        self
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

/// Applied once as a background on the TabView container in MainTabView.
/// Searches the window's view controller hierarchy (top-down) for the
/// UITabBarController backing SwiftUI's TabView, then sets
/// additionalSafeAreaInsets.bottom on each child navigation controller.
/// This propagates to all pushed views, matching how Apple Music handles
/// mini player insets.
///
/// The responder chain walk (bottom-up) doesn't work because the probe view
/// sits in a SwiftUI hosting context that's a sibling of the tab bar controller,
/// not a descendant. So we search downward from window.rootViewController instead.
///
/// Uses UIViewRepresentable (not UIViewControllerRepresentable) to avoid
/// inserting a child VC that could cause layout feedback loops.
private struct MiniPlayerContainerInsetter: UIViewRepresentable {
    let bottomInset: CGFloat

    func makeUIView(context: Context) -> InsetProbeView {
        let view = InsetProbeView()
        view.bottomInset = bottomInset
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ view: InsetProbeView, context: Context) {
        view.bottomInset = bottomInset
        view.applyInsets()
    }

    final class InsetProbeView: UIView {
        var bottomInset: CGFloat = 0
        private var appliedInset: CGFloat = -1

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Defer to next runloop to ensure the VC hierarchy is fully set up
            DispatchQueue.main.async { [weak self] in
                self?.applyInsets()
            }
        }

        func applyInsets() {
            guard let window = self.window else { return }

            guard let tabBarController = Self.findTabBarController(from: window.rootViewController) else {
                #if DEBUG
                NSLog("[MiniPlayerInset] No UITabBarController found in VC hierarchy")
                #endif
                return
            }

            // Set additionalSafeAreaInsets on ALL direct children of the UITabBarController.
            // These are UIHostingControllers that SwiftUI creates for each tab — they exist
            // for ALL tabs from the start, even unvisited ones. The insets propagate down
            // through to NavigationView's UINavigationController and its content.
            //
            // Also set on any UINavigationControllers found deeper in the hierarchy for
            // tabs that have been visited (handles pushed views that inherit the inset).
            var appliedCount = 0
            for child in tabBarController.children {
                // Set on the tab's hosting controller (covers all tabs including unvisited)
                if child.additionalSafeAreaInsets.bottom != bottomInset {
                    var insets = child.additionalSafeAreaInsets
                    insets.bottom = bottomInset
                    child.additionalSafeAreaInsets = insets
                    appliedCount += 1
                }
            }

            #if DEBUG
            if bottomInset != appliedInset {
                NSLog("[MiniPlayerInset] Applied %.0fpt inset to %d/%d tab children",
                      bottomInset, appliedCount, tabBarController.children.count)
            }
            #endif
            appliedInset = bottomInset
        }

        /// Recursively search the view controller hierarchy for a UITabBarController
        private static func findTabBarController(from vc: UIViewController?) -> UITabBarController? {
            guard let vc else { return nil }
            if let tbc = vc as? UITabBarController { return tbc }
            for child in vc.children {
                if let found = findTabBarController(from: child) { return found }
            }
            if let presented = vc.presentedViewController {
                return findTabBarController(from: presented)
            }
            return nil
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
