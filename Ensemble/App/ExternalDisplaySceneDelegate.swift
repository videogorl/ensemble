#if os(iOS)
import EnsembleCore
import EnsembleUI
import SwiftUI
import UIKit

/// Scene delegate for a noninteractive supplementary display.
///
/// When the user activates Screen Mirroring from Control Center, iOS creates a
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene. This delegate
/// hosts a dedicated Now Playing view on the TV via `UIHostingController`.
///
/// Interactive extended-desktop windows use the application scene role and
/// remain owned by the normal root shell. This scene uses the shared wide
/// Now Playing layout at the external window's available size.
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard session.role.rawValue == "UIWindowSceneSessionRoleExternalDisplayNonInteractive",
              let windowScene = scene as? UIWindowScene else { return }

        let externalScreen = windowScene.screen
        let screenBounds = externalScreen.bounds
        let screenScale = externalScreen.scale
        let mirroredScreen = externalScreen.mirrored
        let modeCount = externalScreen.availableModes.count

        // Log diagnostics using EnsembleLogger so they appear in session logs
        EnsembleLogger.debug(
            "[ExternalDisplay] scene willConnectTo"
            + " | role=\(session.role.rawValue)"
            + " | bounds=\(Int(screenBounds.width))x\(Int(screenBounds.height))"
            + " | scale=\(screenScale)"
            + " | mirrored=\(mirroredScreen != nil ? "non-nil" : "nil")"
            + " | availableModes=\(modeCount)"
        )

        // Log each available screen mode for debugging
        for (i, mode) in externalScreen.availableModes.enumerated() {
            EnsembleLogger.debug(
                "[ExternalDisplay]   mode[\(i)]: \(Int(mode.size.width))x\(Int(mode.size.height))"
                + " pixelAspectRatio=\(mode.pixelAspectRatio)"
            )
        }

        // Log all connected scenes for context
        let allScenes = UIApplication.shared.connectedScenes
        for connectedScene in allScenes {
            if let ws = connectedScene as? UIWindowScene {
                EnsembleLogger.debug(
                    "[ExternalDisplay] connectedScene"
                    + " role=\(ws.session.role.rawValue)"
                    + " bounds=\(Int(ws.screen.bounds.width))x\(Int(ws.screen.bounds.height))"
                )
            }
        }

        EnsembleLogger.debug("[ExternalDisplay] Noninteractive external scene — setting up Now Playing window")

        // Preserve the existing supplementary-display timing policy. Actual
        // AirPlay latency compensation still requires hardware verification.
        DependencyContainer.shared.playbackService.isScreenMirroringActive = true

        // Use the shared NowPlayingViewModel from the main UI so playback state,
        // lyrics, queue, and panel selection stay in sync automatically.
        // Falls back to a new instance if the main UI hasn't loaded yet —
        // the new VM still shows correct playback state via PlaybackService publishers,
        // only currentPage won't sync (defaults to Queue).
        let viewModel: NowPlayingViewModel
        if let shared = DependencyContainer.shared.activeNowPlayingViewModel {
            viewModel = shared
        } else {
            EnsembleLogger.debug("[ExternalDisplay] activeNowPlayingViewModel not yet set, creating fallback instance")
            viewModel = DependencyContainer.shared.makeNowPlayingViewModel()
        }

        let externalView = ExternalDisplayNowPlayingView(viewModel: viewModel)
            .environment(\.dependencies, DependencyContainer.shared)

        let hostingController = UIHostingController(rootView: externalView)
        hostingController.view.backgroundColor = .black

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()

        self.window = window

        EnsembleLogger.debug(
            "[ExternalDisplay] window visible"
            + " | screenScale=\(screenScale)"
            + " | bounds=\(Int(screenBounds.width))x\(Int(screenBounds.height))"
        )
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        EnsembleLogger.debug("[ExternalDisplay] scene disconnected — tearing down window")
        DependencyContainer.shared.playbackService.isScreenMirroringActive = UIApplication.shared.connectedScenes.contains {
            $0 !== scene && $0.session.role.rawValue == "UIWindowSceneSessionRoleExternalDisplayNonInteractive"
        }
        window = nil
    }
}
#endif
