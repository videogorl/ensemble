import EnsembleAPI
import Foundation

/// Radio provider for Plex music sources
/// Implements radio features using Plex's sonic analysis and recommendation APIs
public final class PlexRadioProvider: MusicSourceRadioProviding, @unchecked Sendable {
    public let sourceKey: String
    private let apiClient: PlexAPIClient
    private let sectionKey: String

    public init(
        sourceKey: String,
        apiClient: PlexAPIClient,
        sectionKey: String
    ) {
        self.sourceKey = sourceKey
        self.apiClient = apiClient
        self.sectionKey = sectionKey
    }

    public func getRecommendedTracks(
        basedOn track: Track,
        limit: Int
    ) async -> [Track]? {
        do {
            return try await apiClient.getTrackRadio(ratingKey: track.id)
                .prefix(max(0, limit))
                .map { Track(from: $0, sourceKey: sourceKey) }
        } catch {
            EnsembleLogger.debug("Track Radio request failed: \(error.localizedDescription)")
            return nil
        }
    }

    public func getArtistRadio(for artist: Artist) async -> [Track]? {
        EnsembleLogger.debug("🎙️ PlexRadioProvider.getArtistRadio() called")
        EnsembleLogger.debug("  - Artist: \(artist.name)")
        EnsembleLogger.debug("  - Artist ID: \(artist.id)")
        
        do {
            // Get artist radio station playlist from Plex
            EnsembleLogger.debug("🔄 Calling apiClient.getArtistRadioStation...")
            guard let station = try await apiClient.getArtistRadioStation(artistKey: artist.id) else {
                EnsembleLogger.debug("ℹ️ PlexRadioProvider: No artist radio available for \(artist.name)")
                return nil
            }
            EnsembleLogger.debug("✅ Got artist radio station: \(station.title)")
            EnsembleLogger.debug("  - Station playlist key: \(station.ratingKey)")

            // Fetch tracks from the playlist
            EnsembleLogger.debug("🔄 Fetching tracks from playlist...")
            let plexTracks = try await apiClient.getPlaylistTracks(playlistKey: station.ratingKey)
            EnsembleLogger.debug("✅ Fetched \(plexTracks.count) plex tracks")
            
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            EnsembleLogger.debug("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks for artist radio")
            return tracks
        } catch {
            EnsembleLogger.debug("❌ PlexRadioProvider.getArtistRadio error: \(error)")
            return nil
        }
    }

    public func getAlbumRadio(for album: Album) async -> [Track]? {
        EnsembleLogger.debug("🎙️ PlexRadioProvider.getAlbumRadio() called")
        EnsembleLogger.debug("  - Album: \(album.title)")
        EnsembleLogger.debug("  - Album ID: \(album.id)")
        
        do {
            // Get album radio station playlist from Plex
            EnsembleLogger.debug("🔄 Calling apiClient.getAlbumRadioStation...")
            guard let station = try await apiClient.getAlbumRadioStation(albumKey: album.id) else {
                EnsembleLogger.debug("ℹ️ PlexRadioProvider: No album radio available for \(album.title)")
                return nil
            }
            EnsembleLogger.debug("✅ Got album radio station: \(station.title)")
            EnsembleLogger.debug("  - Station playlist key: \(station.ratingKey)")

            // Fetch tracks from the playlist
            EnsembleLogger.debug("🔄 Fetching tracks from playlist...")
            let plexTracks = try await apiClient.getPlaylistTracks(playlistKey: station.ratingKey)
            EnsembleLogger.debug("✅ Fetched \(plexTracks.count) plex tracks")
            
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            EnsembleLogger.debug("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks for album radio")
            return tracks
        } catch {
            EnsembleLogger.debug("❌ PlexRadioProvider.getAlbumRadio error: \(error)")
            return nil
        }
    }

    public func getLibraryRadio(limit: Int) async -> [Track]? {
        do {
            // Library Radio: Get popular tracks (based on play count or rating)
            let plexTracks = try await apiClient.getTracks(sectionKey: sectionKey)

            // Filter for tracks with high play counts or ratings
            let popularTracks = plexTracks.filter { track in
                let viewCount = track.viewCount ?? 0
                let rating = track.userRating ?? 0.0
                return viewCount > 3 || rating >= 8.0  // 4+ stars or 3+ plays
            }

            // Shuffle and limit
            let shuffled = popularTracks.shuffled().prefix(limit)
            let tracks = shuffled.map { Track(from: $0, sourceKey: sourceKey) }

            EnsembleLogger.debug("✅ PlexRadioProvider: Got \(tracks.count) tracks for library radio")
            return Array(tracks)
        } catch {
            EnsembleLogger.debug("❌ PlexRadioProvider.getLibraryRadio error: \(error)")
            return nil
        }
    }

    public func getTimeTravelRadio(limit: Int) async -> [Track]? {
        do {
            // Time Travel Radio: Chronological playback by date added
            let plexTracks = try await apiClient.getTracks(sectionKey: sectionKey)

            // Sort by addedAt timestamp ascending (oldest added first)
            let sortedByDate = plexTracks.sorted { (track1: PlexTrack, track2: PlexTrack) -> Bool in
                let date1 = track1.addedAt ?? 0
                let date2 = track2.addedAt ?? 0
                return date1 < date2
            }

            // Take first N tracks
            let timeTravelTracks = sortedByDate.prefix(limit)
            let tracks = timeTravelTracks.map { Track(from: $0, sourceKey: sourceKey) }

            EnsembleLogger.debug("✅ PlexRadioProvider: Got \(tracks.count) tracks for time travel radio")
            return Array(tracks)
        } catch {
            EnsembleLogger.debug("❌ PlexRadioProvider.getTimeTravelRadio error: \(error)")
            return nil
        }
    }

    public var isAvailable: Bool {
        get async {
            // Radio features require Plex Pass and sonic analysis
            // We can check if sonic similar tracks API works as a proxy
            // For now, assume available (will fail gracefully if not)
            return true
        }
    }
}
