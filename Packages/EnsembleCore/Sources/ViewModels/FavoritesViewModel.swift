import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class FavoritesViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    private let libraryRepository: LibraryRepositoryProtocol
    private var cancellables = Set<AnyCancellable>()

    public init(libraryRepository: LibraryRepositoryProtocol) {
        self.libraryRepository = libraryRepository
        self.filterOptions = FilterPersistence.load(for: "Favorites")
        
        setupFilterPersistence()
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Favorites") }
            .store(in: &cancellables)
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            let allTracks = try await libraryRepository.fetchTracks()
            // Rating 8+ is 4+ stars
            tracks = allTracks.filter { $0.rating >= 8 }.map { Track(from: $0) }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
    
    public var filteredTracks: [Track] {
        var filtered = tracks
        
        if !filterOptions.searchText.isEmpty {
            let searchLower = filterOptions.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        if filterOptions.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }
        
        return filtered
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
}
