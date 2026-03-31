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

        // Use HighDPIHostingController to force the contentScaleFactor on all
        // subviews, ensuring text and SF Symbols render at sufficient pixel
        // density before scaleEffect upscales the view. Without this, the
        // CALayer backing store is at the screen's native 1x scale, and
        // scaleEffect produces a pixelated bitmap transform.
        let refWidth: CGFloat = 1024
        let fourThreeHeight = screenBounds.height
        let fourThreeWidth = fourThreeHeight * 4.0 / 3.0
        let layoutScale = min(fourThreeWidth / refWidth, fourThreeHeight / 768.0)
        let targetContentScale = max(screenScale, ceil(layoutScale))

        let hostingController = HighDPIHostingController(
            rootView: externalView,
            targetContentScale: targetContentScale
        )
        hostingController.view.backgroundColor = .black

        EnsembleLogger.debug(
            "[ExternalDisplay] layoutScale=\(String(format: "%.2f", layoutScale))"
            + " targetContentScale=\(String(format: "%.1f", targetContentScale))"
        )

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = hostingController
        window.makeKeyAndVisible()

        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        EnsembleLogger.debug("[ExternalDisplay] scene disconnected — tearing down window")
        DependencyContainer.shared.playbackService.isScreenMirroringActive = false
        window = nil
    }
}

// MARK: - High-DPI Hosting Controller

/// UIHostingController subclass that forces a high `contentScaleFactor` on the
/// view hierarchy. External displays (especially TVs) often report 1x scale,
/// but our layout uses `scaleEffect` to scale up from a reference iPad size.
/// Without higher contentScaleFactor, the CALayer backing store doesn't have
/// enough pixels, causing text and SF Symbols to appear pixelated.
private class HighDPIHostingController<Content: View>: UIHostingController<Content> {
    let targetContentScale: CGFloat

    init(rootView: Content, targetContentScale: CGFloat) {
        self.targetContentScale = targetContentScale
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyContentScale(to: view)
    }

    /// Recursively sets contentScaleFactor on all views in the hierarchy.
    /// SwiftUI resets contentScaleFactor to the screen's native scale when
    /// creating/recycling views, so we re-apply on every layout pass.
    private func applyContentScale(to view: UIView) {
        if view.contentScaleFactor != targetContentScale {
            view.contentScaleFactor = targetContentScale
        }
        for subview in view.subviews {
            applyContentScale(to: subview)
        }
    }
}
#endif
