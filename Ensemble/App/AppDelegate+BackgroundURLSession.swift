#if os(iOS)
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
}
#endif
