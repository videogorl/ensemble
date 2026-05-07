#if os(iOS)
import UIKit
import EnsembleCore

extension AppDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        AppLogger.debug("📱 AppDelegate: Registered for remote notifications")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        AppLogger.debug("📱 AppDelegate: Remote notification registration failed: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let didHandle = await DependencyContainer.shared.cloudSyncService.handleRemoteNotification(userInfo: userInfo)
            completionHandler(didHandle ? .newData : .noData)
        }
    }
}
#endif
