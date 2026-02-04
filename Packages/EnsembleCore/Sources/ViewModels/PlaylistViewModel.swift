import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class PlaylistViewModel: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var playlistSortOption: PlaylistSortOption = .title

    private let playlistRepository: PlaylistRepositoryProtocol

    public init(
        playlistRepository: PlaylistRepositoryProtocol
    ) {
        self.playlistRepository = playlistRepository
    }

    public func loadPlaylists() async {
        isLoading = true
        error = nil

        do {
            let cached = try await playlistRepository.fetchPlaylists()
            playlists = cached.map { Playlist(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
    
    public var sortedPlaylists: [Playlist] {
        switch playlistSortOption {
        case .title:
            return playlists.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
        case .trackCount:
            return playlists.sorted { $0.trackCount > $1.trackCount }
        case .duration:
            return playlists.sorted { $0.duration > $1.duration }
        }
    }
}

// MARK: - Playlist Detail ViewModel

@MainActor
public final class PlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var playlist: Playlist
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?

    private let playlistRepository: PlaylistRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol

    public init(
        playlist: Playlist,
        playlistRepository: PlaylistRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.libraryRepository = libraryRepository
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            if let cached = try await playlistRepository.fetchPlaylist(ratingKey: playlist.id) {
                let cachedTracks = cached.tracksArray
                tracks = cachedTracks.map { Track(from: $0) }
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
