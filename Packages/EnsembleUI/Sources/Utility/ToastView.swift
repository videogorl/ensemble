import EnsembleDesignTokens
import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Lowest unobstructed point in this scene, measured by the root chrome and mini-player.
struct ToastBottomLimitPreference: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = value.map { min($0, next) } ?? next
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
        overlayPreferenceValue(ToastBottomLimitPreference.self) { bottomLimit in
            GlobalToastWindowHost(toastCenter: toastCenter, bottomLimit: bottomLimit)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
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
