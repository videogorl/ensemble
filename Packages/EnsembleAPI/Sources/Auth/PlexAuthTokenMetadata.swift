import Foundation

/// Parsed metadata for a Plex JWT-style access token.
public struct PlexAuthTokenMetadata: Codable, Sendable, Equatable {
    public let rawToken: String
    public let issuedAt: Date?
    public let expiresAt: Date?

    public init(rawToken: String, issuedAt: Date?, expiresAt: Date?) {
        self.rawToken = rawToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }
}

enum PlexJWTParser {
    static func decodeMetadata(from token: String) -> PlexAuthTokenMetadata {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = decodeBase64URL(String(parts[1])),
              let payloadJSON = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return PlexAuthTokenMetadata(rawToken: token, issuedAt: nil, expiresAt: nil)
        }

        let issuedAt = (payloadJSON["iat"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        let expiresAt = (payloadJSON["exp"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        return PlexAuthTokenMetadata(rawToken: token, issuedAt: issuedAt, expiresAt: expiresAt)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
