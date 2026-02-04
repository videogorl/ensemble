import Combine
import EnsemblePersistence
import Foundation

// MARK: - Protocol

@MainActor
public protocol MediaDetailViewModelProtocol: ObservableObject {
    var tracks: [Track] { get }
    var filteredTracks: [Track] { get }
    var isLoading: Bool { get }
    var error: String? { get }
    var totalDuration: String { get }
    var filterOptions: FilterOptions { get set }
    
    func loadTracks() async
}

// MARK: - Album Detail ViewModel

@MainActor
public final class AlbumDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var album: Album
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    private let libraryRepository: LibraryRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(
        album: Album,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.album = album
        self.libraryRepository = libraryRepository
        self.filterOptions = FilterPersistence.load(for: "AlbumDetail")
        
        // Save filter options when they change
        setupFilterPersistence()
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "AlbumDetail") }
            .store(in: &cancellables)
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
    
    // MARK: - Filtered Collections
    
    /// Filtered tracks based on current filter options
    public var filteredTracks: [Track] {
        applyFilters(to: tracks, with: filterOptions)
    }

    public var totalDuration: String {
        let total = filteredTracks.reduce(0) { $0 + $1.duration }
        let minutes = Int(total) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours) hr \(mins) min"
        }
        return "\(minutes) min"
    }
    
    // MARK: - Filter Application
    
    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks
        
        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }
        
        return filtered
    }
}
