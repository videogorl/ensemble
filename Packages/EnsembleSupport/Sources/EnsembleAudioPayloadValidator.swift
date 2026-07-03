import Foundation

/// Shared checks for audio downloads that actually contain server error bodies.
public enum EnsembleAudioPayloadValidator {
    public static func isClearlyInvalidLeadingText(
        _ data: Data,
        rejectingServiceUnavailable: Bool = false
    ) -> Bool {
        let leadingText = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return leadingText.hasPrefix("<html")
            || leadingText.hasPrefix("<!doctype html")
            || leadingText.hasPrefix("<?xml")
            || leadingText.contains("<h1>400 bad request</h1>")
            || leadingText.contains("<h1>404 not found</h1>")
            || (rejectingServiceUnavailable && leadingText.contains("<h1>503 "))
    }
}
