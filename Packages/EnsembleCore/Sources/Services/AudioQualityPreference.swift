import Foundation

public enum AudioQualityPreference {
    public static let streamingQualityKey = "streamingQuality"
    public static let defaultStreamingQuality = "high"
    public static let downloadQualityKey = "downloadQuality"
    public static let defaultDownloadQuality = "high"

    public static func storedStreamingQuality(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: streamingQualityKey) ?? defaultStreamingQuality
    }

    public static func storedDownloadQuality(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: downloadQualityKey) ?? defaultDownloadQuality
    }
}
