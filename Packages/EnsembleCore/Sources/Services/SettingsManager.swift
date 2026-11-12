import EnsembleDomain
import EnsembleSupport
import SwiftUI

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

public enum NowPlayingSecondaryAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case airPlay, favorite, addToPlaylist, addToRecentPlaylist, addToLibrary
    case goToAlbum, goToArtist, shareEnsembleLink, shareLink, shareAudioFile

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .airPlay: return "AirPlay…"
        case .favorite: return "Favorite"
        case .addToPlaylist: return "Add to Playlist…"
        case .addToRecentPlaylist: return "Add to Recent Playlist"
        case .addToLibrary: return "Add to Library"
        case .goToAlbum: return "Go to Album"
        case .goToArtist: return "Go to Artist"
        case .shareEnsembleLink: return "Share Ensemble Link…"
        case .shareLink: return "Share Link…"
        case .shareAudioFile: return "Share Audio File…"
        }
    }

    public var systemImage: String {
        switch self {
        case .airPlay: return "airplay.audio"
        case .favorite: return "heart"
        case .addToPlaylist, .addToLibrary: return "text.badge.plus"
        case .addToRecentPlaylist: return "clock.arrow.circlepath"
        case .goToAlbum: return "square.stack"
        case .goToArtist: return "music.mic"
        case .shareEnsembleLink, .shareLink: return "link"
        case .shareAudioFile: return "square.and.arrow.up"
        }
    }

    public func isAvailable(
        for track: Track?,
        isFavorited: Bool,
        canAddToLibrary: Bool,
        hasRecentPlaylist: Bool
    ) -> Bool {
        if self == .airPlay { return true }
        guard let track else { return false }
        switch self {
        case .favorite: return track.actionAvailability(for: .favorite, isFavorited: isFavorited).isAvailable
        case .addToPlaylist: return track.actionAvailability(for: .addItems).isAvailable
        case .addToLibrary: return canAddToLibrary
        case .addToRecentPlaylist: return hasRecentPlaylist
        case .goToAlbum: return track.albumRatingKey != nil
        case .goToArtist: return track.artistRatingKey != nil
        case .shareAudioFile: return track.sourceCapabilities.supportsAudioFileSharing
        default: return true
        }
    }
}

public struct NowPlayingSecondaryLayout: Codable, Equatable, Sendable {
    public static let slotCount = 4
    public var slots: [NowPlayingSecondaryAction?]

    public init(slots: [NowPlayingSecondaryAction?]) {
        self.slots = slots
        sanitize()
    }

    public static var `default`: Self {
        Self(slots: [.airPlay, .favorite, .addToPlaylist, nil])
    }

    private enum CodingKeys: String, CodingKey { case slots }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([String?].self, forKey: .slots)
        slots = values.map { $0.flatMap(NowPlayingSecondaryAction.init(rawValue:)) }
        sanitize()
    }

    public func encode(to encoder: Encoder) throws {
        var sanitized = self
        sanitized.sanitize()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sanitized.slots.map { $0?.rawValue }, forKey: .slots)
    }

    public mutating func sanitize() {
        slots = Array(slots.prefix(Self.slotCount))
        slots.append(contentsOf: repeatElement(nil, count: Self.slotCount - slots.count))
        var seen = Set<NowPlayingSecondaryAction>()
        for index in slots.indices {
            if let action = slots[index], !seen.insert(action).inserted {
                slots[index] = nil
            }
        }
    }

    /// Selecting an action already assigned elsewhere swaps the two slots.
    public mutating func setAction(_ action: NowPlayingSecondaryAction?, at index: Int) {
        guard (0..<Self.slotCount).contains(index) else { return }
        sanitize()
        if let action, let previousIndex = slots.firstIndex(of: action), previousIndex != index {
            slots[previousIndex] = slots[index]
        }
        slots[index] = action
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

public enum TabItem: String, CaseIterable, Identifiable, Codable, Sendable {
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
@Observable
public final class SettingsManager {
    nonisolated public static let scrobblingEnabledKey = "scrobblingEnabled"
    nonisolated public static let mergingPreferencesKey = "mergingPreferences"
    nonisolated private static let focusScrobblingOverrideKey = "focusScrobblingOverride"
    nonisolated private static let noFocusScrobblingOverride = -1

    nonisolated public static func storedMergingPreferences(
        in defaults: UserDefaults = .standard
    ) -> EnsembleMergingPreferences {
        guard let data = defaults.data(forKey: mergingPreferencesKey),
              let preferences = try? JSONDecoder().decode(EnsembleMergingPreferences.self, from: data)
        else { return .default }
        return preferences
    }

    public static func setStoredMergingPreferences(
        _ preferences: EnsembleMergingPreferences,
        in defaults: UserDefaults = .standard
    ) {
        guard storedMergingPreferences(in: defaults) != preferences,
              let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: mergingPreferencesKey)
    }

    nonisolated public static func effectiveScrobblingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: focusScrobblingOverrideKey) != nil {
            switch defaults.integer(forKey: focusScrobblingOverrideKey) {
            case 0: return false
            case 1: return true
            default: break
            }
        }
        guard defaults.object(forKey: scrobblingEnabledKey) != nil else { return true }
        return defaults.bool(forKey: scrobblingEnabledKey)
    }

    private static let accentColorKey = "accentColor"
    private static let enabledTabsKey = "enabledTabs"
    private static let nowPlayingSecondaryLayoutKey = "nowPlayingSecondaryLayout"
    private static let trackSwipeLayoutKey = "trackSwipeLayout"
    private static let songsTableColumnsKey = "songsTableColumns"
    private static let demoModeKey = "demoModeEnabled"

    /// Every setting, persisted field by field as it changes.
    public private(set) var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            Self.persist(settings, changedFrom: oldValue, in: defaults)
            broadcast.send(settings)
        }
    }
    @ObservationIgnored private let broadcast = Broadcast<AppSettings>()
    @ObservationIgnored private let defaults: UserDefaults

    /// The current settings, then each change.
    public func snapshots() -> AsyncStream<AppSettings> {
        broadcast.stream(startingWith: settings)
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            AuroraVisualizationPreference.enabledKey: AuroraVisualizationPreference.defaultEnabled,
            Self.scrobblingEnabledKey: true,
            Self.demoModeKey: false
        ])
        if defaults.data(forKey: Self.enabledTabsKey)?.isEmpty ?? true,
           let encoded = try? JSONEncoder().encode([TabItem.home, .artists, .playlists, .search]) {
            defaults.set(encoded, forKey: Self.enabledTabsKey)
        }
        settings = Self.loadSettings(from: defaults)
    }

    public var accentColorName: String {
        get { settings.accentColorName }
        set { settings.accentColorName = newValue }
    }

    public var auroraVisualizationEnabled: Bool {
        get { settings.auroraVisualizationEnabled }
        set { settings.auroraVisualizationEnabled = newValue }
    }

    public var scrobblingEnabled: Bool {
        get { settings.scrobblingEnabled }
        set { settings.scrobblingEnabled = newValue }
    }

    public var demoModeEnabled: Bool {
        get { settings.demoModeEnabled }
        set {
            #if DEBUG
            settings.demoModeEnabled = newValue
            #endif
        }
    }

    public var mergingPreferences: EnsembleMergingPreferences { settings.mergingPreferences }

    public var focusScrobblingOverride: Bool? { settings.focusScrobblingOverride }

    public var effectiveScrobblingEnabled: Bool {
        focusScrobblingOverride ?? scrobblingEnabled
    }

    public func setMergingPreferences(_ preferences: EnsembleMergingPreferences) {
        if preferences != settings.mergingPreferences {
            EnsembleLogger.info(
                "Merging prefs: set on:\(preferences.isEnabled) artists:\(preferences.mergeArtists) albums:\(preferences.mergeAlbums) tracks:\(preferences.mergeTracks) playlists:\(preferences.mergePlaylists) keys:\(preferences.preferredSourceKeys.count)"
            )
        }
        settings.mergingPreferences = preferences
    }

    public func updateMergingPreferences(
        _ update: (inout EnsembleMergingPreferences) -> Void
    ) {
        var preferences = mergingPreferences
        update(&preferences)
        setMergingPreferences(preferences)
    }

    /// Applies or clears the temporary scrobbling value supplied by the active system Focus.
    public func setFocusScrobblingOverride(_ isEnabled: Bool?) {
        settings.focusScrobblingOverride = isEnabled
    }

    public var enabledTabs: [TabItem] {
        get { settings.enabledTabs }
        set { settings.enabledTabs = newValue }
    }

    public var accentColor: AppAccentColor {
        AppAccentColor(rawValue: accentColorName) ?? .blue
    }


    public var allowInsecureConnectionsPolicy: AllowInsecureConnectionsPolicy {
        get { settings.allowInsecureConnectionsPolicy }
        set { settings.allowInsecureConnectionsPolicy = newValue }
    }

    public var nowPlayingSecondaryLayout: NowPlayingSecondaryLayout {
        get { settings.nowPlayingSecondaryLayout }
        set {
            var layout = newValue
            layout.sanitize()
            settings.nowPlayingSecondaryLayout = layout
        }
    }

    public func resetNowPlayingSecondaryLayoutToDefaults() {
        nowPlayingSecondaryLayout = .default
    }

    public func setNowPlayingSecondaryAction(_ action: NowPlayingSecondaryAction?, index: Int) {
        var layout = nowPlayingSecondaryLayout
        layout.setAction(action, at: index)
        nowPlayingSecondaryLayout = layout
    }

    public var trackSwipeLayout: TrackSwipeLayout {
        get { settings.trackSwipeLayout }
        set {
            var sanitized = newValue
            sanitized.sanitize()
            settings.trackSwipeLayout = sanitized
        }
    }

    public var songsTableColumns: [SongsTableColumn] {
        get { settings.songsTableColumns }
        set {
            let deduplicated = newValue.reduce(into: [SongsTableColumn]()) { result, column in
                if !result.contains(column) {
                    result.append(column)
                }
            }
            settings.songsTableColumns = deduplicated.isEmpty ? SongsTableColumn.defaultVisibleColumns : deduplicated
        }
    }

    public func setAccentColor(_ color: AppAccentColor) {
        accentColorName = color.rawValue
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

/// Every persisted setting `SettingsManager` owns.
public struct AppSettings: Equatable, Sendable {
    public var accentColorName: String
    public var enabledTabs: [TabItem]
    public var nowPlayingSecondaryLayout: NowPlayingSecondaryLayout
    public var trackSwipeLayout: TrackSwipeLayout
    public var songsTableColumns: [SongsTableColumn]
    public var allowInsecureConnectionsPolicy: AllowInsecureConnectionsPolicy
    public var auroraVisualizationEnabled: Bool
    public var scrobblingEnabled: Bool
    public var focusScrobblingOverride: Bool?
    public var mergingPreferences: EnsembleMergingPreferences
    public var demoModeEnabled: Bool
}

extension SettingsManager {
    static func loadSettings(from defaults: UserDefaults) -> AppSettings {
        /// A payload that no longer decodes is replaced with `fallback`.
        func decoded<T: Codable>(_ key: String, fallback: T) -> T {
            guard let data = defaults.data(forKey: key), !data.isEmpty else { return fallback }
            if let value = try? JSONDecoder().decode(T.self, from: data) { return value }
            defaults.set(try? JSONEncoder().encode(fallback), forKey: key)
            return fallback
        }
        var trackSwipeLayout = decoded(trackSwipeLayoutKey, fallback: TrackSwipeLayout.default)
        trackSwipeLayout.sanitize()
        let columns = decoded(songsTableColumnsKey, fallback: [SongsTableColumn]())
        let focusOverride: Bool? = switch defaults.object(forKey: focusScrobblingOverrideKey) as? Int {
        case 0: false
        case 1: true
        default: nil
        }
        #if DEBUG
        let demoModeEnabled = defaults.bool(forKey: demoModeKey)
        #else
        let demoModeEnabled = false
        #endif
        return AppSettings(
            accentColorName: defaults.string(forKey: accentColorKey) ?? "blue",
            enabledTabs: decoded(enabledTabsKey, fallback: [TabItem.home, .songs, .artists, .playlists]),
            nowPlayingSecondaryLayout: decoded(nowPlayingSecondaryLayoutKey, fallback: NowPlayingSecondaryLayout.default),
            trackSwipeLayout: trackSwipeLayout,
            songsTableColumns: columns.isEmpty ? SongsTableColumn.defaultVisibleColumns : columns,
            allowInsecureConnectionsPolicy: defaults.string(forKey: AllowInsecureConnectionsPolicy.defaultsKey)
                .flatMap(AllowInsecureConnectionsPolicy.init(rawValue:)) ?? .defaultForEnsemble,
            auroraVisualizationEnabled: defaults.object(forKey: AuroraVisualizationPreference.enabledKey) as? Bool
                ?? AuroraVisualizationPreference.defaultEnabled,
            scrobblingEnabled: defaults.object(forKey: scrobblingEnabledKey) as? Bool ?? true,
            focusScrobblingOverride: focusOverride,
            mergingPreferences: storedMergingPreferences(in: defaults),
            demoModeEnabled: demoModeEnabled
        )
    }

    static func persist(_ settings: AppSettings, changedFrom old: AppSettings, in defaults: UserDefaults) {
        func store<T: Encodable & Equatable>(_ keyPath: KeyPath<AppSettings, T>, _ key: String) {
            guard settings[keyPath: keyPath] != old[keyPath: keyPath],
                  let data = try? JSONEncoder().encode(settings[keyPath: keyPath]) else { return }
            defaults.set(data, forKey: key)
        }
        func set<T: Equatable>(_ keyPath: KeyPath<AppSettings, T>, _ key: String, _ value: (T) -> Any) {
            guard settings[keyPath: keyPath] != old[keyPath: keyPath] else { return }
            defaults.set(value(settings[keyPath: keyPath]), forKey: key)
        }
        set(\.accentColorName, accentColorKey) { $0 }
        store(\.enabledTabs, enabledTabsKey)
        store(\.nowPlayingSecondaryLayout, nowPlayingSecondaryLayoutKey)
        store(\.trackSwipeLayout, trackSwipeLayoutKey)
        store(\.songsTableColumns, songsTableColumnsKey)
        set(\.allowInsecureConnectionsPolicy, AllowInsecureConnectionsPolicy.defaultsKey) { $0.rawValue }
        set(\.auroraVisualizationEnabled, AuroraVisualizationPreference.enabledKey) { $0 }
        set(\.scrobblingEnabled, scrobblingEnabledKey) { $0 }
        set(\.focusScrobblingOverride, focusScrobblingOverrideKey) { $0.map { $0 ? 1 : 0 } ?? noFocusScrobblingOverride }
        set(\.demoModeEnabled, demoModeKey) { $0 }
        if settings.mergingPreferences != old.mergingPreferences {
            setStoredMergingPreferences(settings.mergingPreferences, in: defaults)
        }
    }
}
