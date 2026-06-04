import EnsembleCore
import SwiftUI
#if os(iOS)
import UIKit

/// Hosts the persistent iPad mini player in a pass-through window so native
/// split-view and navigation transitions cannot duplicate or animate its shell.
struct RootMiniPlayerWindowHost: UIViewControllerRepresentable {
    let nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let animationID: String
    let navigationCoordinator: NavigationCoordinator
    let presentNowPlaying: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let view = SceneProbeView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        controller.view = view
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.configuration = Configuration(
            nowPlayingVM: nowPlayingVM,
            layout: layout,
            accentColor: accentColor,
            animationID: animationID,
            navigationCoordinator: navigationCoordinator,
            presentNowPlaying: presentNowPlaying
        )
        context.coordinator.refreshRootView()

        if let probeView = uiViewController.view as? SceneProbeView {
            let coordinator = context.coordinator
            probeView.onSceneChange = { [weak coordinator] scene in
                coordinator?.attach(to: scene)
            }
        }
        context.coordinator.attach(to: uiViewController.view.window?.windowScene)
    }

    static func dismantleUIViewController(_ uiViewController: UIViewController, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        fileprivate var configuration: Configuration?
        private var overlayWindow: RootMiniPlayerPassthroughWindow?
        private weak var attachedScene: UIWindowScene?

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

            let window = RootMiniPlayerPassthroughWindow(windowScene: scene)
            window.backgroundColor = .clear
            window.windowLevel = .normal + 1

            let host = UIHostingController(rootView: rootView())
            host.view.backgroundColor = .clear
            window.rootViewController = host
            window.isHidden = false

            overlayWindow = window
        }

        fileprivate func refreshRootView() {
            guard let host = overlayWindow?.rootViewController as? UIHostingController<RootMiniPlayerWindowRootView> else {
                return
            }
            host.rootView = rootView()
        }

        fileprivate func detach() {
            overlayWindow?.isHidden = true
            overlayWindow?.rootViewController = nil
            overlayWindow = nil
            attachedScene = nil
        }

        private func rootView() -> RootMiniPlayerWindowRootView {
            RootMiniPlayerWindowRootView(configuration: configuration)
        }
    }

    final class SceneProbeView: UIView {
        var onSceneChange: ((UIWindowScene?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            onSceneChange?(window?.windowScene)
        }
    }
}

private struct Configuration {
    let nowPlayingVM: NowPlayingViewModel
    let layout: RootChromeLayout
    let accentColor: Color
    let animationID: String
    let navigationCoordinator: NavigationCoordinator
    let presentNowPlaying: () -> Void
}

private final class RootMiniPlayerPassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        if hitView === rootViewController?.view {
            return nil
        }
        return hitView
    }
}

private struct RootMiniPlayerWindowRootView: View {
    let configuration: Configuration?

    var body: some View {
        Color.clear
            .overlay {
                if let configuration {
                    RootMiniPlayerOverlay(
                        nowPlayingVM: configuration.nowPlayingVM,
                        layout: configuration.layout,
                        accentColor: configuration.accentColor,
                        namespace: nil,
                        animationID: configuration.animationID,
                        surfaceStyle: .stableMaterial,
                        presentNowPlaying: configuration.presentNowPlaying
                    )
                    .environmentObject(configuration.navigationCoordinator)
                }
            }
            .ignoresSafeArea()
    }
}
#endif
