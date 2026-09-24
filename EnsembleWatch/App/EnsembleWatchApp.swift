import SwiftUI
import WatchKit

extension Notification.Name {
    static let ensembleWatchRemoteNowPlayingActivity = Notification.Name(
        "com.videogorl.ensemble.watch.remoteNowPlayingActivity"
    )
}

final class EnsembleWatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func handleRemoteNowPlayingActivity() {
        NotificationCenter.default.post(
            name: .ensembleWatchRemoteNowPlayingActivity,
            object: nil
        )
    }
}

@main
struct EnsembleWatchApp: App {
    @WKApplicationDelegateAdaptor(EnsembleWatchApplicationDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
