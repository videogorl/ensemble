import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
import ObjectiveC
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
        private final class ScrollInsetState: NSObject {
            var baseContentInset: UIEdgeInsets
            var baseIndicatorInset: UIEdgeInsets
            var requestedBottomInsets: [UUID: CGFloat] = [:]

            init(baseContentInset: UIEdgeInsets, baseIndicatorInset: UIEdgeInsets) {
                self.baseContentInset = baseContentInset
                self.baseIndicatorInset = baseIndicatorInset
            }
        }

        private static var insetStateKey: UInt8 = 0

        private let token = UUID()
        var bottomInset: CGFloat
        weak var scrollView: UIScrollView?

        init(bottomInset: CGFloat) {
            self.bottomInset = bottomInset
        }

        func attachAndApply(from view: UIView) {
            guard let foundScrollView = findScrollView(from: view) else { return }

            if scrollView !== foundScrollView {
                restore()
                scrollView = foundScrollView
            }

            apply()
        }

        private func apply() {
            guard let scrollView else { return }

            let state = insetState(for: scrollView)
            state.requestedBottomInsets[token] = bottomInset

            let requestedBottomInset = state.requestedBottomInsets.values.max() ?? 0

            var contentInset = scrollView.contentInset
            contentInset.bottom = max(state.baseContentInset.bottom, requestedBottomInset)
            if scrollView.contentInset != contentInset {
                scrollView.contentInset = contentInset
            }

            var indicatorInset = scrollView.verticalScrollIndicatorInsets
            indicatorInset.bottom = max(state.baseIndicatorInset.bottom, requestedBottomInset)
            if scrollView.verticalScrollIndicatorInsets != indicatorInset {
                scrollView.verticalScrollIndicatorInsets = indicatorInset
            }
        }

        func restore() {
            guard let scrollView else { return }

            guard let state = objc_getAssociatedObject(
                scrollView,
                &Self.insetStateKey
            ) as? ScrollInsetState else {
                self.scrollView = nil
                return
            }

            state.requestedBottomInsets.removeValue(forKey: token)

            if state.requestedBottomInsets.isEmpty {
                scrollView.contentInset = state.baseContentInset
                scrollView.verticalScrollIndicatorInsets = state.baseIndicatorInset
                objc_setAssociatedObject(
                    scrollView,
                    &Self.insetStateKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            } else {
                let requestedBottomInset = state.requestedBottomInsets.values.max() ?? 0
                var contentInset = scrollView.contentInset
                contentInset.bottom = max(state.baseContentInset.bottom, requestedBottomInset)
                scrollView.contentInset = contentInset

                var indicatorInset = scrollView.verticalScrollIndicatorInsets
                indicatorInset.bottom = max(state.baseIndicatorInset.bottom, requestedBottomInset)
                scrollView.verticalScrollIndicatorInsets = indicatorInset
            }

            self.scrollView = nil
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

            // Fallback: choose the scroll view that best overlaps this view in window space.
            guard let window = view.window else { return nil }
            let scrollViews = allScrollViews(in: window)
            guard !scrollViews.isEmpty else { return nil }

            let targetFrame = view.convert(view.bounds, to: window)
            if !targetFrame.isEmpty {
                let best = scrollViews.max { lhs, rhs in
                    let lhsArea = intersectionArea(
                        lhs.convert(lhs.bounds, to: window),
                        targetFrame
                    )
                    let rhsArea = intersectionArea(
                        rhs.convert(rhs.bounds, to: window),
                        targetFrame
                    )
                    return lhsArea < rhsArea
                }
                if let best, intersectionArea(best.convert(best.bounds, to: window), targetFrame) > 0 {
                    return best
                }
            }

            return scrollViews.first
        }

        private func allScrollViews(in root: UIView) -> [UIScrollView] {
            var results: [UIScrollView] = []
            if let scrollView = root as? UIScrollView {
                results.append(scrollView)
            }
            for child in root.subviews {
                results.append(contentsOf: allScrollViews(in: child))
            }
            return results
        }

        private func intersectionArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
            let intersection = a.intersection(b)
            guard !intersection.isNull, !intersection.isEmpty else { return 0 }
            return intersection.width * intersection.height
        }

        private func insetState(for scrollView: UIScrollView) -> ScrollInsetState {
            if let existing = objc_getAssociatedObject(
                scrollView,
                &Self.insetStateKey
            ) as? ScrollInsetState {
                return existing
            }

            let created = ScrollInsetState(
                baseContentInset: scrollView.contentInset,
                baseIndicatorInset: scrollView.verticalScrollIndicatorInsets
            )
            objc_setAssociatedObject(
                scrollView,
                &Self.insetStateKey,
                created,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
            return created
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
