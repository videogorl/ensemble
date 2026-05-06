#if os(iOS)
import os
import UIKit
import EnsembleCore

extension AppDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        DependencyContainer.shared.offlineBackgroundExecutionCoordinator.handleBackgroundURLSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }

    // MARK: - Scene Will Connect (iOS 13+ scene lifecycle)

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        os_log(.info, "SIRI_APP: configurationForConnecting - activities=%{public}d, intents=%{public}d",
               options.userActivities.count,
               options.shortcutItem != nil ? 1 : 0)

        // Route external display (AirPlay screen mirroring) to dedicated scene delegate.
        // Raw string comparison for iOS 15 compatibility — the typed Swift constant
        // was only added in iOS 16, but the role string works on iOS 13+.
        // This does NOT affect iPadOS Stage Manager, which uses the windowApplication role.
        if connectingSceneSession.role.rawValue == "UIWindowSceneSessionRoleExternalDisplayNonInteractive" {
            os_log(.info, "ExternalDisplay: routing external display scene to ExternalDisplaySceneDelegate")
            let config = UISceneConfiguration(
                name: "External Display",
                sessionRole: connectingSceneSession.role
            )
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }

        // Check if there's a Siri userActivity in the connection options
        for activity in options.userActivities {
            os_log(.info, "SIRI_APP: scene connection has activity type=%{public}@", activity.activityType)
            if activity.activityType == "com.videogorl.ensemble.siri.playmedia" {
                os_log(.info, "SIRI_APP: Detected Siri playmedia activity in scene connection!")
            }
        }

        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    // NOTE: These methods are NOT called in SwiftUI lifecycle apps using @main App.
    // Background/foreground handling lives in EnsembleApp.handleScenePhaseChange()
    // via the scenePhase environment value. Keeping these as no-ops for documentation.
    func applicationDidEnterBackground(_ application: UIApplication) {}
    func applicationWillEnterForeground(_ application: UIApplication) {}

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
            cancelPendingStageFlowRotationDisable(reason: "re-registered \(change.source)")

            let hadActiveSupport = !stageFlowRotationSupportTokens.isEmpty
            let wasInserted = stageFlowRotationSupportTokens.insert(change.token).inserted
            AppLogger.debug(
                "📱 AppDelegate: StageFlow rotation registered source=\(change.source) token=\(change.token.uuidString) inserted=\(wasInserted) activeTokens=\(stageFlowRotationSupportTokens.count)"
            )

            if !hadActiveSupport {
                refreshSupportedOrientations(reason: "register \(change.source)")
            }
            return
        }

        guard stageFlowRotationSupportTokens.contains(change.token) else {
            AppLogger.debug(
                "📱 AppDelegate: Ignoring StageFlow rotation unregister for unknown token source=\(change.source) token=\(change.token.uuidString)"
            )
            return
        }

        guard stageFlowRotationSupportTokens.count == 1 else {
            stageFlowRotationSupportTokens.remove(change.token)
            AppLogger.debug(
                "📱 AppDelegate: StageFlow rotation unregistered source=\(change.source) token=\(change.token.uuidString) activeTokens=\(stageFlowRotationSupportTokens.count)"
            )
            return
        }

        scheduleStageFlowRotationDisable(for: change)
    }

    private var currentSupportedInterfaceOrientations: UIInterfaceOrientationMask {
        stageFlowRotationSupportTokens.isEmpty ? .portrait : .allButUpsideDown
    }

    private func scheduleStageFlowRotationDisable(
        for change: AppOrientationNotifications.StageFlowRotationSupportChange
    ) {
        cancelPendingStageFlowRotationDisable(reason: "rescheduled by \(change.source)")

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.stageFlowRotationSupportTokens.remove(change.token) != nil else { return }

            self.pendingStageFlowRotationDisable = nil
            AppLogger.debug(
                "📱 AppDelegate: StageFlow rotation unregistered source=\(change.source) token=\(change.token.uuidString) activeTokens=\(self.stageFlowRotationSupportTokens.count)"
            )
            self.refreshSupportedOrientations(reason: "unregister \(change.source)")
        }

        pendingStageFlowRotationDisable = (change.token, change.source, workItem)
        AppLogger.debug(
            "📱 AppDelegate: Scheduling StageFlow rotation unregister source=\(change.source) token=\(change.token.uuidString) in \(stageFlowRotationDisableDelay)s"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + stageFlowRotationDisableDelay, execute: workItem)
    }

    private func cancelPendingStageFlowRotationDisable(reason: String) {
        guard let pendingStageFlowRotationDisable else { return }

        pendingStageFlowRotationDisable.workItem.cancel()
        self.pendingStageFlowRotationDisable = nil
        AppLogger.debug(
            "📱 AppDelegate: Cancelled pending StageFlow rotation unregister source=\(pendingStageFlowRotationDisable.source) token=\(pendingStageFlowRotationDisable.token.uuidString) reason=\(reason)"
        )
    }

    private func refreshSupportedOrientations(reason: String) {
        AppLogger.debug(
            "📱 AppDelegate: Refreshing supported orientations mask=\(currentSupportedInterfaceOrientations.debugName) activeTokens=\(stageFlowRotationSupportTokens.count) reason=\(reason)"
        )
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

private extension UIInterfaceOrientationMask {
    var debugName: String {
        switch self {
        case .portrait:
            return "portrait"
        case .allButUpsideDown:
            return "allButUpsideDown"
        default:
            return "\(rawValue)"
        }
    }
}
#endif
