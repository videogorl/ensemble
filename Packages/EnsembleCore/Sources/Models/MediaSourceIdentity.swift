import Foundation

/// Parsed media source identity for comparing library-scoped and server-scoped keys.
public struct MediaSourceIdentity: Equatable, Sendable {
    public let type: String
    public let accountId: String
    public let serverId: String
    public let libraryId: String?

    public init(type: String, accountId: String, serverId: String, libraryId: String? = nil) {
        self.type = type
        self.accountId = accountId
        self.serverId = serverId
        self.libraryId = libraryId
    }

    public var serverSourceKey: String {
        "\(type):\(accountId):\(serverId)"
    }

    public var accountServerKey: String {
        "\(accountId):\(serverId)"
    }

    public var isServerScoped: Bool {
        libraryId == nil
    }

    public var librarySourceKey: String? {
        guard let libraryId else { return nil }
        return "\(serverSourceKey):\(libraryId)"
    }

    public static func parse(_ sourceCompositeKey: String?) -> MediaSourceIdentity? {
        guard let sourceCompositeKey else { return nil }
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return MediaSourceIdentity(
            type: String(components[0]),
            accountId: String(components[1]),
            serverId: String(components[2]),
            libraryId: components.count >= 4 ? String(components[3]) : nil
        )
    }

    public static func serverSourceKey(from sourceCompositeKey: String?) -> String? {
        parse(sourceCompositeKey)?.serverSourceKey
    }

    public static func serverSourceKey(for source: MusicSourceIdentifier) -> String {
        "\(source.type.rawValue):\(source.accountId):\(source.serverId)"
    }

    public static func isSameServer(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhsServer = serverSourceKey(from: lhs),
              let rhsServer = serverSourceKey(from: rhs) else { return false }
        return lhsServer == rhsServer
    }
}
