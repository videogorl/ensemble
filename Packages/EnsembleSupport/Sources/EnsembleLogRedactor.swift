import Foundation
import OSLog

public typealias EnsembleFileLogHandler = (String, String, String) -> Void

/// Shared privacy redactor for log messages before they reach unified or
/// persistent diagnostic logs.
public enum EnsembleLogRedactor {
    private static let sensitiveNames = [
        "X-Plex-Token",
        "Authorization",
        "accessToken",
        "authToken",
        "rawToken",
        "token"
    ]

    public static func redactSensitiveValues(in message: String) -> String {
        guard mayContainRedactableContent(message) else {
            return message
        }

        var redacted = message
        if mayContainURL(in: redacted) {
            redacted = redactURLLiterals(in: redacted)
        }
        if mayContainPath(in: redacted) {
            redacted = redactPathLiterals(in: redacted)
        }
        if mayContainHost(in: redacted) {
            redacted = redactHostLiterals(in: redacted)
        }
        if mayContainSensitiveName(in: redacted) {
            redacted = sensitiveNames.reduce(redacted) { partial, name in
                redactValue(named: name, in: partial)
            }
        }
        return redacted
    }

    private static func mayContainRedactableContent(_ message: String) -> Bool {
        mayContainURL(in: message) ||
            mayContainPath(in: message) ||
            mayContainHost(in: message) ||
            mayContainSensitiveName(in: message)
    }

    private static func mayContainURL(in message: String) -> Bool {
        message.range(of: "http://", options: .caseInsensitive) != nil ||
            message.range(of: "https://", options: .caseInsensitive) != nil
    }

    private static func mayContainPath(in message: String) -> Bool {
        message.range(of: "file://", options: .caseInsensitive) != nil ||
            message.contains("/Users/") ||
            message.contains("/private/var/") ||
            message.contains("/var/mobile/") ||
            message.contains("/var/folders/") ||
            message.contains("/tmp/") ||
            message.range(of: "/library", options: .caseInsensitive) != nil ||
            message.range(of: "/playlists", options: .caseInsensitive) != nil ||
            message.range(of: "/hubs", options: .caseInsensitive) != nil
    }

    private static func mayContainHost(in message: String) -> Bool {
        message.range(of: ".plex.direct", options: .caseInsensitive) != nil ||
            message.contains("<redacted-path>") ||
            message.range(of: "/library", options: .caseInsensitive) != nil ||
            message.range(of: "/playlists", options: .caseInsensitive) != nil ||
            message.range(of: "/hubs", options: .caseInsensitive) != nil
    }

    private static func mayContainSensitiveName(in message: String) -> Bool {
        sensitiveNames.contains { name in
            message.range(of: name, options: .caseInsensitive) != nil ||
                message.range(of: "\(name)%3D", options: .caseInsensitive) != nil
        }
    }

    private static func redactURLLiterals(in message: String) -> String {
        message.replacingOccurrences(
            of: #"https?://\S+"#,
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
                of: #"/(?:library|playlists|hubs)(?:/\S*|\b)"#,
                with: "<redacted-path>",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    private static func redactHostLiterals(in message: String) -> String {
        message
            .replacingOccurrences(
                of: #"\b(?:\d{1,3}\.){3}\d{1,3}(?=<redacted-path>|/(?:library|playlists|hubs)/)"#,
                with: "<redacted-host>",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\b[A-Za-z0-9.-]+\.plex\.direct\b"#,
                with: "<redacted-host>",
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

/// Writes privacy-redacted messages to unified and optional persistent logs.
public enum EnsembleLogEmitter {
    public static func debug(
        _ message: @autoclosure () -> String,
        logger: Logger,
        category: String,
        fileLogHandler: EnsembleFileLogHandler?
    ) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.debug("\(msg, privacy: .public)")
        fileLogHandler?("DEBUG", category, msg)
    }

    public static func info(
        _ message: @autoclosure () -> String,
        logger: Logger,
        category: String,
        fileLogHandler: EnsembleFileLogHandler?
    ) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.info("\(msg, privacy: .public)")
        fileLogHandler?("INFO", category, msg)
    }

    public static func error(
        _ message: @autoclosure () -> String,
        logger: Logger,
        category: String,
        fileLogHandler: EnsembleFileLogHandler?
    ) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.error("\(msg, privacy: .public)")
        fileLogHandler?("ERROR", category, msg)
    }

    public static func fault(
        _ message: @autoclosure () -> String,
        logger: Logger,
        category: String,
        fileLogHandler: EnsembleFileLogHandler?
    ) {
        let msg = EnsembleLogRedactor.redactSensitiveValues(in: message())
        logger.fault("\(msg, privacy: .public)")
        fileLogHandler?("FAULT", category, msg)
    }
}
