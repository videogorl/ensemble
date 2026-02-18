import Combine
import EnsemblePersistence
import Foundation

@MainActor
public final class PlaylistViewModel: ObservableObject {
    private static let optimisticCreatePrefix = "creating:"

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
    private var optimisticCreatingPlaylists: [Playlist] = []

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
        await reloadPlaylists(showLoading: true)
    }

    /// Sync playlists from server, then reload from cache
    public func refreshFromServer() async {
        // Check if offline
        if syncCoordinator.isOffline {
            #if DEBUG
            print("📴 Offline - loading playlists from cache only")
            #endif
            await loadPlaylists()
            return
        }

        error = nil

        // Run sync in a detached task to avoid SwiftUI's .refreshable cancellation
        #if DEBUG
        print("🔄 Starting playlist sync (detached)...")
        #endif
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncPlaylistsOnly()
                continuation.resume()
            }
        }
        #if DEBUG
        print("✅ Playlist sync complete")
        #endif

        // Reload from updated cache
        await loadPlaylists()
    }

    public func deletePlaylist(_ playlist: Playlist) async -> Bool {
        do {
            try await syncCoordinator.deletePlaylist(playlist)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func createPlaylist(title: String, serverSourceKey: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Playlist name cannot be empty."
            return false
        }

        addOptimisticCreatingPlaylist(title: trimmed, serverSourceKey: serverSourceKey)

        do {
            _ = try await syncCoordinator.createPlaylist(
                title: trimmed,
                tracks: [],
                serverSourceKey: serverSourceKey
            )
            Task { [weak self] in
                await self?.awaitCreatedPlaylistMaterialization(
                    title: trimmed,
                    serverSourceKey: serverSourceKey
                )
            }
            return true
        } catch {
            removeOptimisticCreatingPlaylist(title: trimmed, serverSourceKey: serverSourceKey)
            await reloadPlaylists(showLoading: false)
            self.error = error.localizedDescription
            return false
        }
    }

    public func isPlaylistPendingCreation(_ playlist: Playlist) -> Bool {
        Self.isOptimisticCreatingPlaylistID(playlist.id)
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

    private func reloadPlaylists(showLoading: Bool) async {
        if showLoading {
            isLoading = true
        }
        error = nil

        do {
            let cached = try await playlistRepository.fetchPlaylists()
            let serverPlaylists = cached.map { Playlist(from: $0) }
            optimisticCreatingPlaylists.removeAll { optimistic in
                serverPlaylists.contains(where: { matchesPlaylistIdentity($0, optimistic) })
            }
            playlists = mergeWithOptimisticCreatingPlaylists(serverPlaylists)
        } catch {
            self.error = error.localizedDescription
        }

        if showLoading {
            isLoading = false
        }
    }

    private func awaitCreatedPlaylistMaterialization(title: String, serverSourceKey: String) async {
        for _ in 0..<20 {
            await reloadPlaylists(showLoading: false)
            let hasPending = optimisticCreatingPlaylists.contains(where: {
                normalizedTitle($0.title) == normalizedTitle(title) &&
                $0.sourceCompositeKey == serverSourceKey
            })
            if !hasPending {
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    private func addOptimisticCreatingPlaylist(title: String, serverSourceKey: String) {
        let placeholder = Playlist(
            id: "\(Self.optimisticCreatePrefix)\(UUID().uuidString)",
            key: "/playlists/pending",
            title: title,
            isSmart: false,
            trackCount: 0,
            duration: 0,
            dateAdded: Date(),
            dateModified: Date(),
            sourceCompositeKey: serverSourceKey
        )
        optimisticCreatingPlaylists.removeAll(where: { matchesPlaylistIdentity($0, placeholder) })
        optimisticCreatingPlaylists.append(placeholder)
        playlists = mergeWithOptimisticCreatingPlaylists(playlists.filter { !Self.isOptimisticCreatingPlaylistID($0.id) })
    }

    private func removeOptimisticCreatingPlaylist(title: String, serverSourceKey: String) {
        optimisticCreatingPlaylists.removeAll {
            normalizedTitle($0.title) == normalizedTitle(title) &&
            $0.sourceCompositeKey == serverSourceKey
        }
    }

    private func mergeWithOptimisticCreatingPlaylists(_ serverPlaylists: [Playlist]) -> [Playlist] {
        let unresolvedOptimistic = optimisticCreatingPlaylists.filter { optimistic in
            !serverPlaylists.contains(where: { matchesPlaylistIdentity($0, optimistic) })
        }
        return serverPlaylists + unresolvedOptimistic
    }

    private static func isOptimisticCreatingPlaylistID(_ id: String) -> Bool {
        id.hasPrefix(optimisticCreatePrefix)
    }

    private func matchesPlaylistIdentity(_ lhs: Playlist, _ rhs: Playlist) -> Bool {
        normalizedTitle(lhs.title) == normalizedTitle(rhs.title) &&
        lhs.sourceCompositeKey == rhs.sourceCompositeKey
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
    private var shouldSkipNextLoadAfterLocalEdit = false

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
        if shouldSkipNextLoadAfterLocalEdit {
            shouldSkipNextLoadAfterLocalEdit = false
            return
        }

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

    public func deletePlaylist() async -> Bool {
        do {
            try await syncCoordinator.deletePlaylist(playlist)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    public func applyEditedTracksLocally(_ editedTracks: [Track]) {
        shouldSkipNextLoadAfterLocalEdit = true
        tracks = editedTracks
        playlist = Playlist(
            id: playlist.id,
            key: playlist.key,
            title: playlist.title,
            summary: playlist.summary,
            isSmart: playlist.isSmart,
            trackCount: editedTracks.count,
            duration: editedTracks.reduce(0) { $0 + $1.duration },
            compositePath: playlist.compositePath,
            dateAdded: playlist.dateAdded,
            dateModified: Date(),
            lastPlayed: playlist.lastPlayed,
            sourceCompositeKey: playlist.sourceCompositeKey
        )
    }

    public func saveEditedTracks(_ editedTracks: [Track]) async {
        // Apply immediately so playlist detail reflects edits before network roundtrip.
        applyEditedTracksLocally(editedTracks)

        do {
            try await syncCoordinator.replacePlaylistContents(playlist, with: editedTracks)
            Task {
                // Refresh from cache once post-mutation sync catches up.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
