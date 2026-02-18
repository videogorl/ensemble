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
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        artist: Artist,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator
    ) {
        self.artist = artist
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
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
            if !cachedAlbums.isEmpty {
                albums = cachedAlbums.map { Album(from: $0) }
            } else if let sourceKey = artist.sourceCompositeKey {
                #if DEBUG
                print("👨‍🎤 ArtistDetailViewModel: Albums not found locally, fetching from API for source: \(sourceKey)")
                #endif
                let apiAlbums = try await syncCoordinator.getArtistAlbums(artistId: artist.id, sourceKey: sourceKey)
                albums = apiAlbums
            }
        } catch {
            #if DEBUG
            print("❌ ArtistDetailViewModel.loadAlbums error: \(error.localizedDescription)")
            #endif
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    public func loadTracks() async {
        do {
            let cachedTracks = try await libraryRepository.fetchTracks(forArtist: artist.id)
            if !cachedTracks.isEmpty {
                tracks = cachedTracks.map { Track(from: $0) }
            } else if let sourceKey = artist.sourceCompositeKey {
                #if DEBUG
                print("👨‍🎤 ArtistDetailViewModel: Tracks not found locally, fetching from API for source: \(sourceKey)")
                #endif
                let apiTracks = try await syncCoordinator.getArtistTracks(artistId: artist.id, sourceKey: sourceKey)
                tracks = apiTracks
            }
        } catch {
            #if DEBUG
            print("❌ ArtistDetailViewModel.loadTracks error: \(error.localizedDescription)")
            #endif
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

    /// Tracks rated 4+ stars (rating >= 8 on 0-10 scale) by this artist
    public var favoritedTracks: [Track] {
        tracks.filter { $0.rating >= 8 }
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
