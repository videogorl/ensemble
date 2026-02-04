import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class ArtistDetailViewModel: ObservableObject {
    @Published public private(set) var artist: Artist
    @Published public private(set) var albums: [Album] = []
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    private let libraryRepository: LibraryRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        artist: Artist,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.artist = artist
        self.libraryRepository = libraryRepository
        self.filterOptions = FilterPersistence.load(for: "ArtistDetail")
        
        // Save filter options when they change
        setupFilterPersistence()
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "ArtistDetail") }
            .store(in: &cancellables)
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

    public func loadTracks() async {
        do {
            let cachedTracks = try await libraryRepository.fetchTracks(forArtist: artist.id)
            tracks = cachedTracks.map { Track(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }
    }
    
    // MARK: - Filtered Collections
    
    /// Filtered albums based on current filter options
    public var filteredAlbums: [Album] {
        applyFilters(to: albums, with: filterOptions)
    }
    
    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
    }

    public var totalDuration: String {
        let totalSeconds = filteredTracks.reduce(0) { $0 + $1.duration }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        }
        return "\(minutes) min"
    }

    public var trackCount: Int {
        filteredTracks.count
    }
    
    // MARK: - Filter Application
    
    private func applyFilters(to albums: [Album], with options: FilterOptions) -> [Album] {
        var filtered = albums
        
        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower)
            }
        }
        
        // Year range filter
        if let yearRange = options.yearRange {
            filtered = filtered.filter {
                guard let year = $0.year else { return false }
                return yearRange.contains(year)
            }
        }
        
        return filtered
    }
    
    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks
        
        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }
        
        return filtered
    }
}
