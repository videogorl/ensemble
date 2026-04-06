import Foundation

/// User profile data model for display name and profile picture.
/// Synced across devices via CloudKit and persisted locally for offline access.
public struct UserProfile: Codable, Equatable {
    /// User's display name (nil when not yet set)
    public var displayName: String?

    /// Relative path to the local profile image file (nil when no image set)
    public var profileImagePath: String?

    /// Last time the profile was modified (used for conflict resolution)
    public var lastModified: Date

    public init(displayName: String? = nil, profileImagePath: String? = nil, lastModified: Date = .distantPast) {
        self.displayName = displayName
        self.profileImagePath = profileImagePath
        self.lastModified = lastModified
    }

    /// Whether the profile has any user-set data
    public var isEmpty: Bool {
        displayName == nil && profileImagePath == nil
    }
}
