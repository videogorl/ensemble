import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class PlaylistViewModel: ObservableObject {
    @Published public private(set) var playlists: [Playlist] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var playlistSortOption: PlaylistSortOption = .title {
        didSet {
            filterOptions.sortBy = playlistSortOption.rawValue
        }
    }
    @Published public var filterOptions: FilterOptions

    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator
    ) {
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        let savedFilters = FilterPersistence.load(for: "Playlists")
        self.filterOptions = savedFilters

        // Load sort option from filters
        if let savedSort = PlaylistSortOption(rawValue: savedFilters.sortBy) {
            self.playlistSortOption = savedSort
        }

        // Save filter options when they change
        setupFilterPersistence()

        // Auto-reload when sync completes
        syncCoordinator.$isSyncing
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] syncing in
                if !syncing {
                    Task { @MainActor in
                        await self?.loadPlaylists()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "Playlists") }
            .store(in: &cancellables)
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

    /// Sync playlists from server, then reload from cache
    public func refreshFromServer() async {
        // Check if offline
        if syncCoordinator.isOffline {
            print("📴 Offline - loading playlists from cache only")
            await loadPlaylists()
            return
        }

        error = nil

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        print("🔄 Starting playlist sync (detached)...")
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncPlaylistsOnly()
                continuation.resume()
            }
        }
        print("✅ Playlist sync complete")

        // Reload from updated cache
        await loadPlaylists()
    }
    
    public var sortedPlaylists: [Playlist] {
        switch playlistSortOption {
        case .title:
            return playlists.sorted { $0.title.sortingKey.localizedStandardCompare($1.title.sortingKey) == .orderedAscending }
        case .trackCount:
            return playlists.sorted { $0.trackCount > $1.trackCount }
        case .duration:
            return playlists.sorted { $0.duration > $1.duration }
        case .dateAdded:
            return playlists.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .dateModified:
            return playlists.sorted { ($0.dateModified ?? .distantPast) > ($1.dateModified ?? .distantPast) }
        case .lastPlayed:
            return playlists.sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
        }
    }
    
    // MARK: - Filtered Collections
    
    /// Filtered playlists based on current filter options
    public var filteredPlaylists: [Playlist] {
        applyFilters(to: sortedPlaylists, with: filterOptions)
    }
    
    // MARK: - Filter Application
    
    private func applyFilters(to playlists: [Playlist], with options: FilterOptions) -> [Playlist] {
        var filtered = playlists
        
        // Search text filter
        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower)
            }
        }
        
        return filtered
    }
}

// MARK: - Playlist Detail ViewModel

@MainActor
public final class PlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var playlist: Playlist
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    private let playlistRepository: PlaylistRepositoryProtocol
    private let libraryRepository: LibraryRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        playlist: Playlist,
        playlistRepository: PlaylistRepositoryProtocol,
        libraryRepository: LibraryRepositoryProtocol,
        syncCoordinator: SyncCoordinator
    ) {
        self.playlist = playlist
        self.playlistRepository = playlistRepository
        self.libraryRepository = libraryRepository
        self.syncCoordinator = syncCoordinator
        self.filterOptions = FilterPersistence.load(for: "PlaylistDetail")
        
        // Save filter options when they change
        setupFilterPersistence()
    }
    
    private func setupFilterPersistence() {
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "PlaylistDetail") }
            .store(in: &cancellables)
    }

    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            if let cachedPlaylist = try await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) {
                // Refresh playlist metadata from cache so title/count stays current after edits.
                playlist = Playlist(from: cachedPlaylist)
                tracks = cachedPlaylist.tracksArray.map { Track(from: $0) }
            } else {
                tracks = []
            }
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
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }
        
        // Downloaded only filter
        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }
        
        return filtered
    }

    public func renamePlaylist(to newTitle: String) async {
        do {
            try await syncCoordinator.renamePlaylist(playlist, to: newTitle)
            await loadTracks()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func saveEditedTracks(_ editedTracks: [Track]) async {
        do {
            try await syncCoordinator.replacePlaylistContents(playlist, with: editedTracks)
            await loadTracks()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
