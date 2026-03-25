import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Scroll Offset Title Preference Key

/// PreferenceKey that tracks the maxY position of a title element in scroll coordinates.
/// When the title scrolls above the nav bar threshold, the toolbar title appears.
struct TitleOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// PreferenceKey that tracks the maxY position of action buttons in scroll coordinates.
/// When the buttons scroll above the threshold, toolbar action icons appear.
struct ActionButtonsOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

/// Attaches a GeometryReader background to track action buttons' position in scroll coordinates.
struct ActionButtonsOffsetTracker: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: ActionButtonsOffsetPreferenceKey.self,
                    value: geometry.frame(in: .named(coordinateSpace)).maxY
                )
        }
    }
}

// MARK: - Collapsing Toolbar Title Modifier

/// Modifier that shows a toolbar title when the inline title scrolls out of view.
/// Works on iOS 15+ using a UINavigationBar appearance configurator for transparent nav bars.
struct CollapsingToolbarTitleModifier: ViewModifier {
    let title: String
    let threshold: CGFloat  // maxY value below which toolbar title appears
    @Binding var showToolbarTitle: Bool

    private var shouldEnableCollapsingToolbarTitle: Bool {
        #if os(macOS)
        return false
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return true
        #endif
    }

    func body(content: Content) -> some View {
        Group {
            if shouldEnableCollapsingToolbarTitle {
                content
                    .onPreferenceChange(TitleOffsetPreferenceKey.self) { maxY in
                        let shouldShow = maxY < threshold
                        if shouldShow != showToolbarTitle {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showToolbarTitle = shouldShow
                            }
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Text(title)
                                .font(.headline)
                                .lineLimit(1)
                                .opacity(showToolbarTitle ? 1 : 0)
                        }
                    }
                    #if os(iOS)
                    // iOS 16+: use SwiftUI toolbarBackground (respects iOS 26 Liquid Glass)
                    .modifier(ToolbarBackgroundModifier(isTransparent: !showToolbarTitle))
                    // iOS 15 fallback: UIKit appearance configurator
                    .background(
                        NavigationBarAppearanceConfigurator(isTransparent: !showToolbarTitle)
                    )
                    #endif
            } else {
                content
                    .onAppear {
                        showToolbarTitle = false
                    }
            }
        }
    }
}

// MARK: - Title Offset Tracker

/// Attaches a GeometryReader background to track the title's position in scroll coordinates.
struct TitleOffsetTracker: View {
    let coordinateSpace: String

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: TitleOffsetPreferenceKey.self,
                    value: geometry.frame(in: .named(coordinateSpace)).maxY
                )
        }
    }
}

// MARK: - Toolbar Background Modifier (iOS 16+)

#if os(iOS)
/// Uses SwiftUI's `.toolbarBackground` API (iOS 16+) to hide/show the nav bar background.
/// On iOS 26+ this correctly suppresses the Liquid Glass bar material that the UIKit
/// appearance configurator alone cannot control.
private struct ToolbarBackgroundModifier: ViewModifier {
    let isTransparent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                .toolbarBackground(isTransparent ? .hidden : .visible, for: .navigationBar)
        } else {
            content
        }
    }
}
#endif

// MARK: - Navigation Bar Appearance Configurator (iOS)

#if os(iOS)
/// UIViewRepresentable that toggles the parent navigation bar between transparent
/// and default appearance. Compatible with iOS 15+.
struct NavigationBarAppearanceConfigurator: UIViewRepresentable {
    let isTransparent: Bool

    func makeUIView(context: Context) -> NavigationBarProbeView {
        let view = NavigationBarProbeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: NavigationBarProbeView, context: Context) {
        uiView.isTransparent = isTransparent
        // Defer to next runloop to ensure the nav controller hierarchy is available
        DispatchQueue.main.async {
            uiView.updateAppearance()
        }
    }

    /// Probe view that walks up the responder chain to find the parent UINavigationController
    final class NavigationBarProbeView: UIView {
        var isTransparent = true
        private var lastAppliedState: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                // Force transparent on first appearance
                DispatchQueue.main.async { [weak self] in
                    self?.updateAppearance()
                }
            }
        }

        func updateAppearance() {
            guard lastAppliedState != isTransparent else { return }
            lastAppliedState = isTransparent

            guard let navBar = findNavigationBar() else { return }

            if isTransparent {
                let appearance = UINavigationBarAppearance()
                appearance.configureWithTransparentBackground()
                navBar.standardAppearance = appearance
                navBar.scrollEdgeAppearance = appearance
                navBar.compactAppearance = appearance
            } else {
                let appearance = UINavigationBarAppearance()
                appearance.configureWithDefaultBackground()
                navBar.standardAppearance = appearance
                navBar.scrollEdgeAppearance = appearance
                navBar.compactAppearance = appearance
            }
        }

        /// Walk up the responder chain to find the UINavigationBar
        private func findNavigationBar() -> UINavigationBar? {
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let navController = next as? UINavigationController {
                    return navController.navigationBar
                }
                responder = next
            }
            return nil
        }

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            if newWindow == nil {
                // Restore default appearance when leaving
                restoreDefaultAppearance()
            }
        }

        private func restoreDefaultAppearance() {
            guard let navBar = findNavigationBar() else { return }
            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            lastAppliedState = nil
        }
    }
}
#endif

// MARK: - View Extension

extension View {
    /// Adds a collapsing toolbar title that appears when the inline title scrolls out of view.
    func collapsingToolbarTitle(
        _ title: String,
        threshold: CGFloat = 0,
        showToolbarTitle: Binding<Bool>
    ) -> some View {
        self.modifier(CollapsingToolbarTitleModifier(
            title: title,
            threshold: threshold,
            showToolbarTitle: showToolbarTitle
        ))
    }
}
