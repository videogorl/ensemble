import EnsembleCore
import SwiftUI
import WatchKit

@main
struct EnsembleWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(\.dependencies, DependencyContainer.shared)
        }
    }
}
