import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var searchQuery = ""
    @Published public private(set) var trackResults: [Track] = []
    @Published public private(set) var artistResults: [Artist] = []
    @Published public private(set) var albumResults: [Album] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var error: String?
    
    // Legacy support
    public var results: [Track] { trackResults }
    
    public let focusRequested = PassthroughSubject<Void, Never>()

    private let libraryRepository: LibraryRepositoryProtocol
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.libraryRepository = libraryRepository

        // Debounced search
        $searchQuery
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] query in
                self?.performSearch(query: query)
            }
            .store(in: &cancellables)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            trackResults = []
            artistResults = []
            albumResults = []
            return
        }

        searchTask = Task {
            await search(query: trimmed)
        }
    }

    public func search(query: String) async {
        isSearching = true
        error = nil

        do {
            async let localTracks = libraryRepository.searchTracks(query: query)
            async let localArtists = libraryRepository.searchArtists(query: query)
            async let localAlbums = libraryRepository.searchAlbums(query: query)
            
            let (tracks, artists, albums) = try await (localTracks, localArtists, localAlbums)
            
            trackResults = tracks.map { Track(from: $0) }
            artistResults = artists.map { Artist(from: $0) }
            albumResults = albums.map { Album(from: $0) }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }

        isSearching = false
    }

    public func clearSearch() {
        searchQuery = ""
        trackResults = []
        artistResults = []
        albumResults = []
    }
    
    public func requestFocus() {
        focusRequested.send()
    }
}