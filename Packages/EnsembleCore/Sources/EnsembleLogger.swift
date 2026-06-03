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

public enum EnsembleStartupTiming {
    /// Set by AppDelegate at launch for TTFMP measurement.
    /// Accessible from EnsembleCore without importing the app target.
    public static var launchTime: Date?

    /// Log time-to-first-meaningful-paint (once, then auto-disables).
    /// Kept behind #if DEBUG — TTFMP measurement is a development-only concern.
    static var hasLoggedTTFMP = false
    public static func logTTFMP(milestone: String) {
        #if DEBUG
        guard !hasLoggedTTFMP, let launch = launchTime else { return }
        hasLoggedTTFMP = true
        let elapsed = Date().timeIntervalSince(launch)
        EnsembleLogger.debug("TTFMP: \(milestone) at \(String(format: "%.2f", elapsed))s after launch")
        #endif
    }
}

/// Package-level logger for EnsembleCore. Writes to the unified log and the
/// optional persistent session sink used for TestFlight diagnostics.
public enum EnsembleLogger {
    private static let logger = Logger(subsystem: "com.videogorl.ensemble", category: "core")

    /// Separate logger for playback-critical events. Uses "playback" category so these
    /// can be filtered in Console.app with: `log stream --predicate 'category == "playback"'`
    private static let playbackLogger = Logger(subsystem: "com.videogorl.ensemble", category: "playback")

    /// Closure wired by PersistentLogService to receive log entries for file writing.
    /// Parameters: (level, category, message)
    public static var fileLogHandler: ((String, String, String) -> Void)?

    private static let category = "core"

    /// Playback-critical log for device diagnostics. Logs at `.info` level so messages
    /// persist in the unified log (visible in Console.app after the fact, not just `log stream`).
    /// NOT behind `#if DEBUG` — these logs exist in Release builds for on-device triage.
    static func playback(_ message: @autoclosure () -> String) {
        let msg = LogRedactor.redactSensitiveValues(in: message())
        playbackLogger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", "playback", msg)
    }

    public static func debug(_ message: @autoclosure () -> String) {
        let msg = LogRedactor.redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }

    static func info(_ message: @autoclosure () -> String) {
        let msg = LogRedactor.redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", category, msg)
    }

    static func error(_ message: @autoclosure () -> String) {
        let msg = LogRedactor.redactSensitiveValues(in: message())
        logger.error("\(msg, privacy: .public)")
        fileLogHandler?("ERROR", category, msg)
    }
}
