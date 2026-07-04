import Foundation

public enum DownloadSettingsPreference {
    public static let allowCellularDownloadsKey = "allowCellularDownloads"
    public static let defaultAllowCellularDownloads = false

    public static func storedAllowCellularDownloads(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: allowCellularDownloadsKey) != nil else {
            return defaultAllowCellularDownloads
        }
        return defaults.bool(forKey: allowCellularDownloadsKey)
    }
}
