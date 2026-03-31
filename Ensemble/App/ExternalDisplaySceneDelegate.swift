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

        // Compute the target content scale for high-DPI rendering.
        // External displays (especially TVs via AirPlay) report 1x native scale.
        // Our layout uses scaleEffect to scale up from a 1024×768 reference size,
        // so we need the backing store to have enough pixels for crisp text.
        let refWidth: CGFloat = 1024
        let fourThreeHeight = screenBounds.height
        let fourThreeWidth = fourThreeHeight * 4.0 / 3.0
        let layoutScale = min(fourThreeWidth / refWidth, fourThreeHeight / 768.0)
        // Use ceil(layoutScale) + 1 to ensure the backing store has a generous
        // pixel surplus over the display resolution. scaleEffect rasterizes into
        // an intermediate compositing layer; the extra pixel density ensures text
        // and SF Symbols remain crisp after the bitmap transform.
        let targetContentScale = max(screenScale, ceil(layoutScale) + 1)

        let hostingController = UIHostingController(rootView: externalView)
        hostingController.view.backgroundColor = .black

        // Wrap hosting controller in a container that overrides the trait
        // collection's displayScale. This is the primary mechanism for high-DPI
        // rendering — UITraitCollection.displayScale is what SwiftUI reads when
        // rasterizing text and SF Symbols. contentScaleFactor alone doesn't stick
        // because SwiftUI resets it during its own render pass.
        let container = HighDPIContainerController(
            child: hostingController,
            targetContentScale: targetContentScale
        )
        container.view.backgroundColor = .black

        EnsembleLogger.debug(
            "[ExternalDisplay] layoutScale=\(String(format: "%.2f", layoutScale))"
            + " targetContentScale=\(String(format: "%.1f", targetContentScale))"
        )

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = container
        window.makeKeyAndVisible()

        // Log actual trait collection after window is visible to verify override
        EnsembleLogger.debug(
            "[ExternalDisplay] post-visible hostingView.traitCollection.displayScale="
            + "\(hostingController.traitCollection.displayScale)"
            + " contentScaleFactor=\(hostingController.view.contentScaleFactor)"
        )

        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        EnsembleLogger.debug("[ExternalDisplay] scene disconnected — tearing down window")
        DependencyContainer.shared.playbackService.isScreenMirroringActive = false
        window = nil
    }
}

// MARK: - High-DPI Container Controller

/// Container view controller that overrides its child's trait collection to
/// force a high `displayScale`. This is the correct way to make SwiftUI render
/// text and SF Symbols at higher pixel density on external displays.
///
/// Why trait collection override instead of contentScaleFactor?
/// - `contentScaleFactor` is set on individual UIViews, but SwiftUI resets it
///   on its internal `_UIGraphicsView` instances during each render pass.
/// - `UITraitCollection.displayScale` propagates through the entire view
///   controller hierarchy automatically. SwiftUI reads this trait when deciding
///   the rasterization scale for text, SF Symbols, and shape rendering.
/// - `setOverrideTraitCollection(_:forChild:)` is the standard UIKit API for
///   this (iOS 13+), so it works reliably across all supported OS versions.
private class HighDPIContainerController: UIViewController {
    private let child: UIViewController
    private let targetContentScale: CGFloat

    init(child: UIViewController, targetContentScale: CGFloat) {
        self.child = child
        self.targetContentScale = targetContentScale
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        addChild(child)
        view.addSubview(child.view)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        child.didMove(toParent: self)

        // Override the child's trait collection to report high display scale
        // and dark user interface style. The displayScale propagates to all
        // SwiftUI views inside the hosting controller, causing text and SF Symbols
        // to rasterize at targetContentScale pixels per point instead of the
        // screen's native 1x. The dark style ensures the color scheme is correct
        // even though SwiftUI's preferredColorScheme(.dark) is also set — the
        // trait collection override at the VC level takes precedence.
        let highDPITraits = UITraitCollection(traitsFrom: [
            UITraitCollection(displayScale: targetContentScale),
            UITraitCollection(userInterfaceStyle: .dark),
        ])
        setOverrideTraitCollection(highDPITraits, forChild: child)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Belt-and-suspenders: also force contentScaleFactor on the UIView
        // hierarchy. The trait collection override is the primary mechanism,
        // but contentScaleFactor affects CALayer backing store resolution
        // for any custom-drawn UIKit views in the hierarchy.
        applyContentScale(to: child.view)
    }

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
