import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

@MainActor
public final class ArtistDetailViewModel: ObservableObject {
    @Published public private(set) var artist: Artist
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let apiClient: PlexAPIClient
    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        artist: Artist,
        apiClient: PlexAPIClient,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.artist = artist
        self.apiClient = apiClient
        self.libraryRepository = libraryRepository
    }

    public func loadAlbums() async {
        isLoading = true
        error = nil

        do {
            // Try to load from cache first
            let cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artist.id)

            if !cachedAlbums.isEmpty {
                albums = cachedAlbums.map { Album(from: $0) }
            }

            // Fetch from API
            let plexAlbums = try await apiClient.getArtistAlbums(artistKey: artist.id)
            albums = plexAlbums.map { Album(from: $0) }

            // Update cache
            for album in plexAlbums {
                _ = try await libraryRepository.upsertAlbum(
                    ratingKey: album.ratingKey,
                    key: album.key,
                    title: album.title,
                    artistName: album.parentTitle,
                    artistRatingKey: artist.id,
                    summary: album.summary,
                    thumbPath: album.thumb,
                    artPath: album.art,
                    year: album.year,
                    trackCount: album.leafCount
                )
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
