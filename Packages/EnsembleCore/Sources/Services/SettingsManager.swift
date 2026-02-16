import SwiftUI
import Combine

public enum AppAccentColor: String, CaseIterable, Identifiable {
    case purple = "purple"
    case blue = "blue"
    case pink = "pink"
    case red = "red"
    case orange = "orange"
    case yellow = "yellow"
    case green = "green"
    
    public var id: String { rawValue }
    
    public var color: Color {
        switch self {
        case .purple: return .purple
        case .blue: return .blue
        case .pink: return Color(red: 1.0, green: 0.0, blue: 1.0) // Magenta
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        }
    }
}

public enum TabItem: String, CaseIterable, Identifiable, Codable {
    case home = "Home"
    case songs = "Songs"
    case artists = "Artists"
    case albums = "Albums"
    case genres = "Genres"
    case playlists = "Playlists"
    case favorites = "Favorites"
    case search = "Search"
    case downloads = "Downloads"
    case settings = "Settings"
    
    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .home:
            return "Feed"
        default:
            return rawValue
        }
    }
    
    public var systemImage: String {
        switch self {
        case .home: return "house"
        case .songs: return "music.note"
        case .artists: return "person.2"
        case .albums: return "square.stack"
        case .genres: return "guitars"
        case .playlists: return "music.note.list"
        case .favorites: return "heart"
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle"
        case .settings: return "gear"
        }
    }
}

@MainActor
public final class SettingsManager: ObservableObject {
    @AppStorage("accentColor") public var accentColorName: String = "blue"
    @AppStorage("enabledTabs") private var enabledTabsData: Data = Data()
    
    public init() {
        if enabledTabsData.isEmpty {
            // Default tabs
            let defaultTabs: [TabItem] = [.home, .artists, .playlists, .search]
            if let encoded = try? JSONEncoder().encode(defaultTabs) {
                enabledTabsData = encoded
            }
        }
    }
    
    public var enabledTabs: [TabItem] {
        get {
            if let decoded = try? JSONDecoder().decode([TabItem].self, from: enabledTabsData) {
                return decoded
            }
            return [.home, .songs, .artists, .playlists]
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                enabledTabsData = encoded
                objectWillChange.send()
            }
        }
    }
    
    public var accentColor: AppAccentColor {
        AppAccentColor(rawValue: accentColorName) ?? .blue
    }
    
    public func setAccentColor(_ color: AppAccentColor) {
        accentColorName = color.rawValue
        objectWillChange.send()
    }
}
