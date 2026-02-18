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
        #if DEBUG
        print("\n🎙️ PlexRadioProvider.getRecommendedTracks()")
        print("  - track.id (ratingKey): \(track.id)")
        print("  - track.title: \(track.title)")
        print("  - sourceKey: \(sourceKey)")
        print("  - limit: \(limit)")
        #endif
        
        do {
            #if DEBUG
            print("🔄 Calling apiClient.getSimilarTracks()...")
            #endif
            // Use Plex's /nearest endpoint for sonic recommendations
            guard let plexTracks = try await apiClient.getSimilarTracks(
                ratingKey: track.id,
                limit: limit,
                maxDistance: 0.25  // Lower = more similar (0.0-1.0)
            ) else {
                #if DEBUG
                print("⚠️ getSimilarTracks returned nil (no sonic analysis available)")
                #endif
                return nil
            }

            #if DEBUG
            print("✅ getSimilarTracks returned \(plexTracks.count) plex tracks")
            #endif
            
            // Convert PlexTrack to Track domain models
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            #if DEBUG
            print("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks")
            #endif
            
            if tracks.isEmpty {
                #if DEBUG
                print("⚠️ WARNING: Conversion resulted in empty array")
                #endif
            } else {
                // Log first few recommendations as confirmation
                for track in tracks.prefix(5) {
                    #if DEBUG
                    print("  ✅ Radio: \(track.title) by \(track.artistName ?? "Unknown")")
                    #endif
                }
                if tracks.count > 5 {
                    #if DEBUG
                    print("  ... and \(tracks.count - 5) more tracks")
                    #endif
                }
            }
            
            return tracks
        } catch {
            #if DEBUG
            print("❌ PlexRadioProvider.getRecommendedTracks() ERROR:")
            print("   Type: \(type(of: error))")
            print("   localizedDescription: \(error.localizedDescription)")
            #endif
            if let nsError = error as? NSError {
                #if DEBUG
                print("   NSError domain: \(nsError.domain)")
                print("   Code: \(nsError.code)")
                print("   UserInfo: \(nsError.userInfo)")
                #endif
            }
            return nil
        }
    }

    public func getArtistRadio(for artist: Artist) async -> [Track]? {
        #if DEBUG
        print("🎙️ PlexRadioProvider.getArtistRadio() called")
        print("  - Artist: \(artist.name)")
        print("  - Artist ID: \(artist.id)")
        #endif
        
        do {
            // Get artist radio station playlist from Plex
            #if DEBUG
            print("🔄 Calling apiClient.getArtistRadioStation...")
            #endif
            guard let station = try await apiClient.getArtistRadioStation(artistKey: artist.id) else {
                #if DEBUG
                print("ℹ️ PlexRadioProvider: No artist radio available for \(artist.name)")
                #endif
                return nil
            }
            #if DEBUG
            print("✅ Got artist radio station: \(station.title)")
            print("  - Station playlist key: \(station.ratingKey)")
            #endif

            // Fetch tracks from the playlist
            #if DEBUG
            print("🔄 Fetching tracks from playlist...")
            #endif
            let plexTracks = try await apiClient.getPlaylistTracks(playlistKey: station.ratingKey)
            #if DEBUG
            print("✅ Fetched \(plexTracks.count) plex tracks")
            #endif
            
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            #if DEBUG
            print("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks for artist radio")
            #endif
            return tracks
        } catch {
            #if DEBUG
            print("❌ PlexRadioProvider.getArtistRadio error: \(error)")
            #endif
            return nil
        }
    }

    public func getAlbumRadio(for album: Album) async -> [Track]? {
        #if DEBUG
        print("🎙️ PlexRadioProvider.getAlbumRadio() called")
        print("  - Album: \(album.title)")
        print("  - Album ID: \(album.id)")
        #endif
        
        do {
            // Get album radio station playlist from Plex
            #if DEBUG
            print("🔄 Calling apiClient.getAlbumRadioStation...")
            #endif
            guard let station = try await apiClient.getAlbumRadioStation(albumKey: album.id) else {
                #if DEBUG
                print("ℹ️ PlexRadioProvider: No album radio available for \(album.title)")
                #endif
                return nil
            }
            #if DEBUG
            print("✅ Got album radio station: \(station.title)")
            print("  - Station playlist key: \(station.ratingKey)")
            #endif

            // Fetch tracks from the playlist
            #if DEBUG
            print("🔄 Fetching tracks from playlist...")
            #endif
            let plexTracks = try await apiClient.getPlaylistTracks(playlistKey: station.ratingKey)
            #if DEBUG
            print("✅ Fetched \(plexTracks.count) plex tracks")
            #endif
            
            let tracks = plexTracks.map { Track(from: $0, sourceKey: sourceKey) }
            #if DEBUG
            print("✅ PlexRadioProvider: Converted to \(tracks.count) domain tracks for album radio")
            #endif
            return tracks
        } catch {
            #if DEBUG
            print("❌ PlexRadioProvider.getAlbumRadio error: \(error)")
            #endif
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

            #if DEBUG
            print("✅ PlexRadioProvider: Got \(tracks.count) tracks for library radio")
            #endif
            return Array(tracks)
        } catch {
            #if DEBUG
            print("❌ PlexRadioProvider.getLibraryRadio error: \(error)")
            #endif
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

            #if DEBUG
            print("✅ PlexRadioProvider: Got \(tracks.count) tracks for time travel radio")
            #endif
            return Array(tracks)
        } catch {
            #if DEBUG
            print("❌ PlexRadioProvider.getTimeTravelRadio error: \(error)")
            #endif
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
