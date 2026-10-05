import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ToastLayout {
    var bottomLimit: CGFloat?
    var miniPlayerFrame: CGRect?
}

/// Unobstructed bottom edge and visible mini-player bounds in this scene.
struct ToastLayoutPreference: PreferenceKey {
    static let defaultValue = ToastLayout()

    static func reduce(value: inout ToastLayout, nextValue: () -> ToastLayout) {
        let next = nextValue()
        if let bottomLimit = next.bottomLimit {
            value.bottomLimit = value.bottomLimit.map { min($0, bottomLimit) } ?? bottomLimit
        }
        if let frame = next.miniPlayerFrame, !frame.isEmpty {
            value.miniPlayerFrame = frame
        }
    }
}

public struct ToastHostView: View {
    @ObservedObject var toastCenter: ToastCenter
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat

    public init(
        toastCenter: ToastCenter,
        horizontalPadding: CGFloat = EnsembleScaffold.Toast.hostHorizontalPadding,
        bottomPadding: CGFloat = EnsembleScaffold.Toast.hostBottomPadding
    ) {
        self.toastCenter = toastCenter
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
    }

    public var body: some View {
        Group {
            if let toast = toastCenter.currentToast {
                ToastBannerView(
                    toast: toast,
                    toastCenter: toastCenter
                )
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, bottomPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toastCenter.currentToast?.id)
    }
}

public extension View {
    @ViewBuilder
    func installGlobalToastWindow(toastCenter: ToastCenter) -> some View {
        #if os(iOS)
        overlayPreferenceValue(ToastLayoutPreference.self) { layout in
            GlobalToastWindowHost(toastCenter: toastCenter, bottomLimit: layout.bottomLimit)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
        #elseif os(macOS)
        overlayPreferenceValue(ToastLayoutPreference.self) { layout in
            GeometryReader { geometry in
                let rootFrame = geometry.frame(in: .global)
                GlobalToastWindowHost(
                    toastCenter: toastCenter,
                    bottomInset: layout.bottomLimit.map { max(0, rootFrame.maxY - $0) } ?? 0,
                    miniPlayerFrame: layout.miniPlayerFrame?.offsetBy(dx: -rootFrame.minX, dy: -rootFrame.minY)
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Installs a dedicated top-level toast window so toasts appear above sheets and app chrome.
public struct GlobalToastWindowHost: UIViewControllerRepresentable {
    private let toastCenter: ToastCenter
    private let bottomLimit: CGFloat?

    public init(toastCenter: ToastCenter, bottomLimit: CGFloat? = nil) {
        self.toastCenter = toastCenter
        self.bottomLimit = bottomLimit
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(toastCenter: toastCenter)
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let view = SceneProbeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        controller.view = view
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.toastCenter = toastCenter
        context.coordinator.bottomLimit = bottomLimit
        context.coordinator.contentWindow = uiViewController.view.window
        context.coordinator.refreshRootView()

        if let probeView = uiViewController.view as? SceneProbeView {
            let coordinator = context.coordinator
            probeView.onSceneChange = { [weak coordinator] window in
                coordinator?.contentWindow = window
                coordinator?.attach(to: window?.windowScene)
            }
        }
        context.coordinator.attach(to: uiViewController.view.window?.windowScene)
    }

    public static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class SceneProbeView: UIView {
        var onSceneChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(window)
        }
    }

    public final class Coordinator {
        fileprivate var toastCenter: ToastCenter
        fileprivate var bottomLimit: CGFloat?
        fileprivate weak var contentWindow: UIWindow?
        private var overlayWindow: PassthroughWindow?
        private weak var attachedScene: UIWindowScene?

        fileprivate init(toastCenter: ToastCenter) {
            self.toastCenter = toastCenter
        }

        fileprivate func attach(to scene: UIWindowScene?) {
            guard let scene else {
                detach()
                return
            }

            if attachedScene === scene, overlayWindow != nil {
                refreshRootView()
                return
            }

            detach()
            attachedScene = scene

            let window = PassthroughWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.windowLevel = .alert + 1

            let host = UIHostingController(rootView: GlobalToastOverlayRootView(toastCenter: toastCenter, bottomLimit: bottomLimit, isSheetPresented: { [weak self] in
                self?.contentWindow?.rootViewController?.presentedViewController != nil
            }) { [weak window] frame in
                window?.toastFrame = frame
            })
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false

            overlayWindow = window
        }

        fileprivate func refreshRootView() {
            guard let window = overlayWindow,
                  let host = window.rootViewController as? UIHostingController<GlobalToastOverlayRootView> else { return }
            host.rootView = GlobalToastOverlayRootView(toastCenter: toastCenter, bottomLimit: bottomLimit, isSheetPresented: { [weak self] in
                self?.contentWindow?.rootViewController?.presentedViewController != nil
            }) { [weak window] frame in
                window?.toastFrame = frame
            }
        }

        fileprivate func detach() {
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            attachedScene = nil
        }
    }
}

private final class PassthroughWindow: UIWindow {
    var toastFrame = CGRect.zero

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // SwiftUI can return its hosting root for a touch inside the banner.
        guard toastFrame.contains(point) else { return nil }
        // Consume empty padding too, rather than forwarding it to the window below.
        return super.hitTest(point, with: event) ?? self
    }
}

private struct ToastFramePreference: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}

private struct GlobalToastOverlayRootView: View {
    @ObservedObject var toastCenter: ToastCenter
    let bottomLimit: CGFloat?
    let isSheetPresented: () -> Bool
    let onToastFrameChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay(alignment: .bottom) {
                    ToastHostView(
                        toastCenter: toastCenter,
                        horizontalPadding: EnsembleScaffold.Toast.globalHorizontalPadding,
                        bottomPadding: max(
                            0,
                            isSheetPresented() ? 0 : bottomLimit.map { geometry.frame(in: .global).maxY - $0 } ?? 0
                        ) + EnsembleScaffold.Toast.hostBottomPadding
                    )
                }
        }
        .onPreferenceChange(ToastFramePreference.self, perform: onToastFrameChange)
    }

}
#endif

#if os(macOS)
/// Installs a banner-sized overlay in the scene window, or its active sheet.
public struct GlobalToastWindowHost: NSViewRepresentable {
    @ObservedObject private var toastCenter: ToastCenter
    private let bottomInset: CGFloat
    private let miniPlayerFrame: CGRect?

    public init(toastCenter: ToastCenter, bottomInset: CGFloat = 0, miniPlayerFrame: CGRect? = nil) {
        self._toastCenter = ObservedObject(wrappedValue: toastCenter)
        self.bottomInset = bottomInset
        self.miniPlayerFrame = miniPlayerFrame
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(toastCenter: toastCenter)
    }

    public func makeNSView(context: Context) -> NSView {
        SceneProbeView()
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.miniPlayerFrame = miniPlayerFrame
        context.coordinator.update(toastCenter: toastCenter, bottomInset: bottomInset)
        context.coordinator.attach(to: nsView.window)
        (nsView as? SceneProbeView)?.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private final class SceneProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    public final class Coordinator {
        fileprivate var toastCenter: ToastCenter
        fileprivate var bottomInset: CGFloat = 0
        fileprivate var miniPlayerFrame: CGRect?
        private weak var contentWindow: NSWindow?
        private weak var targetWindow: NSWindow?
        private var hostingView: NSHostingView<MacToastOverlayRootView>?
        private var observerTokens: [NSObjectProtocol] = []

        fileprivate init(toastCenter: ToastCenter) {
            self.toastCenter = toastCenter
        }

        fileprivate func update(toastCenter: ToastCenter, bottomInset: CGFloat) {
            self.toastCenter = toastCenter
            self.bottomInset = bottomInset
            refreshOverlay()
        }

        fileprivate func attach(to window: NSWindow?) {
            guard contentWindow !== window else {
                refreshOverlay()
                return
            }

            removeObservers()
            detachOverlay()
            contentWindow = window

            guard let window else { return }
            let center = NotificationCenter.default
            observerTokens = [
                center.addObserver(forName: NSWindow.willBeginSheetNotification, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.refreshOverlay() }
                },
                center.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.refreshOverlay() }
                },
                center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] notification in
                    guard let self,
                          let resizedWindow = notification.object as? NSWindow,
                          resizedWindow === self.contentWindow || resizedWindow === self.targetWindow else { return }
                    self.refreshOverlay()
                }
            ]
            let activityNotifications: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSApplication.didBecomeActiveNotification,
                NSApplication.didResignActiveNotification
            ]
            observerTokens += activityNotifications.map { name in
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.layoutOverlay() }
                }
            }
            refreshOverlay()
        }

        fileprivate func detach() {
            removeObservers()
            detachOverlay()
            contentWindow = nil
        }

        private func refreshOverlay() {
            guard let contentWindow else {
                detachOverlay()
                return
            }
            let target = activeWindow(from: contentWindow)
            guard let contentView = target.contentView else {
                detachOverlay()
                return
            }

            let width = toastWidth(in: contentView, window: target)
            if targetWindow !== target {
                hostingView?.removeFromSuperview()
                targetWindow = target
            }

            let hostingView = hostingView ?? NSHostingView(rootView: toastRootView(width: width))
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            let overlaySuperview = contentView.superview ?? contentView
            if hostingView.superview !== overlaySuperview {
                hostingView.removeFromSuperview()
                overlaySuperview.addSubview(hostingView, positioned: .above, relativeTo: nil)
            }
            self.hostingView = hostingView

            layoutOverlay()
        }

        private func toastRootView(width: CGFloat) -> MacToastOverlayRootView {
            MacToastOverlayRootView(toastCenter: toastCenter, width: width)
        }

        private func toastWidth(in contentView: NSView, window: NSWindow) -> CGFloat {
            let availableWidth = max(0, contentView.bounds.width - 2 * EnsembleScaffold.Toast.globalHorizontalPadding)
            if window === contentWindow, let miniPlayerFrame {
                return min(miniPlayerFrame.width, contentView.bounds.width)
            }
            return availableWidth
        }

        private func layoutOverlay() {
            guard let contentWindow,
                  let target = targetWindow,
                  let contentView = target.contentView,
                  let hostingView else {
                hostingView?.isHidden = true
                return
            }

            let width = toastWidth(in: contentView, window: target)
            guard width > 0, toastCenter.currentToast != nil else {
                hostingView.isHidden = true
                return
            }

            hostingView.rootView = toastRootView(width: width)
            hostingView.layoutSubtreeIfNeeded()
            let size = hostingView.fittingSize
            guard size.height > 0 else {
                hostingView.isHidden = true
                return
            }

            let isShowingSheet = target !== contentWindow
            let chromeInset = isShowingSheet ? 0 : bottomInset
            let bottomOffset = min(
                max(0, chromeInset),
                max(0, contentView.bounds.height - size.height)
            ) + EnsembleScaffold.Toast.hostBottomPadding
            let originY = contentView.isFlipped
                ? contentView.bounds.maxY - bottomOffset - size.height
                : contentView.bounds.minY + bottomOffset
            let bannerRect = NSRect(
                x: (isShowingSheet ? contentView.bounds.midX : miniPlayerFrame?.midX ?? contentView.bounds.midX) - size.width / 2,
                y: originY,
                width: size.width,
                height: size.height
            )
            let overlaySuperview = contentView.superview ?? contentView
            hostingView.frame = contentView.convert(bannerRect, to: overlaySuperview)
            hostingView.isHidden = !(target.isVisible && isActiveWindow(target))
        }

        private func activeWindow(from window: NSWindow) -> NSWindow {
            var activeWindow = window
            while let sheet = activeWindow.attachedSheet {
                activeWindow = sheet
            }
            return activeWindow
        }

        private func isActiveWindow(_ window: NSWindow) -> Bool {
            guard NSApp.isActive else { return false }
            return window === NSApp.keyWindow ||
                (window === NSApp.mainWindow && window.attachedSheet == nil)
        }

        private func detachOverlay() {
            hostingView?.removeFromSuperview()
            hostingView = nil
            targetWindow = nil
        }

        private func removeObservers() {
            observerTokens.forEach { NotificationCenter.default.removeObserver($0) }
            observerTokens.removeAll()
        }
    }
}

private struct MacToastOverlayRootView: View {
    @ObservedObject var toastCenter: ToastCenter
    let width: CGFloat

    var body: some View {
        ToastHostView(toastCenter: toastCenter, horizontalPadding: 0, bottomPadding: 0)
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif

public struct ToastBannerView: View {
    let toast: ToastPayload
    let toastCenter: ToastCenter
    @ObservedObject private var settingsManager = DependencyContainer.shared.settingsManager

    public var body: some View {
        HStack(alignment: .center, spacing: EnsembleScaffold.Toast.iconTextSpacing) {
            if toast.showsActivityIndicator {
                ProgressView()
                    .controlSize(.small)
                    .tint(iconColor)
            } else {
                Image(systemName: toast.iconSystemName)
                    .font(EnsembleDesign.Typography.toastTitle)
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: EnsembleScaffold.Toast.textSpacing) {
                Text(toast.title)
                    .font(EnsembleDesign.Typography.toastTitle)
                    .lineLimit(2)
                    .foregroundColor(EnsembleDesign.Color.primaryText)

                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(EnsembleDesign.Typography.toastMessage)
                        .lineLimit(2)
                        .foregroundColor(EnsembleDesign.Color.secondaryText)
                }
            }

            Spacer(minLength: EnsembleScaffold.Toast.trailingSpacerMinLength)

            if let action = toast.action {
                Button(action.title) {
                    toastCenter.triggerAction(for: toast.id)
                }
                .font(EnsembleDesign.Typography.toastAction)
                .foregroundColor(accentColor)
                .accessibilityIdentifier("toast.action")
            }
        }
        .padding(.horizontal, EnsembleScaffold.Toast.horizontalPadding)
        .padding(.vertical, EnsembleScaffold.Toast.verticalPadding)
        .ensembleCapsuleMaterial(.popover, strokeColor: borderColor)
        #if os(iOS)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ToastFramePreference.self,
                    value: geometry.frame(in: .global)
                )
            }
        }
        #endif
        .contentShape(Capsule())
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard Self.shouldDismiss(for: value.translation) else { return }
                    toastCenter.dismiss(id: toast.id)
                }
        )
        .onTapGesture {
            toastCenter.dismiss(id: toast.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toast.banner")
        .accessibilityAction(.escape) {
            toastCenter.dismiss(id: toast.id)
        }
    }

    static func shouldDismiss(for translation: CGSize) -> Bool {
        translation.width <= -50 && abs(translation.width) > abs(translation.height)
    }

    private var iconColor: Color {
        accentColor
    }

    private var borderColor: Color {
        accentColor.opacity(EnsembleScaffold.Toast.borderOpacity)
    }

    private var accentColor: Color {
        #if os(macOS)
        return EnsembleDesign.Color.accent
        #else
        settingsManager.accentColor.color
        #endif
    }
}
