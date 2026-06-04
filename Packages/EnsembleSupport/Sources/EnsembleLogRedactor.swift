import Foundation

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
        let endpointRedacted = redactHostLiterals(in: redactPathLiterals(in: redactURLLiterals(in: message)))
        return sensitiveNames.reduce(endpointRedacted) { partial, name in
            redactValue(named: name, in: partial)
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
