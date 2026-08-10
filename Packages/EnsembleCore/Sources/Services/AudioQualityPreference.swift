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

    static func prefersStreaming(_ streamingQuality: String, overDownloadQuality downloadQuality: String) -> Bool {
        qualityRank(streamingQuality) > qualityRank(downloadQuality)
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
