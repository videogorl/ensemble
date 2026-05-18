import Foundation

enum PlaybackStreamCacheIdentity {
    private static let separator = "__"
    private static let legacySeparator: Character = "_"

    static var streamCacheDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EnsembleStreamCache", isDirectory: true)
    }

    static func fileName(for identity: String, suffix: String = String(UUID().uuidString.prefix(8)), pathExtension: String) -> String {
        "\(filePrefix(for: identity))\(separator)\(suffix).\(pathExtension)"
    }

    static func shouldKeep(fileName: String, keepIdentities: Set<String>) -> Bool {
        guard let filePrefix = cachePrefix(from: fileName) else { return false }

        let keepPrefixes = Set(keepIdentities.map(filePrefix(for:)))
        if keepPrefixes.contains(filePrefix) { return true }

        // Legacy stream-cache files were named with the bare rating key. Keep them
        // when the current playback neighborhood contains the same rating key.
        let legacyRatingKeys = Set(keepIdentities.map(legacyRatingKey(for:)))
        return legacyRatingKeys.contains(filePrefix)
    }

    static func filePrefix(for identity: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-."))
        return identity.addingPercentEncoding(withAllowedCharacters: allowed) ?? legacyRatingKey(for: identity)
    }

    private static func cachePrefix(from fileName: String) -> String? {
        if let range = fileName.range(of: separator) {
            return String(fileName[..<range.lowerBound])
        }

        guard let separatorIndex = fileName.firstIndex(of: legacySeparator) else { return nil }
        return String(fileName[..<separatorIndex])
    }

    private static func legacyRatingKey(for identity: String) -> String {
        identity.components(separatedBy: "||").last ?? identity
    }
}
