import Foundation

/// Parsed provider, account, server, and optional library scope for a music source key.
///
/// This Core-owned identity keeps the existing serialized key format while preventing
/// provider routing from depending on Plex API models.
public struct MediaSourceIdentity: Equatable, Hashable, Sendable {
    private let providerType: MusicSourceType
    public let accountId: String
    public let serverId: String
    public let libraryId: String?

    public init(
        type: MusicSourceType,
        accountId: String,
        serverId: String,
        libraryId: String? = nil
    ) {
        self.providerType = type
        self.accountId = accountId
        self.serverId = serverId
        self.libraryId = libraryId
    }

    public var type: String { providerType.rawValue }

    public var sourceType: MusicSourceType {
        providerType
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

    /// Parses only complete server- or library-scoped source keys.
    public static func parse(_ sourceKey: String?) -> MediaSourceIdentity? {
        guard let sourceKey else { return nil }
        let components = sourceKey.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty }),
              let type = MusicSourceType(rawValue: components[0]) else {
            return nil
        }
        return MediaSourceIdentity(
            type: type,
            accountId: components[1],
            serverId: components[2],
            libraryId: components.count == 4 ? components[3] : nil
        )
    }

    public static func serverSourceKey(from sourceKey: String?) -> String? {
        parse(sourceKey)?.serverSourceKey
    }

    public static func serverSourceKey(for source: MusicSourceIdentifier) -> String {
        "\(source.type.rawValue):\(source.accountId):\(source.serverId)"
    }

    public static func isSameServer(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = parse(lhs), let rhs = parse(rhs) else { return false }
        return lhs.sourceType == rhs.sourceType
            && lhs.accountId == rhs.accountId
            && lhs.serverId == rhs.serverId
    }
}
