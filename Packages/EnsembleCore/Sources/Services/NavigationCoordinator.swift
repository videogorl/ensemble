import SwiftUI
import Combine
import os

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

    // Per-tab NowPlaying push destinations. Each tab gets its own @Published
    // property so the modifier can subscribe via onReceive (Combine) which fires
    // independently of SwiftUI's view re-rendering — working around the iOS 18+
    // .sidebarAdaptable TabView bug where binding observation is broken.
    @Published public var homeNowPlayingDest: Destination?
    @Published public var songsNowPlayingDest: Destination?
    @Published public var artistsNowPlayingDest: Destination?
    @Published public var albumsNowPlayingDest: Destination?
    @Published public var genresNowPlayingDest: Destination?
    @Published public var playlistsNowPlayingDest: Destination?
    @Published public var favoritesNowPlayingDest: Destination?
    @Published public var searchNowPlayingDest: Destination?
    @Published public var downloadsNowPlayingDest: Destination?
    @Published public var settingsNowPlayingDest: Destination?

    /// Set the NowPlaying push destination for a specific tab only.
    public func setNowPlayingDestination(_ dest: Destination, for tab: TabItem) {
        switch tab {
        case .home: homeNowPlayingDest = dest
        case .songs: songsNowPlayingDest = dest
        case .artists: artistsNowPlayingDest = dest
        case .albums: albumsNowPlayingDest = dest
        case .genres: genresNowPlayingDest = dest
        case .playlists: playlistsNowPlayingDest = dest
        case .favorites: favoritesNowPlayingDest = dest
        case .search: searchNowPlayingDest = dest
        case .downloads: downloadsNowPlayingDest = dest
        case .settings: settingsNowPlayingDest = dest
        }
    }

    /// Clear the NowPlaying push destination after it's been consumed.
    public func clearNowPlayingDest(for tab: TabItem) {
        switch tab {
        case .home: homeNowPlayingDest = nil
        case .songs: songsNowPlayingDest = nil
        case .artists: artistsNowPlayingDest = nil
        case .albums: albumsNowPlayingDest = nil
        case .genres: genresNowPlayingDest = nil
        case .playlists: playlistsNowPlayingDest = nil
        case .favorites: favoritesNowPlayingDest = nil
        case .search: searchNowPlayingDest = nil
        case .downloads: downloadsNowPlayingDest = nil
        case .settings: settingsNowPlayingDest = nil
        }
    }

    /// Combine publisher for a specific tab's NowPlaying destination.
    /// Used by NowPlayingPushModifier to detect changes via onReceive.
    public func nowPlayingDestPublisher(for tab: TabItem) -> Published<Destination?>.Publisher {
        switch tab {
        case .home: return $homeNowPlayingDest
        case .songs: return $songsNowPlayingDest
        case .artists: return $artistsNowPlayingDest
        case .albums: return $albumsNowPlayingDest
        case .genres: return $genresNowPlayingDest
        case .playlists: return $playlistsNowPlayingDest
        case .favorites: return $favoritesNowPlayingDest
        case .search: return $searchNowPlayingDest
        case .downloads: return $downloadsNowPlayingDest
        case .settings: return $settingsNowPlayingDest
        }
    }

    #if DEBUG
    private let logger = Logger(subsystem: "com.ensemble", category: "NavigationCoordinator")
    #endif

    public init() {}
    
    // MARK: - Navigation Methods
    
    /// Push a destination onto a specific tab's stack
    public func push(_ destination: Destination, in tab: TabItem) {
        // No-op if already viewing same item as last in stack
        guard path(for: tab).last != destination else {
            #if DEBUG
            logger.debug("🧭 push SKIPPED (duplicate): \(String(describing: destination)) in \(String(describing: tab))")
            #endif
            return
        }

        #if DEBUG
        logger.debug("🧭 push: \(String(describing: destination)) in \(String(describing: tab)), pathCount before: \(self.path(for: tab).count)")
        #endif

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

        #if DEBUG
        logger.debug("🧭 push DONE, pathCount after: \(self.path(for: tab).count)")
        #endif
    }
    
    /// Pop to root for a specific tab
    public func popToRoot(tab: TabItem) {
        #if DEBUG
        logger.debug("🧭 popToRoot: \(String(describing: tab)), pathCount was: \(self.path(for: tab).count)")
        #endif
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
        #if DEBUG
        logger.debug("🧭 navigate(to:): dest=\(String(describing: destination)), selectedTab=\(String(describing: self.selectedTab)), targetTab=\(String(describing: targetTab))")
        #endif
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
