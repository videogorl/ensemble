import Foundation

/// Compact searchable index consumed by Siri intent resolution.
public struct SiriMediaIndex: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let items: [SiriMediaIndexItem]

    public init(
        schemaVersion: Int = SiriMediaIndex.currentSchemaVersion,
        generatedAt: Date = Date(),
        items: [SiriMediaIndexItem]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.items = items
    }
}

/// Single candidate entity for Siri media lookup.
public struct SiriMediaIndexItem: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let kind: SiriMediaKind
    public let id: String
    public let displayName: String
    public let sourceCompositeKey: String?
    public let secondaryText: String?
    public let lastPlayed: Date?
    public let playCount: Int?
    public let trackCount: Int?

    public init(
        kind: SiriMediaKind,
        id: String,
        displayName: String,
        sourceCompositeKey: String? = nil,
        secondaryText: String? = nil,
        lastPlayed: Date? = nil,
        playCount: Int? = nil,
        trackCount: Int? = nil
    ) {
        self.kind = kind
        self.id = id
        self.displayName = displayName
        self.sourceCompositeKey = sourceCompositeKey
        self.secondaryText = secondaryText
        self.lastPlayed = lastPlayed
        self.playCount = playCount
        self.trackCount = trackCount
    }
}
