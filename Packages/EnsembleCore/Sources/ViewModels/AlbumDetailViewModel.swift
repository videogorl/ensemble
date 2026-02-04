import Combine
import EnsemblePersistence
import Foundation

// MARK: - Protocol

@MainActor
public protocol MediaDetailViewModelProtocol: ObservableObject {
    var tracks: [Track] { get }
    var isLoading: Bool { get }
    var error: String? { get }
    var totalDuration: String { get }
    
    func loadTracks() async
}

// MARK: - Album Detail ViewModel

@MainActor
public final class AlbumDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var album: Album
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        album: Album,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.album = album
        self.libraryRepository = libraryRepository
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            let cachedTracks = try await libraryRepository.fetchTracks(forAlbum: album.id)
            tracks = cachedTracks.map { Track(from: $0) }
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
