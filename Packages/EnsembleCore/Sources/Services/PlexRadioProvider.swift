import EnsembleAPI
import EnsemblePersistence
import Foundation

/// Radio provider for Plex music sources
/// Implements radio features using Plex's sonic analysis and recommendation APIs
public final class PlexRadioProvider: RadioProviderProtocol {
    public let sourceKey: String
    private let apiClient: PlexAPIClient
    private let libraryRepository: LibraryRepositoryProtocol
    private let sectionKey: String

    public init(
        sourceKey: String,
        apiClient: PlexAPIClient,
        libraryRepository: LibraryRepositoryProtocol,
        sectionKey: String
    ) {
        self.sourceKey = sourceKey
        self.apiClient = apiClient
        self.libraryRepository = libraryRepository
        self.sectionKey = sectionKey
    }

    // MARK: - RadioProviderProtocol

    public func getRecommendedTracks(
        basedOn track: Track,
        limit: Int
    ) async -> [Track]? {
        EnsembleLogger.debug("\n🎙️ PlexRadioProvider.getRecommendedTracks()")
        EnsembleLogger.debug("  - track.id (ratingKey): \(track.id)")
        EnsembleLogger.debug("  - track.title: \(track.title)")
        EnsembleLogger.debug("  - sourceKey: \(sourceKey)")
        EnsembleLogger.debug("  - limit: \(limit)")
        
        do {
            EnsembleLogger.debug("🔄 Calling apiClient.getSimilarTracks()...")
            // Use Plex's /nearest endpoint for sonic recommendations
            guard let plexTracks = try await apiClient.getSimilarTracks(
                ratingKey: track.id,
                limit: limit,
                maxDistance: 0.25  // Lower = more similar (0.0-1.0)
            ) else {
                EnsembleLogger.debug("⚠️ getSimilarTracks returned nil (no sonic analysis available)")
                return nil
            }

            EnsembleLogger.debug("✅ getSimilarTracks returned \(plexTracks.count) plex tracks")
            
            // Convert PlexTrack to Track domain models
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            EnsembleLogger.debug("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks")
            
            if tracks.isEmpty {
                EnsembleLogger.debug("⚠️ WARNING: Conversion resulted in empty array")
            } else {
                // Log first few recommendations as confirmation
                for track in tracks.prefix(5) {
                    EnsembleLogger.debug("  ✅ Radio: \(track.title) by \(track.artistName ?? "Unknown")")
                }
                if tracks.count > 5 {
                    EnsembleLogger.debug("  ... and \(tracks.count - 5) more tracks")
                }
            }
            
            return tracks
        } catch {
            EnsembleLogger.debug("❌ PlexRadioProvider.getRecommendedTracks() ERROR:")
            EnsembleLogger.debug("   Type: \(type(of: error))")
            EnsembleLogger.debug("   localizedDescription: \(error.localizedDescription)")
            let nsError = error as NSError
            EnsembleLogger.debug("   NSError domain: \(nsError.domain)")
            EnsembleLogger.debug("   Code: \(nsError.code)")
            EnsembleLogger.debug("   UserInfo: \(nsError.userInfo)")
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
