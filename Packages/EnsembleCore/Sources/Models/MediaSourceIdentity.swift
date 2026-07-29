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

    public static func playlistScopeKey(from sourceKey: String?) -> String? {
        guard let identity = parse(sourceKey) else { return nil }
        if identity.sourceType.capabilities.playlistsAreServerScoped {
            return identity.serverSourceKey
        }
        return identity.librarySourceKey ?? identity.serverSourceKey
    }

    /// Returns a provider only when the source key has a complete, valid identity.
    /// A missing or malformed key has unresolved ownership.
    public static func sourceType(from sourceKey: String?) -> MusicSourceType? {
        parse(sourceKey)?.sourceType
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

    /// Whether an exact library key, or a server-scoped item such as a Plex playlist,
    /// is covered by the currently enabled source keys.
    public static func isEnabledSourceKey(
        _ sourceKey: String?,
        within enabledSourceKeys: Set<String>
    ) -> Bool {
        guard let sourceKey else { return false }
        if enabledSourceKeys.contains(sourceKey) { return true }
        guard let identity = parse(sourceKey),
              identity.isServerScoped,
              identity.sourceType.capabilities.playlistsAreServerScoped else {
            return false
        }
        return enabledSourceKeys.contains {
            guard let enabledIdentity = parse($0) else { return false }
            return enabledIdentity.sourceType == identity.sourceType &&
                enabledIdentity.accountId == identity.accountId &&
                enabledIdentity.serverId == identity.serverId
        }
    }
}
