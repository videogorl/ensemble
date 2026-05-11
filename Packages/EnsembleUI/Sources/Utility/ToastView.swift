import EnsembleCore
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

public struct ToastHostView: View {
    @ObservedObject var toastCenter: ToastCenter
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat
    let onToastTap: (() -> Void)?

    public init(
        toastCenter: ToastCenter,
        horizontalPadding: CGFloat = EnsembleScaffold.Toast.hostHorizontalPadding,
        bottomPadding: CGFloat = EnsembleScaffold.Toast.hostBottomPadding,
        onToastTap: (() -> Void)? = nil
    ) {
        self.toastCenter = toastCenter
        self.horizontalPadding = horizontalPadding
        self.bottomPadding = bottomPadding
        self.onToastTap = onToastTap
    }

    public var body: some View {
        Group {
            if let toast = toastCenter.currentToast {
                ToastBannerView(
                    toast: toast,
                    toastCenter: toastCenter,
                    onToastTap: onToastTap
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
        background(
            GlobalToastWindowHost(toastCenter: toastCenter)
                .frame(
                    width: EnsembleScaffold.Toast.hiddenHostDimension,
                    height: EnsembleScaffold.Toast.hiddenHostDimension
                )
        )
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Installs a dedicated top-level toast window so toasts appear above sheets and app chrome.
public struct GlobalToastWindowHost: UIViewControllerRepresentable {
    private let toastCenter: ToastCenter

    public init(toastCenter: ToastCenter) {
        self.toastCenter = toastCenter
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
        context.coordinator.refreshRootView()

        if let probeView = uiViewController.view as? SceneProbeView {
            let coordinator = context.coordinator
            probeView.onSceneChange = { [weak coordinator] scene in
                coordinator?.attach(to: scene)
            }
        }
        context.coordinator.attach(to: uiViewController.view.window?.windowScene)
    }

    public static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class SceneProbeView: UIView {
        var onSceneChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(window?.windowScene)
        }
    }

    @MainActor
    public final class Coordinator {
        fileprivate var toastCenter: ToastCenter
        private var overlayWindow: PassthroughWindow?
        private weak var attachedScene: UIWindowScene?
        private var toastCancellable: AnyCancellable?

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
            window.isUserInteractionEnabled = toastCenter.currentToast != nil

            let host = UIHostingController(rootView: GlobalToastOverlayRootView(toastCenter: toastCenter))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false

            overlayWindow = window
            observeToastVisibility()
        }

        fileprivate func refreshRootView() {
            guard let host = overlayWindow?.rootViewController as? UIHostingController<GlobalToastOverlayRootView> else { return }
            host.rootView = GlobalToastOverlayRootView(toastCenter: toastCenter)
            overlayWindow?.isUserInteractionEnabled = toastCenter.currentToast != nil
        }

        fileprivate func detach() {
            toastCancellable = nil
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            attachedScene = nil
        }

        private func observeToastVisibility() {
            toastCancellable = toastCenter.$currentToast
                .receive(on: RunLoop.main)
                .sink { [weak self] toast in
                    self?.overlayWindow?.isUserInteractionEnabled = toast != nil
                }
        }
    }
}

private final class PassthroughWindow: UIWindow {
    private let interactiveToastBandHeight: CGFloat = 260

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard point.y >= bounds.maxY - interactiveToastBandHeight else {
            return nil
        }

        let hitView = super.hitTest(point, with: event)
        if hitView === rootViewController?.view {
            return nil
        }
        return hitView
    }
}

private struct GlobalToastOverlayRootView: View {
    @ObservedObject var toastCenter: ToastCenter

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .overlay(alignment: .bottom) {
                    ToastHostView(
                        toastCenter: toastCenter,
                        horizontalPadding: EnsembleScaffold.Toast.globalHorizontalPadding,
                        // Account for safe-area when rendering in a window that
                        // ignores safe areas so the toast stays above mini player.
                        bottomPadding: baseBottomPadding + geometry.safeAreaInsets.bottom
                    )
                }
                .ignoresSafeArea()
        }
    }

    private var baseBottomPadding: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 74 : 130
    }
}
#endif

public struct ToastBannerView: View {
    let toast: ToastPayload
    let toastCenter: ToastCenter
    let onToastTap: (() -> Void)?
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
        .contentShape(Capsule())
        .onTapGesture {
            if toast.tapHandler != nil {
                toastCenter.triggerTap(for: toast.id)
                onToastTap?()
                return
            }
            // Allow full-toast dismissal only for non-action toasts.
            guard toast.action == nil else { return }
            toastCenter.dismiss(id: toast.id)
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        accentColor
    }

    private var borderColor: Color {
        accentColor.opacity(EnsembleScaffold.Toast.borderOpacity)
    }

    private var accentColor: Color {
        settingsManager.accentColor.color
    }
}
