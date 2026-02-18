import SwiftUI
#if os(iOS)
import UIKit
#endif

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
    /// iOS 16+ uses safe-area insets. iOS 15 uses a UIKit scroll inset
    /// bridge to preserve native "scroll behind chrome" behavior without
    /// triggering SwiftUI host-preference recursion.
    @ViewBuilder
    func miniPlayerBottomSpacing(_ height: CGFloat = 140) -> some View {
        #if os(iOS)
        if #available(iOS 16.0, *) {
            self.safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: height)
            }
        } else {
            self.background(
                LegacyScrollBottomInsetApplier(bottomInset: height)
                    .frame(width: 0, height: 0)
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
}

#if os(iOS)
/// Applies a bottom content inset directly to the nearest UIKit scroll view.
/// This keeps scrolling behavior native on iOS 15 while avoiding SwiftUI
/// preference recursion from safeAreaInset in complex navigation stacks.
private struct LegacyScrollBottomInsetApplier: UIViewRepresentable {
    let bottomInset: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(bottomInset: bottomInset)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.bottomInset = bottomInset
        DispatchQueue.main.async {
            context.coordinator.attachAndApply(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.restore()
    }

    final class Coordinator {
        var bottomInset: CGFloat
        weak var scrollView: UIScrollView?
        private var baseContentInset: UIEdgeInsets?
        private var baseIndicatorInset: UIEdgeInsets?

        init(bottomInset: CGFloat) {
            self.bottomInset = bottomInset
        }

        func attachAndApply(from view: UIView) {
            guard let foundScrollView = findScrollView(from: view) else { return }

            if scrollView !== foundScrollView {
                restore()
                scrollView = foundScrollView
                baseContentInset = foundScrollView.contentInset
                baseIndicatorInset = foundScrollView.verticalScrollIndicatorInsets
            }

            apply()
        }

        private func apply() {
            guard let scrollView else { return }

            let baselineContentInset = baseContentInset ?? scrollView.contentInset
            var contentInset = scrollView.contentInset
            contentInset.bottom = max(baselineContentInset.bottom, bottomInset)
            if scrollView.contentInset != contentInset {
                scrollView.contentInset = contentInset
            }

            let baselineIndicatorInset = baseIndicatorInset ?? scrollView.verticalScrollIndicatorInsets
            var indicatorInset = scrollView.verticalScrollIndicatorInsets
            indicatorInset.bottom = max(baselineIndicatorInset.bottom, bottomInset)
            if scrollView.verticalScrollIndicatorInsets != indicatorInset {
                scrollView.verticalScrollIndicatorInsets = indicatorInset
            }
        }

        func restore() {
            guard let scrollView else { return }
            if let baseContentInset {
                scrollView.contentInset = baseContentInset
            }
            if let baseIndicatorInset {
                scrollView.verticalScrollIndicatorInsets = baseIndicatorInset
            }
            self.scrollView = nil
            self.baseContentInset = nil
            self.baseIndicatorInset = nil
        }

        private func findScrollView(from view: UIView) -> UIScrollView? {
            // Prefer ancestor traversal first (works when attached directly to a ScrollView).
            var current: UIView? = view
            while let node = current {
                if let scrollView = node as? UIScrollView {
                    return scrollView
                }
                current = node.superview
            }

            // Fallback for wrappers where the representable is outside the actual scroll view.
            let searchRoot = view.window ?? view.superview
            guard let searchRoot else { return nil }
            return firstScrollView(in: searchRoot)
        }

        private func firstScrollView(in root: UIView) -> UIScrollView? {
            if let scrollView = root as? UIScrollView {
                return scrollView
            }
            for child in root.subviews {
                if let found = firstScrollView(in: child) {
                    return found
                }
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
