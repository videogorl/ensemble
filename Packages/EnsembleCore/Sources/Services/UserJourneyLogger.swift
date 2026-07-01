import Foundation

/// Low-volume breadcrumbs for reconstructing what the user was doing around a failure.
public enum UserJourneyLogger {
    public static func log(
        context: String,
        event: String,
        details: [String: String] = [:]
    ) {
        EnsembleLogger.info(message(context: context, event: event, details: details))
    }

    static func message(
        context: String,
        event: String,
        details: [String: String] = [:]
    ) -> String {
        let base = "USER_JOURNEY context=\(sanitize(context)) event=\(sanitize(event))"
        guard !details.isEmpty else { return base }

        let renderedDetails = details
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\(sanitize($0.value))" }
            .joined(separator: " ")

        return "\(base) \(renderedDetails)"
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: " ", with: "_")
    }
}
