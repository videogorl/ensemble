#if os(iOS)
import UIKit
import EnsembleCore

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

        // Route external display (AirPlay screen mirroring) to dedicated scene delegate.
        // Raw string comparison for iOS 15 compatibility — the typed Swift constant
        // was only added in iOS 16, but the role string works on iOS 13+.
        // This does NOT affect iPadOS Stage Manager, which uses the windowApplication role.
        if connectingSceneSession.role.rawValue == "UIWindowSceneSessionRoleExternalDisplayNonInteractive" {
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
        stageFlowRotationSupportTokens.isEmpty ? .portrait : .allButUpsideDown
    }

    private func refreshSupportedOrientations() {
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                if #available(iOS 16.0, *) {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }

        UIViewController.attemptRotationToDeviceOrientation()
    }
}
#endif
