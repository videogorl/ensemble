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
        pendingDestination = .artist(artist)
    }
    
    /// Request navigation to an album
    public func navigateToAlbum(_ album: Album) {
        pendingDestination = .album(album)
    }
    
    /// Request navigation to a playlist
    public func navigateToPlaylist(_ playlist: Playlist) {
        pendingDestination = .playlist(playlist)
    }
    
    /// Clear the pending destination after navigation is handled
    public func clearDestination() {
        pendingDestination = nil
    }
}
