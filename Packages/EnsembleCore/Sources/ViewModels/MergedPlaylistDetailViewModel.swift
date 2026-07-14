import Combine
import EnsemblePersistence
import Foundation

/// ViewModel for displaying a merged playlist — multiple same-named playlists from
/// different servers shown as a single unified view with round-robin interleaved tracks.
@MainActor
public final class MergedPlaylistDetailViewModel: ObservableObject, MediaDetailViewModelProtocol {
    @Published public private(set) var displayPlaylist: DisplayPlaylist
    @Published public private(set) var tracks: [Track] = [] {
        didSet { updateDerivedTrackState() }
    }
    @Published public private(set) var availableGenres: [String] = []
    @Published public private(set) var filteredTracks: [Track] = []
    @Published public private(set) var totalDuration: String = "0 min"
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoadedTracks = false
    @Published public private(set) var hasUnavailableTracks = false
    @Published public private(set) var error: String?
    @Published public var filterOptions: FilterOptions {
        didSet { updateDerivedTrackState() }
    }

    /// Resolved server names for each constituent playlist source
    @Published public private(set) var sourceServerNames: [(sourceKey: String, name: String)] = []

    private let playlistRepository: PlaylistRepositoryProtocol
    private let accountManager: AccountManager
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private var cancellables = Set<AnyCancellable>()
    private var shouldSkipNextLoadAfterLocalEdit = false

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
        updateDerivedTrackState()

        setupFilterPersistence()
        resolveServerNames()
        observeReloadTriggers()
        observePlaylistRefresh()
    }

    // MARK: - Setup

    private func setupFilterPersistence() {
        let title = displayPlaylist.title
        FilterPersistence.observe($filterOptions, key: "MergedPlaylistDetail-\(title)", storingIn: &cancellables)
    }

    /// Resolves human-readable server names from each constituent playlist's sourceCompositeKey
    private func resolveServerNames() {
        sourceServerNames = displayPlaylist.playlists.compactMap { playlist in
            guard let sourceKey = playlist.sourceCompositeKey else { return nil }
            let name = accountManager.serverName(for: sourceKey) ?? "Unknown Server"
            return (sourceKey: sourceKey, name: name)
        }
    }

    private func observePlaylistRefresh() {
        ViewModelNotificationObserver.observePlaylistRefresh(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    private func observeReloadTriggers() {
        ViewModelNotificationObserver.observeDownloadAndMetadataChanges(storingIn: &cancellables) { [weak self] in
            await self?.loadTracks()
        }
    }

    // MARK: - Track Loading

    /// Loads tracks from all constituent playlists and interleaves them round-robin
    public func loadTracks() async {
        if shouldSkipNextLoadAfterLocalEdit {
            shouldSkipNextLoadAfterLocalEdit = false
            return
        }

        isLoading = true
        error = nil

        do {
            tracks = DisplayPlaylist.interleave(try await loadConstituentTrackSets())
        } catch {
            self.error = error.localizedDescription
        }

        hasLoadedTracks = true
        isLoading = false
    }

    private func loadConstituentTrackSets() async throws -> [[Track]] {
        let references = displayPlaylist.playlists.compactMap { playlist -> SourceScopedArtworkReference? in
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { return nil }
            return SourceScopedArtworkReference(ratingKey: playlist.id, sourceCompositeKey: sourceCompositeKey)
        }

        guard references.count == displayPlaylist.playlists.count else {
            return try await loadConstituentTrackSetsOneByOne()
        }

        let playlistsByKey = try await playlistRepository.fetchPlaylists(forReferences: references)
        var unavailablePlaylistIDs = Set<String>()
        let trackSets: [[Track]] = displayPlaylist.playlists.map { playlist -> [Track] in
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { return [] }
            let key = SourceScopedArtworkReference(
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey
            ).lookupKey
            guard let cachedPlaylist = playlistsByKey[key] else {
                if playlist.trackCount > 0 {
                    unavailablePlaylistIDs.insert(playlist.sourceScopedID)
                }
                return []
            }

            let tracks = cachedPlaylist.tracksArray.map { Track(from: $0) }
            if cachedPlaylist.hasUnavailableTracks {
                unavailablePlaylistIDs.insert(playlist.sourceScopedID)
            }
            return tracks
        }
        hasUnavailableTracks = !unavailablePlaylistIDs.isEmpty
        return trackSets
    }

    private func loadConstituentTrackSetsOneByOne() async throws -> [[Track]] {
        var trackSets: [[Track]] = []
        var unavailablePlaylistIDs = Set<String>()
        trackSets.reserveCapacity(displayPlaylist.playlists.count)
        for playlist in displayPlaylist.playlists {
            if let cached = try await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) {
                let tracks = cached.tracksArray.map { Track(from: $0) }
                if cached.hasUnavailableTracks {
                    unavailablePlaylistIDs.insert(playlist.sourceScopedID)
                }
                trackSets.append(tracks)
            } else {
                if playlist.trackCount > 0 {
                    unavailablePlaylistIDs.insert(playlist.sourceScopedID)
                }
                trackSets.append([])
            }
        }
        hasUnavailableTracks = !unavailablePlaylistIDs.isEmpty
        return trackSets
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

    @discardableResult
    public func removeTrackFromPlaylist(_ track: Track, displayIndex: Int? = nil) async -> Bool {
        guard !displayPlaylist.isSmart else {
            error = PlaylistMutationError.smartPlaylistReadOnly.localizedDescription
            return false
        }

        let selectedTrack = selectedTrack(for: track, displayIndex: displayIndex)
        guard let targetPlaylist = playlistOwningTrack(selectedTrack) else {
            error = "Could not determine which server playlist owns this track."
            return false
        }
        guard !hasUnavailableTracks else {
            error = PlaylistMutationError.incompletePlaylistContents.localizedDescription
            return false
        }

        let targetTracks = tracksForPlaylistSource(targetPlaylist)
        guard let removalIndex = playlistTrackIndex(for: selectedTrack, displayIndex: displayIndex, in: targetTracks),
              let mergedIndex = mergedTrackIndex(for: selectedTrack, displayIndex: displayIndex) else {
            error = "Track is no longer in this playlist."
            return false
        }

        let previousTracks = tracks
        var editedTargetTracks = targetTracks
        editedTargetTracks.remove(at: removalIndex)

        shouldSkipNextLoadAfterLocalEdit = true
        tracks.remove(at: mergedIndex)

        do {
            try await mutationCoordinator.replacePlaylistContents(targetPlaylist, with: editedTargetTracks)
            Task {
                // Refresh from cache once the source playlist mutation has synced back.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
            return true
        } catch {
            tracks = previousTracks
            shouldSkipNextLoadAfterLocalEdit = false
            self.error = error.localizedDescription
            return false
        }
    }

    private func updateDerivedTrackState() {
        PlaylistDetailTrackDerivation.make(tracks: tracks, filterOptions: filterOptions)
            .publishChanges(
                filteredTracks: &filteredTracks,
                availableGenres: &availableGenres,
                totalDuration: &totalDuration
            )
    }

    private func selectedTrack(for track: Track, displayIndex: Int?) -> Track {
        guard let displayIndex, filteredTracks.indices.contains(displayIndex) else {
            return track
        }
        return filteredTracks[displayIndex]
    }

    private func playlistOwningTrack(_ track: Track) -> Playlist? {
        guard let trackServerSourceKey = MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) else {
            return displayPlaylist.playlists.count == 1 ? displayPlaylist.primaryPlaylist : nil
        }

        let matches = displayPlaylist.playlists.filter { playlist in
            MediaSourceIdentity.serverSourceKey(from: playlist.sourceCompositeKey) == trackServerSourceKey
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func tracksForPlaylistSource(_ playlist: Playlist) -> [Track] {
        guard let playlistServerSourceKey = MediaSourceIdentity.serverSourceKey(from: playlist.sourceCompositeKey) else {
            return []
        }
        return tracks.filter { track in
            MediaSourceIdentity.serverSourceKey(from: track.sourceCompositeKey) == playlistServerSourceKey
        }
    }

    private func playlistTrackIndex(for track: Track, displayIndex: Int?, in targetTracks: [Track]) -> Int? {
        if let displayIndex, filteredTracks.indices.contains(displayIndex) {
            let selected = filteredTracks[displayIndex]
            let precedingVisibleMatches = filteredTracks[..<displayIndex]
                .filter { sameTrackIdentity($0, selected) }
                .count
            var seenMatches = 0
            for (index, candidate) in targetTracks.enumerated() where sameTrackIdentity(candidate, selected) {
                if seenMatches == precedingVisibleMatches {
                    return index
                }
                seenMatches += 1
            }
        }

        return targetTracks.firstIndex { sameTrackIdentity($0, track) }
    }

    private func mergedTrackIndex(for track: Track, displayIndex: Int?) -> Int? {
        if let displayIndex, filteredTracks.indices.contains(displayIndex) {
            let selected = filteredTracks[displayIndex]
            let precedingVisibleMatches = filteredTracks[..<displayIndex]
                .filter { sameTrackIdentity($0, selected) }
                .count
            var seenMatches = 0
            for (index, candidate) in tracks.enumerated()
                where sameTrackIdentity(candidate, selected) && trackPassesCurrentFilters(candidate) {
                if seenMatches == precedingVisibleMatches {
                    return index
                }
                seenMatches += 1
            }
        }

        return tracks.firstIndex { sameTrackIdentity($0, track) }
    }

    private func sameTrackIdentity(_ lhs: Track, _ rhs: Track) -> Bool {
        lhs.id == rhs.id &&
            MediaSourceIdentity.serverSourceKey(from: lhs.sourceCompositeKey) ==
            MediaSourceIdentity.serverSourceKey(from: rhs.sourceCompositeKey)
    }

    private func trackPassesCurrentFilters(_ track: Track) -> Bool {
        !PlaylistDetailTrackDerivation.filter([track], with: filterOptions).isEmpty
    }

    /// Updates the display playlist (e.g., when merge state changes and constituents are refreshed)
    public func updateDisplayPlaylist(_ dp: DisplayPlaylist) {
        displayPlaylist = dp
        resolveServerNames()
    }
}
