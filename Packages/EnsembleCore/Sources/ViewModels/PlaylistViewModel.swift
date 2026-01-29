import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

@MainActor
public final class PlaylistViewModel: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let apiClient: PlexAPIClient
    private let playlistRepository: PlaylistRepositoryProtocol

    public init(
        apiClient: PlexAPIClient,
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.apiClient = apiClient
        self.playlistRepository = playlistRepository
    }

    public func loadPlaylists() async {
        isLoading = true
        error = nil

        do {
            // Load from cache first
            let cached = try await playlistRepository.fetchPlaylists()
            if !cached.isEmpty {
                playlists = cached.map { Playlist(from: $0) }
            }

            // Fetch from API
            let plexPlaylists = try await apiClient.getPlaylists()
            playlists = plexPlaylists.map { Playlist(from: $0) }

            // Update cache
            for playlist in plexPlaylists {
                _ = try await playlistRepository.upsertPlaylist(
                    ratingKey: playlist.ratingKey,
                    key: playlist.key,
                    title: playlist.title,
                    summary: playlist.summary,
                    compositePath: playlist.composite,
                    isSmart: playlist.smart ?? false,
                    duration: playlist.duration,
                    trackCount: playlist.leafCount
                )
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Playlist Detail ViewModel

@MainActor
public final class PlaylistDetailViewModel: ObservableObject {
    @Published public private(set) var playlist: Playlist
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let apiClient: PlexAPIClient
    private let playlistRepository: PlaylistRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        playlist: Playlist,
        apiClient: PlexAPIClient,
        playlistRepository: PlaylistRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.playlist = playlist
        self.apiClient = apiClient
        self.playlistRepository = playlistRepository
        self.libraryRepository = libraryRepository
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            // Load from cache
            if let cached = try await playlistRepository.fetchPlaylist(ratingKey: playlist.id) {
                let cachedTracks = cached.tracksArray
                if !cachedTracks.isEmpty {
                    tracks = cachedTracks.map { Track(from: $0) }
                }
            }

            // Fetch from API
            let plexTracks = try await apiClient.getPlaylistTracks(playlistKey: playlist.id)
            tracks = plexTracks.map { Track(from: $0) }

            // Update cache - first upsert tracks, then update playlist relationship
            var trackKeys: [String] = []
            for track in plexTracks {
                _ = try await libraryRepository.upsertTrack(
                    ratingKey: track.ratingKey,
                    key: track.key,
                    title: track.title,
                    artistName: track.grandparentTitle,
                    albumName: track.parentTitle,
                    albumRatingKey: track.parentRatingKey,
                    trackNumber: track.index,
                    discNumber: track.parentIndex,
                    duration: track.duration,
                    thumbPath: track.thumb ?? track.parentThumb,
                    streamKey: track.streamURL
                )
                trackKeys.append(track.ratingKey)
            }

            try await playlistRepository.setPlaylistTracks(trackKeys, forPlaylist: playlist.id)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public var totalDuration: String {
        let total = tracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(minutes) min"
    }
}
