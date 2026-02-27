import Foundation

/// User-defined visibility preset that controls which source composite keys are hidden from browse surfaces.
public struct LibraryVisibilityProfile: Identifiable, Codable, Hashable, Sendable {
    public static let defaultProfileID = "default"

    public let id: String
    public var name: String
    public var hiddenSourceCompositeKeys: Set<String>
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        hiddenSourceCompositeKeys: Set<String> = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hiddenSourceCompositeKeys = hiddenSourceCompositeKeys
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static var `default`: LibraryVisibilityProfile {
        LibraryVisibilityProfile(
            id: defaultProfileID,
            name: "All Libraries",
            hiddenSourceCompositeKeys: []
        )
    }
}
