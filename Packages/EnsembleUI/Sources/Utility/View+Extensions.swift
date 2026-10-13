import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

private struct ViewportNowPlayingPresentedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct DismissViewportNowPlayingKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private struct LargeScreenBrowseDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

private struct StageFlowActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MediaNavigationTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var mediaNavigationTransitionNamespace: Namespace.ID? {
        get { self[MediaNavigationTransitionNamespaceKey.self] }
        set { self[MediaNavigationTransitionNamespaceKey.self] = newValue }
    }
}

public extension EnvironmentValues {
    var isViewportNowPlayingPresented: Bool {
        get { self[ViewportNowPlayingPresentedKey.self] }
        set { self[ViewportNowPlayingPresentedKey.self] = newValue }
    }

    var dismissViewportNowPlaying: (() -> Void)? {
        get { self[DismissViewportNowPlayingKey.self] }
        set { self[DismissViewportNowPlayingKey.self] = newValue }
    }

    var isInLargeScreenBrowseDetailPane: Bool {
        get { self[LargeScreenBrowseDetailPaneKey.self] }
        set { self[LargeScreenBrowseDetailPaneKey.self] = newValue }
    }

    var isStageFlowActive: Bool {
        get { self[StageFlowActiveKey.self] }
        set { self[StageFlowActiveKey.self] = newValue }
    }
}

private struct MediaNavigationTransitionSourceModifier: ViewModifier {
    @Environment(\.mediaNavigationTransitionNamespace) private var namespace
    let id: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *), let namespace, let id {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    func mediaNavigationTransitionSource(id: String?) -> some View {
        modifier(MediaNavigationTransitionSourceModifier(id: id))
    }
}

/// Applies aurora background transparency in dark mode only.
/// In light mode the system grouped background is preserved so list row
/// backgrounds remain visible against the near-white aurora backdrop.
private struct AuroraBackgroundSupportModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(colorScheme == .dark ? .hidden : .visible)
            .background(Color.clear)
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
    
    /// Enables/disables StageFlow landscape rotation support from the root shell.
    @ViewBuilder
    func stageFlowRotationSupport(isEnabled: Bool) -> some View {
        #if os(iOS)
        self.modifier(StageFlowRotationSupportModifier(isEnabled: isEnabled))
        #else
        self
        #endif
    }

    /// Adds bottom spacing for the mini player/tab bar area so content can
    /// scroll clear of the floating player overlay.
    func miniPlayerBottomSpacing(_ height: CGFloat = TrackListLayoutMetrics.miniPlayerBottomSpacing) -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: height)
        }
    }

    /// Measures the native tab bar's window-bottom clearance.
    @ViewBuilder
    func tabBarBottomClearanceProbe(_ tabBarBottomClearance: Binding<CGFloat>) -> some View {
        #if os(iOS)
        self.background(
            TabBarBottomClearanceProbe(tabBarBottomClearance: tabBarBottomClearance)
        )
        #else
        self
        #endif
    }

    /// Makes the view's background transparent so the aurora visualization shows through.
    /// In dark mode, hides the scroll content background so list rows are visible against
    /// the dark aurora. In light mode, keeps the system background — the aurora backdrop
    /// is near-white and hiding it would make list row backgrounds invisible.
    func auroraBackgroundSupport() -> some View {
        self.modifier(AuroraBackgroundSupportModifier())
    }

    /// Removes default macOS button bezel chrome when the control already draws
    /// its own capsule/circle/background styling.
    @ViewBuilder
    func chromelessMediaControlButton() -> some View {
        #if os(macOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// Keeps custom menu labels from picking up bordered macOS pull-down styling.
    @ViewBuilder
    func chromelessMediaControlMenu() -> some View {
        #if os(macOS)
        self.menuStyle(BorderlessButtonMenuStyle())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct StageFlowRotationSupportModifier: ViewModifier {
    let isEnabled: Bool
    @State private var token = UUID()
    @State private var isRegistered = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                updateRotationSupport(isEnabled)
            }
            .onChange(of: isEnabled) { enabled in
                updateRotationSupport(enabled)
            }
            .onDisappear {
                updateRotationSupport(false)
            }
    }

    private func updateRotationSupport(_ isEnabled: Bool) {
        guard isRegistered != isEnabled else { return }

        isRegistered = isEnabled
        NotificationCenter.default.post(
            name: AppOrientationNotifications.stageFlowRotationSupportChanged,
            object: AppOrientationNotifications.StageFlowRotationSupportChange(
                token: token,
                isEnabled: isEnabled
            )
        )
    }
}

/// Finds SwiftUI's native tab bar to report its window-bottom clearance.
///
/// The responder chain walk (bottom-up) doesn't work because the probe view
/// sits in a SwiftUI hosting context that's a sibling of the tab bar controller,
/// not a descendant. So we search downward from window.rootViewController instead.
///
/// Uses UIViewRepresentable (not UIViewControllerRepresentable) to avoid
/// inserting a child VC that could cause layout feedback loops.
private struct TabBarBottomClearanceProbe: UIViewRepresentable {
    let tabBarBottomClearance: Binding<CGFloat>

    func makeUIView(context: Context) -> InsetProbeView {
        let view = InsetProbeView()
        view.bottomClearanceDidChange = { tabBarBottomClearance.wrappedValue = $0 }
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: InsetProbeView, context: Context) {
        view.bottomClearanceDidChange = { tabBarBottomClearance.wrappedValue = $0 }
        view.applyInsets()
    }

    final class InsetProbeView: UIView {
        var bottomClearanceDidChange: ((CGFloat) -> Void)?
        private var reportedBottomClearance: CGFloat = -1

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyInsets()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyInsets()
        }

        func applyInsets() {
            guard let window = self.window else { return }

            guard let tabBarController = Self.findTabBarController(from: window.rootViewController) else {
                EnsembleLogger.debug("[MiniPlayerInset] No UITabBarController found in VC hierarchy")
                return
            }

            let tabBar = tabBarController.tabBar
            let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
            // The root suppresses the mini player during StageFlow. UIKit can still
            // report a hidden tab bar while restoring its correct portrait frame.
            let bottomClearance = max(window.bounds.maxY - tabBarFrame.minY, 0)
            if abs(bottomClearance - reportedBottomClearance) > 0.5 {
                reportedBottomClearance = bottomClearance
                bottomClearanceDidChange?(bottomClearance)
            }
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

public extension ToolbarItemPlacement {
    /// Keeps action toolbar items in the platform's normal trailing action cluster.
    static var primaryActionIfAvailable: ToolbarItemPlacement {
        #if os(macOS)
        return .primaryAction
        #else
        return .navigationBarTrailing
        #endif
    }
}

extension View {
    /// Hosts short sheet content in the platform's native navigation container.
    @ViewBuilder
    func nativeSheetNavigationContainer() -> some View {
        NavigationStack {
            self
        }
    }

    /// Applies the editor toolbar role on macOS so primary actions land on
    /// the trailing edge instead of clustering beside the sidebar/title area.
    @ViewBuilder
    func macEditorToolbarRoleIfAvailable() -> some View {
        #if os(macOS)
        self.toolbarRole(.editor)
        #else
        self
        #endif
    }

    /// Marks content hosted as the detail pane inside the app's large-screen
    /// browse split so shared toolbar placement can avoid standalone-only spacers.
    func largeScreenBrowseDetailPane(_ isActive: Bool = true) -> some View {
        environment(\.isInLargeScreenBrowseDetailPane, isActive)
    }
}
