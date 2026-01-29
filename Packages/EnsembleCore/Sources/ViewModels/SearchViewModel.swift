import Combine
import EnsembleAPI
import EnsemblePersistence
import Foundation

@MainActor
public final class SearchViewModel: ObservableObject {
    @Published public var searchQuery = ""
    @Published public private(set) var results: [Track] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var error: String?

    private let apiClient: PlexAPIClient
    private let libraryRepository: LibraryRepositoryProtocol
    private var searchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    public init(
        apiClient: PlexAPIClient,
        libraryRepository: LibraryRepositoryProtocol
    ) {
        self.apiClient = apiClient
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
            results = []
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
            // Search local cache first for quick results
            let localResults = try await libraryRepository.searchTracks(query: query)
            if !localResults.isEmpty {
                results = localResults.map { Track(from: $0) }
            }

            // Search server
            if let musicSection = try await apiClient.getMusicLibrarySection() {
                let serverResults = try await apiClient.search(query: query, sectionKey: musicSection.key)
                results = serverResults.map { Track(from: $0) }
            }
        } catch {
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }

        isSearching = false
    }

    public func clearSearch() {
        searchQuery = ""
        results = []
    }
}
