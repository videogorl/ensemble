import Foundation

/// Radio mode for playback
public enum RadioMode: String, Codable, CaseIterable, Sendable {
    case trackRadio = "track"      // Similar tracks to current track
    case artistRadio = "artist"    // Artist radio station
    case albumRadio = "album"      // Similar albums
    case libraryRadio = "library"  // Popular tracks from library
    case timeTravelRadio = "timeTravel"  // Chronological by year
    case off = "off"               // Radio disabled

    public var displayName: String {
        switch self {
        case .trackRadio: return "Track Radio"
        case .artistRadio: return "Artist Radio"
        case .albumRadio: return "Album Radio"
        case .libraryRadio: return "Library Radio"
        case .timeTravelRadio: return "Time Travel"
        case .off: return "Off"
        }
    }

    public var icon: String {
        switch self {
        case .trackRadio: return "music.note"
        case .artistRadio: return "person.fill"
        case .albumRadio: return "square.stack"
        case .libraryRadio: return "books.vertical"
        case .timeTravelRadio: return "clock.arrow.circlepath"
        case .off: return "stop.circle"
        }
    }
}

/// Protocol for providing radio/recommendation functionality
/// Different sources (Plex, Jellyfin, offline) can implement their own providers
public protocol RadioProviderProtocol: AnyObject {
    /// Get recommended tracks based on a seed track (Track Radio)
    /// Returns nil if recommendations unavailable (offline, no subscription, etc.)
    /// - Parameters:
    ///   - track: The seed track to base recommendations on
    ///   - limit: Maximum number of tracks to return
    func getRecommendedTracks(
        basedOn track: Track,
        limit: Int
    ) async -> [Track]?

    /// Get radio station for an artist (Artist Radio)
    /// Returns nil if artist radio unavailable
    /// - Parameter artist: The artist to create radio for
    func getArtistRadio(for artist: Artist) async -> [Track]?

    /// Get radio station for an album (Album Radio)
    /// Returns nil if album radio unavailable
    /// - Parameter album: The album to create radio for
    func getAlbumRadio(for album: Album) async -> [Track]?

    /// Get library radio (popular/highly-rated tracks)
    /// Returns nil if unavailable
    /// - Parameter limit: Maximum number of tracks to return
    func getLibraryRadio(limit: Int) async -> [Track]?

    /// Get time travel radio (chronological playback)
    /// Returns nil if unavailable
    /// - Parameter limit: Maximum number of tracks to return
    func getTimeTravelRadio(limit: Int) async -> [Track]?

    /// Check if radio/recommendations are available for this source
    var isAvailable: Bool { get async }

    /// Get the music source identifier for this provider
    var sourceKey: String { get }
}
