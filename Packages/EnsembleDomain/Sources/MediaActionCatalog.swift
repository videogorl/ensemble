import Foundation

public enum EnsembleMediaAction: String, CaseIterable, Codable, Equatable, Sendable {
    case play
    case shuffle
    case radio
    case playNext
    case playLast
    case addToPlaylist
    case addToRecentPlaylist
    case favorite
    case pin
    case goToAlbum
    case goToArtist
    case share
    case delete
}

public struct EnsembleMediaActionDescriptor: Codable, Equatable, Sendable {
    public let action: EnsembleMediaAction
    public let title: String
    public let systemImage: String
    public let isDestructive: Bool

    public init(
        action: EnsembleMediaAction,
        title: String,
        systemImage: String,
        isDestructive: Bool = false
    ) {
        self.action = action
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
    }
}

public enum EnsembleMediaActionCatalog {
    public static let ordered: [EnsembleMediaActionDescriptor] = [
        .init(action: .play, title: "Play", systemImage: "play.fill"),
        .init(action: .shuffle, title: "Shuffle", systemImage: "shuffle"),
        .init(action: .radio, title: "Radio", systemImage: "dot.radiowaves.left.and.right"),
        .init(action: .playNext, title: "Play Next", systemImage: "text.insert"),
        .init(action: .playLast, title: "Play Last", systemImage: "text.append"),
        .init(action: .addToPlaylist, title: "Add to Playlist…", systemImage: "text.badge.plus"),
        .init(action: .addToRecentPlaylist, title: "Add to Recent Playlist", systemImage: "clock.arrow.circlepath"),
        .init(action: .favorite, title: "Favorite", systemImage: "heart"),
        .init(action: .pin, title: "Pin", systemImage: "pin.fill"),
        .init(action: .goToAlbum, title: "Go to Album", systemImage: "square.stack"),
        .init(action: .goToArtist, title: "Go to Artist", systemImage: "music.mic"),
        .init(action: .share, title: "Share Ensemble Link", systemImage: "link"),
        .init(action: .delete, title: "Delete", systemImage: "trash", isDestructive: true)
    ]
}
