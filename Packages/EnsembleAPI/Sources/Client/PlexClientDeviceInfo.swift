import Foundation

#if os(iOS)
import UIKit
#endif

/// Provides Plex client identity values without forcing API actors to touch
/// main-actor UIKit properties from nonisolated initializers.
enum PlexClientDeviceInfo {
    static var platformName: String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "Unknown"
        #endif
    }

    static func defaultDeviceName() -> String {
        #if os(iOS)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                UIDevice.current.name
            }
        }
        return "iOS Device"
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(watchOS)
        return "Apple Watch"
        #else
        return "Unknown Device"
        #endif
    }
}
