#if os(iOS)
import EnsembleCore
import EnsembleUI
import os
import SwiftUI
import UIKit

/// Scene delegate for the external display (AirPlay screen mirroring).
///
/// When the user activates Screen Mirroring from Control Center, iOS creates a
/// `UIWindowSceneSessionRoleExternalDisplayNonInteractive` scene. This delegate
/// hosts a dedicated Now Playing view on the TV via `UIHostingController`.
///
/// On iPadOS with a wired display in "Extend" mode, the system also creates this
/// scene. We detect wired displays and skip window creation so the extended
/// desktop is not replaced by our view.
///
/// ## Rendering strategy
///
/// The SwiftUI view lays out at a 1024×768 reference size (iPad proportions)
/// and uses `scaleEffect` to fill the 4:3 container on the TV. SwiftUI renders
/// Metal drawables at `UIScreen.scale` (1x for AirPlay TVs), so some elements
/// with compositing boundaries may appear slightly soft after scaling — this is
/// a SwiftUI platform limitation, not something we can override via trait
/// collection or contentScaleFactor (both were tried and reverted).
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

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

        // Detect wired external displays (USB-C, HDMI) vs AirPlay.
        // Wired displays expose multiple screen modes for different resolutions.
        // AirPlay virtual screens typically have exactly 1 mode (the negotiated resolution).
        // On iPadOS with Stage Manager, wired displays are used as extended desktops —
        // don't replace the extended desktop with our Now Playing view.
        // NOTE: UIScreen.mirrored is unreliable for this (returns non-nil even in
        // extend mode on iPadOS 26).
        let isLikelyWiredDisplay = modeCount > 1

        if isLikelyWiredDisplay {
            EnsembleLogger.debug(
                "[ExternalDisplay] Wired display detected (\(modeCount) modes)"
                + " — skipping custom view to preserve extended desktop"
            )
            return
        }

        EnsembleLogger.debug("[ExternalDisplay] AirPlay mirroring detected — setting up Now Playing window")

        // Tell PlaybackService that screen mirroring is active so it suppresses
        // AirPlay latency compensation. During mirroring, AVAudioSession reports
        // .airPlay but the mirroring protocol syncs A/V together — no separate
        // audio pipeline delay exists. Without this, lyrics lag by ~2s.
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
        DependencyContainer.shared.playbackService.isScreenMirroringActive = false
        window = nil
    }
}
#endif
