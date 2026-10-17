#if os(iOS)
import UIKit
import EnsembleCore
import EnsembleUI

extension AppDelegate {
    // MARK: - Scene Will Connect (iOS 13+ scene lifecycle)

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        AppLogger.info(
            "SIRI_APP: configurationForConnecting - activities=\(options.userActivities.count), intents=\(options.shortcutItem != nil ? 1 : 0)"
        )

        // iOS 27 uses RootView's SwiftUI scene accessory. Keep the delegate
        // route for earlier systems without overriding the accessory's scene.
        if #unavailable(iOS 27.0),
           connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            AppLogger.info("ExternalDisplay: routing external display scene to ExternalDisplaySceneDelegate")
            let config = UISceneConfiguration(
                name: "External Display",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }

        // Check if there's a Siri userActivity in the connection options
        for activity in options.userActivities {
            AppLogger.info("SIRI_APP: scene connection has activity type=\(activity.activityType)")
            if activity.activityType == "com.videogorl.ensemble.siri.playmedia" {
                AppLogger.info("SIRI_APP: Detected Siri playmedia activity in scene connection")
            }
        }

        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        currentSupportedInterfaceOrientations
    }

    @objc
    func handleStageFlowRotationSupportChanged(_ notification: Notification) {
        guard let change = notification.object as? AppOrientationNotifications.StageFlowRotationSupportChange else {
            return
        }

        if change.isEnabled {
            let hadActiveSupport = !stageFlowRotationSupportTokens.isEmpty
            stageFlowRotationSupportTokens.insert(change.token)

            if !hadActiveSupport {
                refreshSupportedOrientations()
            }
            return
        }

        guard stageFlowRotationSupportTokens.contains(change.token) else {
            return
        }

        let hadActiveSupport = !stageFlowRotationSupportTokens.isEmpty
        stageFlowRotationSupportTokens.remove(change.token)

        if hadActiveSupport && stageFlowRotationSupportTokens.isEmpty {
            refreshSupportedOrientations()
        }
    }

    private var currentSupportedInterfaceOrientations: UIInterfaceOrientationMask {
        if EnsemblePlatformFeaturePolicy.current.usesNativeBrowse {
            return .all
        }
        return stageFlowRotationSupportTokens.isEmpty ? .portrait : .allButUpsideDown
    }

    private func refreshSupportedOrientations() {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }

        UIViewController.attemptRotationToDeviceOrientation()
    }
}
#endif
