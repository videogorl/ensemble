import Foundation

public enum AudioQualityPreference {
    public static let streamingQualityKey = "streamingQuality"
    public static let defaultStreamingQuality = "high"
    public static let allowStreamingOnCellularKey = "allowStreamingOnCellular"
    public static let defaultAllowStreamingOnCellular = true
    public static let cellularStreamingPolicyDidChange = Notification.Name(
        "AudioQualityPreference.cellularStreamingPolicyDidChange"
    )
    public static let downloadQualityKey = "downloadQuality"
    public static let defaultDownloadQuality = "high"

    public static func storedStreamingQuality(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: streamingQualityKey) ?? defaultStreamingQuality
    }

    public static func storedDownloadQuality(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: downloadQualityKey) ?? defaultDownloadQuality
    }

    public static func storedAllowStreamingOnCellular(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: allowStreamingOnCellularKey) != nil else {
            return defaultAllowStreamingOnCellular
        }
        return defaults.bool(forKey: allowStreamingOnCellularKey)
    }

    static func prefersStreaming(_ streamingQuality: String, overDownloadQuality downloadQuality: String) -> Bool {
        qualityRank(streamingQuality) > qualityRank(downloadQuality)
    }

    static func fileQuality(at fileURL: URL) -> String? {
        let token = fileURL.deletingPathExtension().lastPathComponent
            .split(separator: "_").last?.lowercased()
        return switch token {
        case "original", "high", "medium", "low": token
        default: nil
        }
    }

    private static func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "original": 3
        case "high": 2
        case "medium": 1
        case "low": 0
        default: 2
        }
    }
}
