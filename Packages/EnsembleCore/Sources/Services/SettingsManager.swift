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

public enum SongsTableColumn: String, CaseIterable, Codable, Sendable, Identifiable {
    case title
    case time
    case artist
    case album
    case genre
    case favorite
    case plays
    case dateAdded
    case downloaded

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .title:
            return "Title"
        case .time:
            return "Time"
        case .artist:
            return "Artist"
        case .album:
            return "Album"
        case .genre:
            return "Genre"
        case .favorite:
            return "Favorite"
        case .plays:
            return "Plays"
        case .dateAdded:
            return "Date Added"
        case .downloaded:
            return "Downloaded"
        }
    }

    public static var defaultVisibleColumns: [SongsTableColumn] {
        [.title, .time, .artist, .album, .genre, .favorite, .plays, .dateAdded, .downloaded]
    }
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
        leading = Self.sanitizedSlots(from: leading)
        trailing = Self.sanitizedSlots(from: trailing)

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

    private static func sanitizedSlots(from source: [TrackSwipeAction?]) -> [TrackSwipeAction?] {
        var slots = normalizedSlots(from: source)
        var seen = Set<TrackSwipeAction>()

        for index in slots.indices {
            guard let action = slots[index] else { continue }
            if seen.contains(action) {
                slots[index] = nil
            } else {
                seen.insert(action)
            }
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

/// Shared display redaction for development demo screenshots and recordings.
public enum DemoModeRedaction {
    public static let accountIdentifier = "Plex Account"
    public static let serverName = "Plex Server"
    public static let connectionInfo = "Hidden in Demo Mode"

    public static func accountIdentifier(_ value: String, isEnabled: Bool) -> String {
        isEnabled ? accountIdentifier : value
    }

    public static func serverName(_ value: String, isEnabled: Bool) -> String {
        isEnabled ? serverName : value
    }

    public static func connectionInfo(_ value: String, isEnabled: Bool) -> String {
        isEnabled ? connectionInfo : value
    }

    public static func sourceDisplayName(
        serverName: String,
        libraryTitle: String,
        isEnabled: Bool
    ) -> String {
        "\(Self.serverName(serverName, isEnabled: isEnabled)) - \(libraryTitle)"
    }

    public static func sourceDisplaySubtitle(
        serverName: String,
        libraryTitle: String,
        accountName: String,
        isEnabled: Bool
    ) -> String {
        "\(sourceDisplayName(serverName: serverName, libraryTitle: libraryTitle, isEnabled: isEnabled)) · \(accountIdentifier(accountName, isEnabled: isEnabled))"
    }
}

@MainActor
public final class SettingsManager: ObservableObject {
    public static let playlistMergeEnabledKey = "playlistMergeEnabled"
    public static let defaultPlaylistMergeEnabled = true

    public static func storedPlaylistMergeEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: playlistMergeEnabledKey) != nil else {
            return defaultPlaylistMergeEnabled
        }
        return defaults.bool(forKey: playlistMergeEnabledKey)
    }

    @AppStorage("accentColor") public var accentColorName: String = "blue"
    @AppStorage("enabledTabs") private var enabledTabsData: Data = Data()
    @AppStorage("trackSwipeLayout") private var trackSwipeLayoutData: Data = Data()
    @AppStorage("songsTableColumns") private var songsTableColumnsData: Data = Data()
    @AppStorage(AllowInsecureConnectionsPolicy.defaultsKey) private var allowInsecureConnectionsPolicyRawValue: String = AllowInsecureConnectionsPolicy.defaultForEnsemble.rawValue
    @AppStorage(AuroraVisualizationPreference.enabledKey) public var auroraVisualizationEnabled: Bool = AuroraVisualizationPreference.defaultEnabled
    @AppStorage("scrobblingEnabled") public var scrobblingEnabled: Bool = true
    @AppStorage(playlistMergeEnabledKey) public var playlistMergeEnabled: Bool = defaultPlaylistMergeEnabled
    #if DEBUG
    @AppStorage("demoModeEnabled") public var demoModeEnabled: Bool = false
    #else
    public var demoModeEnabled: Bool {
        get { false }
        set {}
    }
    #endif

    public init() {
        // Register defaults so UserDefaults.standard.bool(forKey:) returns true
        // before the setting has ever been toggled (PlaybackService reads directly).
        UserDefaults.standard.register(defaults: [
            AuroraVisualizationPreference.enabledKey: AuroraVisualizationPreference.defaultEnabled,
            "scrobblingEnabled": true,
            Self.playlistMergeEnabledKey: Self.defaultPlaylistMergeEnabled,
            "demoModeEnabled": false
        ])
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

    public var songsTableColumns: [SongsTableColumn] {
        get {
            guard !songsTableColumnsData.isEmpty,
                  let decoded = try? JSONDecoder().decode([SongsTableColumn].self, from: songsTableColumnsData) else {
                return SongsTableColumn.defaultVisibleColumns
            }

            let validColumns = decoded.filter { SongsTableColumn.allCases.contains($0) }
            return validColumns.isEmpty ? SongsTableColumn.defaultVisibleColumns : validColumns
        }
        set {
            let deduplicated = newValue.reduce(into: [SongsTableColumn]()) { result, column in
                if !result.contains(column) {
                    result.append(column)
                }
            }
            let columns = deduplicated.isEmpty ? SongsTableColumn.defaultVisibleColumns : deduplicated
            if let encoded = try? JSONEncoder().encode(columns) {
                songsTableColumnsData = encoded
                objectWillChange.send()
            }
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

    public func setSongsTableColumn(_ column: SongsTableColumn, isVisible: Bool) {
        var columns = songsTableColumns
        if isVisible {
            guard !columns.contains(column) else { return }
            let allColumns = SongsTableColumn.allCases
            if let insertionIndex = allColumns.firstIndex(of: column) {
                let targetOffset = columns.firstIndex { existing in
                    guard let existingIndex = allColumns.firstIndex(of: existing) else { return false }
                    return existingIndex > insertionIndex
                } ?? columns.endIndex
                columns.insert(column, at: targetOffset)
            } else {
                columns.append(column)
            }
        } else {
            columns.removeAll { $0 == column }
        }
        songsTableColumns = columns
    }

    public func resetSongsTableColumnsToDefaults() {
        songsTableColumns = SongsTableColumn.defaultVisibleColumns
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
           isTrackSwipeActionAssigned(action, edge: edge, excluding: index, layout: layout) {
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

    private func isTrackSwipeActionAssigned(
        _ action: TrackSwipeAction,
        edge: TrackSwipeEdge,
        excluding excludedIndex: Int? = nil,
        layout: TrackSwipeLayout
    ) -> Bool {
        let slots: [TrackSwipeAction?]
        switch edge {
        case .leading:
            slots = layout.leading
        case .trailing:
            slots = layout.trailing
        }

        for (index, candidate) in slots.enumerated() {
            if excludedIndex == index {
                continue
            }
            if candidate == action {
                return true
            }
        }
        return false
    }
}
