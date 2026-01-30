import EnsembleCore
import EnsembleUI
import SwiftUI

@main
struct EnsembleApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            if #available(iOS 16.0, *) {
                RootView()
                    .environment(\.dependencies, DependencyContainer.shared)
            } else {
                // Fallback on earlier versions
            }
        }
    }
}
