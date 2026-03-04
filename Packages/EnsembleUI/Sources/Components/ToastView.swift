import EnsembleCore
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
        horizontalPadding: CGFloat = 16,
        bottomPadding: CGFloat = 16,
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: toastCenter.currentToast?.id)
    }
}

public extension View {
    @ViewBuilder
    func installGlobalToastWindow(toastCenter: ToastCenter) -> some View {
        #if os(iOS)
        background(
            GlobalToastWindowHost(toastCenter: toastCenter)
                .frame(width: 0, height: 0)
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
        controller.view.isHidden = true
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.toastCenter = toastCenter
        context.coordinator.refreshRootView()

        DispatchQueue.main.async {
            context.coordinator.attach(to: uiViewController.view.window?.windowScene)
        }
    }

    public static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    public final class Coordinator {
        fileprivate var toastCenter: ToastCenter
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

            let host = UIHostingController(rootView: GlobalToastOverlayRootView(toastCenter: toastCenter))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false

            overlayWindow = window
        }

        fileprivate func refreshRootView() {
            guard let host = overlayWindow?.rootViewController as? UIHostingController<GlobalToastOverlayRootView> else { return }
            host.rootView = GlobalToastOverlayRootView(toastCenter: toastCenter)
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
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
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
                        horizontalPadding: 16,
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
        HStack(alignment: .center, spacing: 10) {
            if toast.showsActivityIndicator {
                ProgressView()
                    .controlSize(.small)
                    .tint(iconColor)
            } else {
                Image(systemName: toast.iconSystemName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(iconColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let action = toast.action {
                Button(action.title) {
                    toastCenter.triggerAction(for: toast.id)
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        accentColor.opacity(0.4)
    }

    private var accentColor: Color {
        settingsManager.accentColor.color
    }
}
