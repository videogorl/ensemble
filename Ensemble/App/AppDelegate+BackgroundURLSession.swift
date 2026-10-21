#if os(iOS)
import UIKit
import EnsembleCore

extension AppDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        AppRoot.container.offlineBackgroundExecutionCoordinator.handleBackgroundURLSessionEvents(
            identifier: identifier,
            completionHandler: completionHandler
        )
    }
}
#endif
