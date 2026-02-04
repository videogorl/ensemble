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
            RootView()
                .environment(\.dependencies, DependencyContainer.shared)
        }
    }
}
