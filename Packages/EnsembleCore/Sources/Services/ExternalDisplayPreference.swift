import Foundation

/// Device-local choice between a dedicated Now Playing view and plain screen
/// mirroring on a mirrored display. Stored in `UserDefaults` only; never synced.
public enum ExternalDisplayPreference {
    public static let nowPlayingEnabledKey = "externalDisplayNowPlayingEnabled"
    public static let defaultNowPlayingEnabled = true

    public static func storedNowPlayingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: nowPlayingEnabledKey) != nil else {
            return defaultNowPlayingEnabled
        }
        return defaults.bool(forKey: nowPlayingEnabledKey)
    }
}
