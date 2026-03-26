import Combine
import EnsemblePersistence
import Foundation

/// ViewModel for displaying a merged playlist — multiple same-named playlists from
/// different servers shown as a single unified view with round-robin interleaved tracks.
@MainActor
public final class MergedPlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var displayPlaylist: DisplayPlaylist
    @Published public private(set) var tracks: [Track] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions

    /// Resolved server names for each constituent playlist source
    @Published public private(set) var sourceServerNames: [(sourceKey: String, name: String)] = []

    private let playlistRepository: PlaylistRepositoryProtocol
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private var cancellables = Set<AnyCancellable>()

    public init(
        displayPlaylist: DisplayPlaylist,
        playlistRepository: PlaylistRepositoryProtocol,
        accountManager: AccountManager,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator
    ) {
        self.displayPlaylist = displayPlaylist
        self.playlistRepository = playlistRepository
        self.accountManager = accountManager
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.filterOptions = FilterPersistence.load(for: "MergedPlaylistDetail-\(displayPlaylist.title)")

        setupFilterPersistence()
        resolveServerNames()
        observeDownloadChanges()
        observePlaylistRefresh()
    }

    // MARK: - Setup

    private func setupFilterPersistence() {
        let title = displayPlaylist.title
        $filterOptions
            .debounce(for: 0.5, scheduler: DispatchQueue.main)
            .sink { FilterPersistence.save($0, for: "MergedPlaylistDetail-\(title)") }
            .store(in: &cancellables)
    }

    /// Resolves human-readable server names from each constituent playlist's sourceCompositeKey
    private func resolveServerNames() {
        sourceServerNames = displayPlaylist.playlists.compactMap { playlist in
            guard let sourceKey = playlist.sourceCompositeKey else { return nil }
            let name = accountManager.serverName(for: sourceKey) ?? "Unknown Server"
            return (sourceKey: sourceKey, name: name)
        }
    }

    private func observeDownloadChanges() {
        NotificationCenter.default.publisher(for: OfflineDownloadService.downloadsDidChange)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)
    }

    private func observePlaylistRefresh() {
        NotificationCenter.default.publisher(for: SyncCoordinator.playlistsDidRefresh)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)

        syncCoordinator.$sourceStatuses
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.loadTracks()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Track Loading

    /// Loads tracks from all constituent playlists and interleaves them round-robin
    public func loadTracks() async {
        isLoading = true
        error = nil

        do {
            var trackSets: [[Track]] = []

            for playlist in displayPlaylist.playlists {
                if let cached = try await playlistRepository.fetchPlaylist(
                    ratingKey: playlist.id,
                    sourceCompositeKey: playlist.sourceCompositeKey
                ) {
                    trackSets.append(cached.tracksArray.map { Track(from: $0) })
                } else {
                    trackSets.append([])
                }
            }

            tracks = DisplayPlaylist.interleave(trackSets)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    /// Sync all constituent playlists then reload
    public func refreshFromServer() async {
        guard !syncCoordinator.isOffline, !syncCoordinator.isSyncing else {
            await loadTracks()
            return
        }

        error = nil
        await withCheckedContinuation { continuation in
            Task.detached { [syncCoordinator] in
                await syncCoordinator.syncPlaylistsOnly()
                continuation.resume()
            }
        }
        await loadTracks()
    }

    // MARK: - Filtered Collections

    public var availableGenres: [String] {
        LibraryViewModel.extractUniqueGenres(from: tracks.flatMap(\.genres))
    }

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

    private func applyFilters(to tracks: [Track], with options: FilterOptions) -> [Track] {
        var filtered = tracks

        if !options.searchText.isEmpty {
            let searchLower = options.searchText.lowercased()
            filtered = filtered.filter {
                $0.title.lowercased().contains(searchLower) ||
                ($0.artistName?.lowercased().contains(searchLower) ?? false) ||
                ($0.albumName?.lowercased().contains(searchLower) ?? false)
            }
        }

        if !options.selectedGenres.isEmpty {
            filtered = filtered.filter { !options.selectedGenres.isDisjoint(with: $0.genres) }
        }
        if !options.excludedGenres.isEmpty {
            filtered = filtered.filter { !$0.genres.isEmpty && options.excludedGenres.isDisjoint(with: $0.genres) }
        }

        if options.showDownloadedOnly {
            filtered = filtered.filter { $0.isDownloaded }
        }

        return filtered
    }

    // MARK: - Mutation Operations

    /// Renames all constituent playlists to the new title
    @discardableResult
    public func renameAll(to newTitle: String) async -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Playlist name cannot be empty."
            return false
        }

        var successCount = 0
        for playlist in displayPlaylist.playlists {
            do {
                _ = try await mutationCoordinator.renamePlaylist(playlist, to: trimmed)
                successCount += 1
            } catch {
                EnsembleLogger.debug("📋 MergedPlaylistDetailVM: Failed to rename '\(playlist.title)' on \(playlist.sourceCompositeKey ?? "?"): \(error)")
            }
        }

        if successCount == 0 {
            self.error = "Failed to rename playlist on all servers."
            return false
        }
        if successCount < displayPlaylist.playlists.count {
            EnsembleLogger.debug("📋 MergedPlaylistDetailVM: Renamed on \(successCount)/\(displayPlaylist.playlists.count) servers")
        }
        return true
    }

    /// Deletes all constituent playlists
    public func deleteAll() async -> Bool {
        var allSucceeded = true
        for playlist in displayPlaylist.playlists {
            do {
                try await mutationCoordinator.deletePlaylist(playlist)
            } catch {
                EnsembleLogger.debug("📋 MergedPlaylistDetailVM: Failed to delete '\(playlist.title)' on \(playlist.sourceCompositeKey ?? "?"): \(error)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }

    /// Updates the display playlist (e.g., when merge state changes and constituents are refreshed)
    public func updateDisplayPlaylist(_ dp: DisplayPlaylist) {
        displayPlaylist = dp
        resolveServerNames()
    }
}
