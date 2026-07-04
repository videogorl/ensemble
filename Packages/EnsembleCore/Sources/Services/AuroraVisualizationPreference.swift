import Foundation

public enum AuroraVisualizationPreference {
    public static let enabledKey = "auroraVisualizationEnabled"
    public static let defaultEnabled = true

    public static func storedEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}
