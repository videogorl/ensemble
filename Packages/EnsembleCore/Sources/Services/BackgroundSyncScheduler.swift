import BackgroundTasks
import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if os(iOS)
/// Manages iOS background app refresh for syncing
@available(iOS 13.0, *)
public final class BackgroundSyncScheduler {
    public static let shared = BackgroundSyncScheduler()
    
    private let taskIdentifier = "com.videogorl.ensemble.refresh"
    
    private init() {}
    
    /// Schedule the next background refresh
    /// Call this at app launch and after each background refresh completes.
    /// Must be called from the main thread (reads UIApplication.backgroundRefreshStatus).
    @MainActor
    public func scheduleAppRefresh() {
        #if targetEnvironment(simulator)
        EnsembleLogger.debug("ℹ️ Background refresh scheduling skipped on simulator")
        return
        #endif

        guard #available(iOS 16.0, *) else {
            EnsembleLogger.debug("ℹ️ Background refresh scheduling skipped on iOS 15")
            return
        }

        #if canImport(UIKit)
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            EnsembleLogger.debug("ℹ️ Background refresh unavailable; skipping schedule")
            return
        }
        #endif

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        
        // Request earliest execution in 15 minutes (system decides actual timing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            EnsembleLogger.debug("📅 Background refresh scheduled (earliest: \(request.earliestBeginDate?.description ?? "now"))")
        } catch {
            EnsembleLogger.debug("❌ Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }
    
    /// Cancel any pending background refresh
    public func cancelAppRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        EnsembleLogger.debug("🚫 Background refresh cancelled")
    }
}
#endif
