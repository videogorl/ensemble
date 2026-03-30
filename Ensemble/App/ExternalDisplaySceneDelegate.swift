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
/// This does NOT conflict with iPadOS Stage Manager / extended desktop — that uses
/// the regular `windowApplication` role, which is routed to the default configuration.
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        os_log(.info, "ExternalDisplay: scene willConnectTo — setting up external display window")

        // Notify PlaybackService that screen mirroring is active so it applies
        // AirPlay latency compensation even when AVAudioSession doesn't report
        // the audio route as .airPlay (audio goes through the mirroring stream).
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
            os_log(.info, "ExternalDisplay: activeNowPlayingViewModel not yet set, creating fallback instance")
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
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        os_log(.info, "ExternalDisplay: scene disconnected — tearing down window")
        DependencyContainer.shared.playbackService.isScreenMirroringActive = false
        window = nil
    }
}
#endif
