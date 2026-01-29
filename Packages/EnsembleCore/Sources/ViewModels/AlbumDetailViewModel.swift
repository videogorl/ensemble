import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

@MainActor
public final class AlbumDetailViewModel: ObservableObject {
    @Published public private(set) var album: Album
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let apiClient: PlexAPIClient
    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        album: Album,
        apiClient: PlexAPIClient,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.album = album
        self.apiClient = apiClient
        self.libraryRepository = libraryRepository
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            // Try to load from cache first
            let cachedTracks = try await libraryRepository.fetchTracks(forAlbum: album.id)

            if !cachedTracks.isEmpty {
                tracks = cachedTracks.map { Track(from: $0) }
            }

            // Fetch from API
            let plexTracks = try await apiClient.getAlbumTracks(albumKey: album.id)
            tracks = plexTracks.map { Track(from: $0) }

            // Update cache
            for track in plexTracks {
                _ = try await libraryRepository.upsertTrack(
                    ratingKey: track.ratingKey,
                    key: track.key,
                    title: track.title,
                    artistName: track.grandparentTitle,
                    albumName: track.parentTitle,
                    albumRatingKey: album.id,
                    trackNumber: track.index,
                    discNumber: track.parentIndex,
                    duration: track.duration,
                    thumbPath: track.thumb ?? track.parentThumb,
                    streamKey: track.streamURL
                )
            }
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
