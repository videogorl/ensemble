import EnsembleAPI

public typealias MediaSourceIdentity = PlexSourceIdentity

public extension PlexSourceIdentity {
    static func serverSourceKey(for source: MusicSourceIdentifier) -> String {
        "\(source.type.rawValue):\(source.accountId):\(source.serverId)"
    }
}
