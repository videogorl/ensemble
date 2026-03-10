import SwiftUI
import Combine

/// Centralized navigation coordinator for handling deep links and cross-tab navigation
@MainActor
public final class NavigationCoordinator: ObservableObject {
    /// Represents a navigation destination using IDs for hashability and deep linking
    public enum Destination: Hashable {
        case artist(id: String)
        case album(id: String)
        case playlist(id: String, sourceKey: String?)
        case moodTracks(mood: Mood)
        case view(TabItem) // For pushing library views from the More menu
    }
    
    /// The currently selected tab
    @Published public var selectedTab: TabItem = .home

    /// Visible tabs in the tab bar (synced from MainTabView to enable fallback logic)
    public var visibleTabs: [TabItem] = [.home, .artists, .playlists, .search]

    // Per-tab navigation paths (strictly typed as [Destination] for iOS 15+ compatibility)
    @Published public var homePath: [Destination] = []
    @Published public var songsPath: [Destination] = []
    @Published public var artistsPath: [Destination] = []
    @Published public var albumsPath: [Destination] = []
    @Published public var genresPath: [Destination] = []
    @Published public var playlistsPath: [Destination] = []
    @Published public var favoritesPath: [Destination] = []
    @Published public var searchPath: [Destination] = []
    @Published public var downloadsPath: [Destination] = []
    @Published public var settingsPath: [Destination] = []
    
    /// Drives the "Add Plex Account" sheet from a stable root-level view
    /// (MainTabView / SidebarView) so it survives TabView content recreation.
    @Published public var showingAddAccount = false

    /// For NowPlaying flow: pending navigation to execute after sheet dismissal
    public struct PendingNavigation {
        public let tab: TabItem
        public let destination: Destination
        
        public init(tab: TabItem, destination: Destination) {
            self.tab = tab
            self.destination = destination
        }
    }
    
    @Published public var pendingNavigation: PendingNavigation?
    
    public init() {}
    
    // MARK: - Navigation Methods
    
    /// Push a destination onto a specific tab's stack
    public func push(_ destination: Destination, in tab: TabItem) {
        // No-op if already viewing same item as last in stack
        guard path(for: tab).last != destination else { return }
        
        switch tab {
        case .home: homePath.append(destination)
        case .songs: songsPath.append(destination)
        case .artists: artistsPath.append(destination)
        case .albums: albumsPath.append(destination)
        case .genres: genresPath.append(destination)
        case .playlists: playlistsPath.append(destination)
        case .favorites: favoritesPath.append(destination)
        case .search: searchPath.append(destination)
        case .downloads: downloadsPath.append(destination)
        case .settings: settingsPath.append(destination)
        }
    }
    
    /// Pop to root for a specific tab
    public func popToRoot(tab: TabItem) {
        switch tab {
        case .home: homePath.removeAll()
        case .songs: songsPath.removeAll()
        case .artists: artistsPath.removeAll()
        case .albums: albumsPath.removeAll()
        case .genres: genresPath.removeAll()
        case .playlists: playlistsPath.removeAll()
        case .favorites: favoritesPath.removeAll()
        case .search: searchPath.removeAll()
        case .downloads: downloadsPath.removeAll()
        case .settings: settingsPath.removeAll()
        }
    }
    
    /// Request navigation immediately (using current tab or fallback)
    public func navigate(to destination: Destination) {
        let targetTab: TabItem
        if selectedTab == .search {
            targetTab = visibleTabs.first ?? .home
        } else {
            targetTab = selectedTab
        }
        selectedTab = targetTab
        push(destination, in: targetTab)
    }
    
    /// Request navigation from NowPlaying sheet (handles dismiss-then-navigate)
    /// Uses current tab (or first visible if currently in Search)
    public func navigateFromNowPlaying(to destination: Destination) {
        let targetTab: TabItem
        if selectedTab == .search {
            targetTab = visibleTabs.first ?? .home
        } else {
            targetTab = selectedTab
        }
        pendingNavigation = PendingNavigation(tab: targetTab, destination: destination)
    }
    
    /// Handle deep links by popping to root of the first visible tab and pushing the new destination
    public func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "ensemble" else { return false }
        
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        
        let type = components[0]
        let id = components[1]
        
        let destination: Destination
        switch type {
        case "artist":
            destination = .artist(id: id)
        case "album":
            destination = .album(id: id)
        case "playlist":
            destination = .playlist(id: id, sourceKey: nil)
        default:
            return false
        }
        
        // Deep links always go to the first visible tab
        let targetTab = visibleTabs.first ?? .home

        // Pop to root of the target tab first for a clean state
        popToRoot(tab: targetTab)

        // Switch tab and push
        selectedTab = targetTab
        push(destination, in: targetTab)
        
        return true
    }
    
    // MARK: - Helper Methods

    private func path(for tab: TabItem) -> [Destination] {
        switch tab {
        case .home: return homePath
        case .songs: return songsPath
        case .artists: return artistsPath
        case .albums: return albumsPath
        case .genres: return genresPath
        case .playlists: return playlistsPath
        case .favorites: return favoritesPath
        case .search: return searchPath
        case .downloads: return downloadsPath
        case .settings: return settingsPath
        }
    }
}
