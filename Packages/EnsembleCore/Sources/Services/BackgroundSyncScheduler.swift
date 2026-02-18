import BackgroundTasks
import Foundation

#if os(iOS)
/// Manages iOS background app refresh for syncing
@available(iOS 13.0, *)
public final class BackgroundSyncScheduler {
    public static let shared = BackgroundSyncScheduler()
    
    private let taskIdentifier = "com.videogorl.ensemble.refresh"
    
    private init() {}
    
    /// Schedule the next background refresh
    /// Call this at app launch and after each background refresh completes
    public func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        
        // Request earliest execution in 15 minutes (system decides actual timing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            #if DEBUG
            print("📅 Background refresh scheduled (earliest: \(request.earliestBeginDate?.description ?? "now"))")
            #endif
        } catch {
            #if DEBUG
            print("❌ Failed to schedule background refresh: \(error.localizedDescription)")
            #endif
        }
    }
    
    /// Cancel any pending background refresh
    public func cancelAppRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        #if DEBUG
        print("🚫 Background refresh cancelled")
        #endif
    }
}
#endif
