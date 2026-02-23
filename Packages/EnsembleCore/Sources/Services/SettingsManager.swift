import SwiftUI
import Combine

public enum TrackSwipeAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case playNext
    case playLast
    case addToPlaylist
    case favoriteToggle

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .playNext:
            return "Play Next"
        case .playLast:
            return "Play Last"
        case .addToPlaylist:
            return "Add to Playlist…"
        case .favoriteToggle:
            return "Favorite Toggle"
        }
    }

    public var systemImage: String {
        switch self {
        case .playNext:
            return "text.insert"
        case .playLast:
            return "text.append"
        case .addToPlaylist:
            return "text.badge.plus"
        case .favoriteToggle:
            return "heart.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .playNext:
            return .blue
        case .playLast:
            return .indigo
        case .addToPlaylist:
            return .orange
        case .favoriteToggle:
            return .pink
        }
    }
}

public enum TrackSwipeEdge: String, Codable, Sendable {
    case leading
    case trailing
}

public struct TrackSwipeLayout: Codable, Equatable, Sendable {
    public static let slotCountPerEdge = 2

    public var leading: [TrackSwipeAction?]
    public var trailing: [TrackSwipeAction?]

    public init(leading: [TrackSwipeAction?], trailing: [TrackSwipeAction?]) {
        self.leading = leading
        self.trailing = trailing
        sanitize()
    }

    public static var `default`: TrackSwipeLayout {
        TrackSwipeLayout(
            leading: [.playNext, .playLast],
            trailing: [.favoriteToggle, .addToPlaylist]
        )
    }

    public mutating func sanitize() {
        leading = Self.normalizedSlots(from: leading)
        trailing = Self.normalizedSlots(from: trailing)

        // Ensure each action appears at most once across all slots.
        var seen = Set<TrackSwipeAction>()
        for index in leading.indices {
            guard let action = leading[index] else { continue }
            if seen.contains(action) {
                leading[index] = nil
            } else {
                seen.insert(action)
            }
        }
        for index in trailing.indices {
            guard let action = trailing[index] else { continue }
            if seen.contains(action) {
                trailing[index] = nil
            } else {
                seen.insert(action)
            }
        }

        // Recover from corrupted/empty payloads so swipe gestures always have actions.
        if leading.allSatisfy({ $0 == nil }) && trailing.allSatisfy({ $0 == nil }) {
            self = .default
        }
    }

    private static func normalizedSlots(from source: [TrackSwipeAction?]) -> [TrackSwipeAction?] {
        var slots = Array(source.prefix(slotCountPerEdge))
        if slots.count < slotCountPerEdge {
            slots.append(contentsOf: Array(repeating: nil, count: slotCountPerEdge - slots.count))
        }
        return slots
    }
}

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
    @AppStorage("trackSwipeLayout") private var trackSwipeLayoutData: Data = Data()
    @AppStorage("allowInsecureConnectionsPolicy") private var allowInsecureConnectionsPolicyRawValue: String = AllowInsecureConnectionsPolicy.defaultForEnsemble.rawValue
    
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

    public var allowInsecureConnectionsPolicy: AllowInsecureConnectionsPolicy {
        get {
            AllowInsecureConnectionsPolicy(rawValue: allowInsecureConnectionsPolicyRawValue) ?? .defaultForEnsemble
        }
        set {
            allowInsecureConnectionsPolicyRawValue = newValue.rawValue
            objectWillChange.send()
        }
    }

    public var trackSwipeLayout: TrackSwipeLayout {
        get {
            guard !trackSwipeLayoutData.isEmpty,
                  let decoded = try? JSONDecoder().decode(TrackSwipeLayout.self, from: trackSwipeLayoutData) else {
                return .default
            }
            var sanitized = decoded
            sanitized.sanitize()
            return sanitized
        }
        set {
            var sanitized = newValue
            sanitized.sanitize()
            if let encoded = try? JSONEncoder().encode(sanitized) {
                trackSwipeLayoutData = encoded
            } else if let encodedDefault = try? JSONEncoder().encode(TrackSwipeLayout.default) {
                trackSwipeLayoutData = encodedDefault
            }
            objectWillChange.send()
        }
    }

    public func setAccentColor(_ color: AppAccentColor) {
        accentColorName = color.rawValue
        objectWillChange.send()
    }

    public func setAllowInsecureConnectionsPolicy(_ policy: AllowInsecureConnectionsPolicy) {
        allowInsecureConnectionsPolicy = policy
    }

    public func resetTrackSwipeLayoutToDefaults() {
        trackSwipeLayout = .default
    }

    @discardableResult
    public func setTrackSwipeAction(
        _ action: TrackSwipeAction?,
        edge: TrackSwipeEdge,
        index: Int
    ) -> Bool {
        guard index >= 0 && index < TrackSwipeLayout.slotCountPerEdge else { return false }

        var layout = trackSwipeLayout

        if let action,
           isTrackSwipeActionAssigned(action, excluding: (edge: edge, index: index), layout: layout) {
            return false
        }

        switch edge {
        case .leading:
            layout.leading[index] = action
        case .trailing:
            layout.trailing[index] = action
        }
        trackSwipeLayout = layout
        return true
    }

    public func moveTrackSwipeAction(edge: TrackSwipeEdge, fromOffsets: IndexSet, toOffset: Int) {
        var layout = trackSwipeLayout
        switch edge {
        case .leading:
            layout.leading.move(fromOffsets: fromOffsets, toOffset: toOffset)
        case .trailing:
            layout.trailing.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
        trackSwipeLayout = layout
    }

    public func isTrackSwipeActionAssigned(
        _ action: TrackSwipeAction,
        excluding location: (edge: TrackSwipeEdge, index: Int)? = nil
    ) -> Bool {
        isTrackSwipeActionAssigned(action, excluding: location, layout: trackSwipeLayout)
    }

    private func isTrackSwipeActionAssigned(
        _ action: TrackSwipeAction,
        excluding location: (edge: TrackSwipeEdge, index: Int)? = nil,
        layout: TrackSwipeLayout
    ) -> Bool {
        for (index, candidate) in layout.leading.enumerated() {
            if let location,
               location.edge == .leading,
               location.index == index {
                continue
            }
            if candidate == action {
                return true
            }
        }
        for (index, candidate) in layout.trailing.enumerated() {
            if let location,
               location.edge == .trailing,
               location.index == index {
                continue
            }
            if candidate == action {
                return true
            }
        }
        return false
    }
}
