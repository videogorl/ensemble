import Foundation
import Combine

/// Centralized navigation coordinator for handling deep links and cross-tab navigation
@MainActor
public final class NavigationCoordinator: ObservableObject {
    /// Represents a navigation destination
    public enum Destination: Equatable {
        case artist(Artist)
        case album(Album)
        case playlist(Playlist)
    }
    
    /// Published destination that views can observe
    @Published public var pendingDestination: Destination?
    
    public init() {}
    
    /// Request navigation to an artist
    public func navigateToArtist(_ artist: Artist) {
        print("🧭 NavigationCoordinator: navigateToArtist called for: \(artist.name)")
        pendingDestination = .artist(artist)
        print("🧭 NavigationCoordinator: pendingDestination set to artist")
    }
    
    /// Request navigation to an album
    public func navigateToAlbum(_ album: Album) {
        print("🧭 NavigationCoordinator: navigateToAlbum called for: \(album.title)")
        pendingDestination = .album(album)
        print("🧭 NavigationCoordinator: pendingDestination set to album")
    }
    
    /// Request navigation to a playlist
    public func navigateToPlaylist(_ playlist: Playlist) {
        print("🧭 NavigationCoordinator: navigateToPlaylist called for: \(playlist.title)")
        pendingDestination = .playlist(playlist)
        print("🧭 NavigationCoordinator: pendingDestination set to playlist")
    }
    
    /// Clear the pending destination after navigation is handled
    public func clearDestination() {
        pendingDestination = nil
    }
}
