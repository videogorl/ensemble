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
        #if DEBUG
        EnsembleLogger.debug("ℹ️ Background refresh scheduling skipped on simulator")
        #endif
        return
        #endif

        guard #available(iOS 16.0, *) else {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Background refresh scheduling skipped on iOS 15")
            #endif
            return
        }

        #if canImport(UIKit)
        guard UIApplication.shared.backgroundRefreshStatus == .available else {
            #if DEBUG
            EnsembleLogger.debug("ℹ️ Background refresh unavailable; skipping schedule")
            #endif
            return
        }
        #endif

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        
        // Request earliest execution in 15 minutes (system decides actual timing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            EnsembleLogger.debug("📅 Background refresh scheduled (earliest: \(request.earliestBeginDate?.description ?? "now"))")
            #endif
        } catch {
            #if DEBUG
            EnsembleLogger.debug("❌ Failed to schedule background refresh: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Cancel any pending background refresh
    public func cancelAppRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        #if DEBUG
        EnsembleLogger.debug("🚫 Background refresh cancelled")
        #endif
    }
}
#endif
