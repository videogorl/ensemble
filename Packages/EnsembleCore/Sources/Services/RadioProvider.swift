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
