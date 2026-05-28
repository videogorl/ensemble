import SwiftUI
#if os(iOS)
import UIKit
import ObjectiveC
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
                                .font(EnsembleDesign.Typography.toolbarTitle)
                                .lineLimit(1)
                                .opacity(showToolbarTitle ? 1 : 0)
                        }
                    }
                    #if os(iOS)
                    // iOS 16+: use SwiftUI toolbarBackground (respects iOS 26 Liquid Glass)
                    .modifier(ToolbarBackgroundModifier(isTransparent: !showToolbarTitle))
                    // iOS 15 fallback only; newer OS releases own navigation chrome natively.
                    .modifier(IOS15NavigationBarAppearanceModifier(isTransparent: !showToolbarTitle))
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

/// Applies the UIKit navigation-bar fallback only on iOS 15.
private struct IOS15NavigationBarAppearanceModifier: ViewModifier {
    let isTransparent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
        } else {
            content
                .background(
                    NavigationBarAppearanceConfigurator(isTransparent: isTransparent)
                )
        }
    }
}
#endif

// MARK: - Navigation Bar Appearance Configurator (iOS)

#if os(iOS)
/// UIKit fallback that toggles the parent navigation bar between transparent
/// and default appearance on iOS 15 only. Modern iOS uses SwiftUI's
/// `.toolbarBackground(...)` so UIKit appearance proxies do not fight native
/// navigation chrome.
struct NavigationBarAppearanceConfigurator: UIViewRepresentable {
    let isTransparent: Bool

    func makeUIView(context: Context) -> NavigationBarProbeView {
        let view = NavigationBarProbeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: NavigationBarProbeView, context: Context) {
        if #available(iOS 16.0, *) {
            return
        }
        uiView.isTransparent = isTransparent
        uiView.updateAppearance()
    }

    /// Probe view that walks up the responder chain to find the parent UINavigationController
    final class NavigationBarProbeView: UIView {
        var isTransparent = true
        private final class AppearanceOwner: NSObject {}

        private static var appearanceOwnerKey: UInt8 = 0

        private let ownerToken = AppearanceOwner()
        private weak var appliedNavigationBar: UINavigationBar?
        private var lastAppliedState: Bool?
        private var retryScheduled = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if #available(iOS 16.0, *) {
                return
            }
            if window != nil {
                updateAppearance()
            }
        }

        func updateAppearance() {
            if #available(iOS 16.0, *) {
                return
            }
            guard let navBar = findNavigationBar() else {
                scheduleAppearanceRetry()
                return
            }

            let ownsCurrentAppearance = Self.ownerToken(for: navBar) === ownerToken
            guard lastAppliedState != isTransparent || appliedNavigationBar !== navBar || !ownsCurrentAppearance else {
                return
            }

            applyAppearance(isTransparent: isTransparent, to: navBar)
        }

        private func applyAppearance(isTransparent: Bool, to navBar: UINavigationBar) {
            let appearance = UINavigationBarAppearance()
            if isTransparent {
                appearance.configureWithTransparentBackground()
            } else {
                appearance.configureWithDefaultBackground()
            }
            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            Self.setOwnerToken(ownerToken, for: navBar)
            appliedNavigationBar = navBar
            lastAppliedState = isTransparent
        }

        private func scheduleAppearanceRetry() {
            guard !retryScheduled else { return }
            retryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.retryScheduled = false
                self.updateAppearance()
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
            if #available(iOS 16.0, *) {
                return
            }
            if newWindow == nil {
                restoreDefaultAppearanceIfOwned()
            }
        }

        private func restoreDefaultAppearanceIfOwned() {
            if #available(iOS 16.0, *) {
                return
            }
            // During nested pushes, an offscreen source detail can detach after the
            // destination has already claimed transparent chrome. Only the current
            // owner may restore default chrome.
            guard let navBar = appliedNavigationBar ?? findNavigationBar(),
                  Self.ownerToken(for: navBar) === ownerToken else {
                return
            }

            let appearance = UINavigationBarAppearance()
            appearance.configureWithDefaultBackground()
            navBar.standardAppearance = appearance
            navBar.scrollEdgeAppearance = appearance
            navBar.compactAppearance = appearance
            Self.clearOwnerToken(for: navBar)
            appliedNavigationBar = nil
            lastAppliedState = nil
        }

        private static func ownerToken(for navBar: UINavigationBar) -> AppearanceOwner? {
            objc_getAssociatedObject(navBar, &appearanceOwnerKey) as? AppearanceOwner
        }

        private static func setOwnerToken(_ token: AppearanceOwner, for navBar: UINavigationBar) {
            objc_setAssociatedObject(
                navBar,
                &appearanceOwnerKey,
                token,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }

        private static func clearOwnerToken(for navBar: UINavigationBar) {
            objc_setAssociatedObject(
                navBar,
                &appearanceOwnerKey,
                nil,
                .OBJC_ASSOCIATION_ASSIGN
            )
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

    /// Keeps top-edge content visible behind platform toolbar chrome.
    func toolbarMaterialBleed(hidesTopScrollEdgeEffect: Bool = false) -> some View {
        modifier(ToolbarMaterialBleedModifier(hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect))
    }

    /// Requests the native toolbar material without making the toolbar fully transparent.
    func toolbarMaterialBackground() -> some View {
        modifier(ToolbarMaterialBackgroundModifier())
    }

    /// Keeps artwork-backed surfaces visible behind platform toolbar chrome.
    func artworkBackedToolbarBleed(hidesTopScrollEdgeEffect: Bool = false) -> some View {
        toolbarMaterialBleed(hidesTopScrollEdgeEffect: hidesTopScrollEdgeEffect)
    }

}

private struct ToolbarMaterialBackgroundModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        } else if #available(macOS 13.0, *) {
            content
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ToolbarMaterialBleedModifier: ViewModifier {
    let hidesTopScrollEdgeEffect: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            if #available(iOS 16.0, *) {
                content
                    .toolbarBackground(.hidden, for: .navigationBar)
            } else {
                content
                    .background(NavigationBarAppearanceConfigurator(isTransparent: true))
            }
        } else {
            phoneContent(content)
        }
        #elseif os(macOS)
        if #available(macOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectStyle(.automatic, for: .top)
        } else if #available(macOS 15.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else if #available(macOS 13.0, *) {
            content
                .toolbarBackground(.hidden, for: .windowToolbar)
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func phoneContent(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(hidesTopScrollEdgeEffect, for: .top)
        } else {
            content
        }
    }
    #endif
}
