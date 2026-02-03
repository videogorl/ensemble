import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class ArtistDetailViewModel: ObservableObject {
    @Published public private(set) var artist: Artist
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        artist: Artist,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.artist = artist
        self.libraryRepository = libraryRepository
    }

    public func loadAlbums() async {
        isLoading = true
        error = nil

        do {
            let cachedAlbums = try await libraryRepository.fetchAlbums(forArtist: artist.id)
            albums = cachedAlbums.map { Album(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}
