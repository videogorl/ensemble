#if os(macOS)
import AppKit
import EnsembleCore
import SwiftUI

private struct MacBrowsePickerKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MacBrowseSidebarToggleKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var isMacBrowsePicker: Bool {
        get { self[MacBrowsePickerKey.self] }
        set { self[MacBrowsePickerKey.self] = newValue }
    }

    var toggleMacBrowseSidebar: () -> Void {
        get { self[MacBrowseSidebarToggleKey.self] }
        set { self[MacBrowseSidebarToggleKey.self] = newValue }
    }
}

/// AppKit owns the panes so changing the section never replaces the sidebar.
@available(macOS 15.0, *)
struct MacBrowseSplitView<Sidebar: View, Picker: View, Detail: View>: NSViewControllerRepresentable {
    let sidebar: Sidebar
    let picker: Picker
    let detail: Detail
    let showsPicker: Bool
    let sidebarFrameChanged: (CGRect?) -> Void
    @EnvironmentObject private var navigationCoordinator: NavigationCoordinator
    @EnvironmentObject private var sourceActionPresenter: MediaSourceActionPresenter

    func makeNSViewController(context: Context) -> Controller {
        let controller = Controller()
        updateNSViewController(controller, context: context)
        return controller
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        // The root supplies the available size; measuring all pane constraints
        // can feed toolbar and search changes back into SwiftUI's layout pass.
        proposal.replacingUnspecifiedDimensions()
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.loadViewIfNeeded()
        controller.sidebarFrameChanged = sidebarFrameChanged
        let environment = context.environment
        controller.sidebar.rootView = pane(sidebar, environment: environment)
        controller.picker.rootView = pane(picker.environment(\.isMacBrowsePicker, true), environment: environment)
        controller.detail.rootView = pane(detail.environment(\.toggleMacBrowseSidebar, { [weak controller] in
            controller?.toggleSidebar(nil)
        }), environment: environment)
        let collapsesPicker = !showsPicker
        if controller.pickerItem.isCollapsed != collapsesPicker {
            controller.pickerItem.isCollapsed = collapsesPicker
        }
    }

    private func pane<Content: View>(_ content: Content, environment: EnvironmentValues) -> AnyView {
        // Each host is a new SwiftUI root. Copy app context explicitly; forwarding
        // the parent's whole environment also copies private toolbar/search state
        // and can feed the bridged window state back into itself.
        AnyView(content
            .environmentObject(navigationCoordinator)
            .environmentObject(sourceActionPresenter)
            .environment(\.dependencies, environment.dependencies)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.scenePhase, environment.scenePhase)
            .environment(\.openURL, environment.openURL)
            .environment(\.isViewportNowPlayingPresented, environment.isViewportNowPlayingPresented)
            .environment(\.dismissViewportNowPlaying, environment.dismissViewportNowPlaying)
            .environment(\.isSoftwareKeyboardVisible, environment.isSoftwareKeyboardVisible)
            .environment(\.artworkDetailBackgroundContinuity, environment.artworkDetailBackgroundContinuity)
            .environment(\.artistDetailArtworkContinuity, environment.artistDetailArtworkContinuity)
            .environment(\.mediaNavigationTransitionNamespace, environment.mediaNavigationTransitionNamespace)
            .environment(\.nativeBrowseScrollPosition, environment.nativeBrowseScrollPosition)
            .tint(environment.dependencies.settingsManager.accentColor.color))
    }

    @MainActor
    final class Controller: NSSplitViewController {
        let sidebar = NSHostingController(rootView: AnyView(EmptyView()))
        let picker = NSHostingController(rootView: AnyView(EmptyView()))
        let detail = NSHostingController(rootView: AnyView(EmptyView()))
        private(set) var pickerItem: NSSplitViewItem!
        var sidebarFrameChanged: ((CGRect?) -> Void)?
        private var lastSidebarFrame: CGRect?
        private var isSidebarPublicationPending = false

        override func viewDidLoad() {
            super.viewDidLoad()
            splitView.isVertical = true
            // Each pane is sized by its split item, not SwiftUI's ideal content size.
            for host in [sidebar, picker, detail] {
                host.sizingOptions = []
                host.sceneBridgingOptions = []
            }
            // Exactly one host owns the window title, search and toolbar.
            detail.sceneBridgingOptions = [.title, .toolbars]
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
            sidebarItem.minimumThickness = RootSidebarColumnWidth.minimum
            sidebarItem.maximumThickness = RootSidebarColumnWidth.maximum
            sidebarItem.preferredThicknessFraction = 0.22
            pickerItem = NSSplitViewItem(contentListWithViewController: picker)
            pickerItem.minimumThickness = 240
            pickerItem.maximumThickness = 360
            pickerItem.isCollapsed = true
            let detailItem = NSSplitViewItem(viewController: detail)
            detailItem.minimumThickness = 240
            addSplitViewItem(sidebarItem)
            addSplitViewItem(pickerItem)
            addSplitViewItem(detailItem)
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            let frame: CGRect? = splitViewItems[0].isCollapsed ? nil : sidebar.view.frame
            guard frame != lastSidebarFrame else { return }
            lastSidebarFrame = frame
            guard !isSidebarPublicationPending else { return }
            isSidebarPublicationPending = true
            // Native layout can run inside a representable update. Publish the
            // latest geometry after that transaction, without reentering SwiftUI.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSidebarPublicationPending = false
                self.sidebarFrameChanged?(self.lastSidebarFrame)
            }
        }
    }
}

struct MacBrowseSidebarToggle: View {
    @Environment(\.toggleMacBrowseSidebar) private var toggle

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "sidebar.left")
        }
        .help("Toggle Sidebar")
        .accessibilityLabel("Toggle Sidebar")
        .keyboardShortcut("s", modifiers: [.command, .control])
    }
}

#endif
