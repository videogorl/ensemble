import EnsembleCore
import SwiftUI
import WatchKit

@main
struct EnsembleWatchApp: App {
    init() {
        UserDefaults.standard.register(defaults: [
            "streamingQuality": "low",
            "downloadQuality": "low",
            "allowCellularDownloads": true
        ])
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(\.dependencies, DependencyContainer.shared)
        }
    }
}
