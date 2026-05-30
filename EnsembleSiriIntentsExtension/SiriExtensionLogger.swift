import Foundation
import OSLog

/// Siri extension logger with the same privacy redaction policy as the app logger.
enum SiriExtensionLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble.siri-intents", category: "siri-extension")
    private static let sensitiveNames = [
        "X-Plex-Token",
        "accessToken",
        "authToken",
        "rawToken"
    ]

    static func debug(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.error("\(msg, privacy: .public)")
    }

    private static func redactSensitiveValues(in message: String) -> String {
        let urlRedacted = redactURLLiterals(in: message)
        return sensitiveNames.reduce(urlRedacted) { partial, name in
            redactValue(named: name, in: partial)
        }
    }

    private static func redactURLLiterals(in message: String) -> String {
        message.replacingOccurrences(
            of: #"https?://[^\s,\)\]\}>]+"#,
            with: "<redacted-url>",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func redactValue(named name: String, in message: String) -> String {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let plainPattern = #"(?i)(\b\#(escapedName)\s*[:=]\s*)[^&\s,\)\]\}>]+"#
        let encodedPattern = #"(?i)(\b\#(escapedName)%3D)[^%&\s,\)\]\}>]+"#

        return message
            .replacingOccurrences(
                of: plainPattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: encodedPattern,
                with: "$1<redacted>",
                options: .regularExpression
            )
    }
}
