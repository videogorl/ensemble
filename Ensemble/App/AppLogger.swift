import Foundation
import OSLog

/// App-target logger. Writes to the unified log and the optional persistent
/// session sink used for TestFlight diagnostics.
enum AppLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "app")
    private static let sensitiveNames = [
        "X-Plex-Token",
        "accessToken",
        "authToken",
        "rawToken"
    ]

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "app"

    static func debug(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", category, msg)
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.error("\(msg, privacy: .public)")
        fileLogHandler?("ERROR", category, msg)
    }

    static func fault(_ message: @autoclosure () -> String) {
        let msg = redactSensitiveValues(in: message())
        logger.fault("\(msg, privacy: .public)")
        fileLogHandler?("FAULT", category, msg)
    }

    private static func redactSensitiveValues(in message: String) -> String {
        sensitiveNames.reduce(message) { partial, name in
            redactValue(named: name, in: partial)
        }
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
