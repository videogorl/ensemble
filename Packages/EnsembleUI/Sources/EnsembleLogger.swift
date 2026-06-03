import Foundation
import OSLog

enum LogRedactor {
    private static let sensitiveNames = [
        "X-Plex-Token",
        "Authorization",
        "accessToken",
        "authToken",
        "rawToken",
        "token"
    ]

    static func redactSensitiveValues(in message: String) -> String {
        let pathRedacted = redactPathLiterals(in: redactURLLiterals(in: message))
        return sensitiveNames.reduce(pathRedacted) { partial, name in
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

    private static func redactPathLiterals(in message: String) -> String {
        message
            .replacingOccurrences(
                of: #"(?:file://)?/(Users|private/var|var/mobile|var/folders|tmp)/.*?(?=\s+\w+\s*[:=]|$|[,)\]\}>])"#,
                with: "<redacted-path>",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: #"/(?:library|playlists|hubs)/[^\s,\)\]\}>]+"#,
                with: "<redacted-path>",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    private static func redactValue(named name: String, in message: String) -> String {
        if name.caseInsensitiveCompare("Authorization") == .orderedSame {
            return message.replacingOccurrences(
                of: #"(?i)(\bAuthorization\s*[:=]\s*)(?:Bearer\s+[^&\s,\)\]\}><]+|[^&\s,\)\]\}><]+)"#,
                with: "$1<redacted>",
                options: .regularExpression
            )
        }

        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let plainPattern = #"(?i)(\b\#(escapedName)\s*[:=]\s*)[^&\s,\)\]\}><]+"#
        let encodedPattern = #"(?i)(\b\#(escapedName)%3D)[^%&\s,\)\]\}><]+"#

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

/// Package-level logger for EnsembleUI. Writes to the unified log and the
/// optional persistent session sink used for TestFlight diagnostics.
public enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "ui")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    /// Parameters: (level, category, message)
    public static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "ui"

    static func debug(_ message: @autoclosure () -> String) {
        let msg = LogRedactor.redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }
}
