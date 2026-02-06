import SwiftUI
import Combine

/// Centralized navigation coordinator for handling deep links and cross-tab navigation
@MainActor
public final class NavigationCoordinator: ObservableObject {
    /// Represents a navigation destination using IDs for hashability and deep linking
    public enum Destination: Hashable {
        case artist(id: String)
        case album(id: String)
        case playlist(id: String)
    }
    
    /// The currently selected tab
    @Published public var selectedTab: TabItem = .home

    /// Visible tabs in the tab bar (first 4). Set by MainTabView to enable fallback logic.
    public var visibleTabs: [TabItem] = [.home, .artists, .playlists, .search]

    // Per-tab navigation paths (strictly typed as [Destination] for iOS 15+ compatibility)
    @Published public var homePath: [Destination] = []
    @Published public var artistsPath: [Destination] = []
    @Published public var albumsPath: [Destination] = []
    @Published public var playlistsPath: [Destination] = []
    @Published public var searchPath: [Destination] = []
    
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
    
    // Legacy support (maintained during transition, to be removed)
    @Published public var pendingDestination: Destination?
    
    public init() {}
    
    // MARK: - Navigation Methods
    
    /// Push a destination onto a specific tab's stack
    public func push(_ destination: Destination, in tab: TabItem) {
        // No-op if already viewing same item as last in stack
        guard path(for: tab).last != destination else { return }
        
        switch tab {
        case .home: homePath.append(destination)
        case .artists: artistsPath.append(destination)
        case .albums: albumsPath.append(destination)
        case .playlists: playlistsPath.append(destination)
        case .search: searchPath.append(destination)
        default: break
        }
    }
    
    /// Pop to root for a specific tab
    public func popToRoot(tab: TabItem) {
        switch tab {
        case .home: homePath.removeAll()
        case .artists: artistsPath.removeAll()
        case .albums: albumsPath.removeAll()
        case .playlists: playlistsPath.removeAll()
        case .search: searchPath.removeAll()
        default: break
        }
    }
    
    /// Request navigation from NowPlaying sheet (handles dismiss-then-navigate)
    public func navigateFromNowPlaying(to destination: Destination, in tab: TabItem) {
        pendingNavigation = PendingNavigation(tab: tab, destination: destination)
    }
    
    /// Handle deep links by popping to root and pushing the new destination
    public func handleDeepLink(_ url: URL) -> Bool {
        guard url.scheme == "ensemble" else { return false }
        
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return false }
        
        let type = components[0]
        let id = components[1]
        
        let destination: Destination
        let tab: TabItem
        
        switch type {
        case "artist":
            destination = .artist(id: id)
            tab = .artists
        case "album":
            destination = .album(id: id)
            tab = .albums
        case "playlist":
            destination = .playlist(id: id)
            tab = .playlists
        default:
            return false
        }
        
        // Resolve to visible tab (fallback to Home if target is hidden in "More")
        let targetTab = resolveTab(tab)

        // Pop to root of the target tab first for a clean state
        popToRoot(tab: targetTab)

        // Switch tab and push
        selectedTab = targetTab
        push(destination, in: targetTab)
        
        return true
    }
    
    // MARK: - Helper Methods

    /// Returns the target tab if visible, otherwise falls back to Home
    private func resolveTab(_ tab: TabItem) -> TabItem {
        visibleTabs.contains(tab) ? tab : .home
    }

    private func path(for tab: TabItem) -> [Destination] {
        switch tab {
        case .home: return homePath
        case .artists: return artistsPath
        case .albums: return albumsPath
        case .playlists: return playlistsPath
        case .search: return searchPath
        default: return []
        }
    }
    
    // Legacy mapping methods (to keep old code compiling during transition)
    public func navigateToArtist(_ artist: Artist) {
        let tab = resolveTab(.artists)
        push(.artist(id: artist.id), in: tab)
        selectedTab = tab
    }

    public func navigateToAlbum(_ album: Album) {
        let tab = resolveTab(.albums)
        push(.album(id: album.id), in: tab)
        selectedTab = tab
    }

    public func navigateToPlaylist(_ playlist: Playlist) {
        let tab = resolveTab(.playlists)
        push(.playlist(id: playlist.id), in: tab)
        selectedTab = tab
    }
    
    public func clearDestination() {
        pendingDestination = nil
    }
}