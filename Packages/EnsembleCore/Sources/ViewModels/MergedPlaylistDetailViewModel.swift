import Combine
import EnsemblePersistence
import EnsembleSupport
import Foundation
import Observation

private struct MergedPlaylistTrackSnapshot {
    let trackSets: [[Track]]
    let uneditablePlaylistIDs: Set<String>
    let loadedTrackCountsByPlaylistID: [String: Int]
    let loadedItemsByPlaylistID: [String: [PlaylistItem]]
    let hasUnavailableTracks: Bool
}

/// ViewModel for displaying a merged playlist — multiple same-named playlists from
/// different sources shown as a single unified view with round-robin interleaved tracks.
@MainActor
@Observable
public final class MergedPlaylistDetailViewModel: MediaDetailViewModelProtocol {
    public private(set) var displayPlaylist: DisplayPlaylist
    public private(set) var tracks: [Track] = [] {
        didSet { updateDerivedTrackState(refreshGenres: true) }
    }
    public private(set) var availableGenres: [String] = []
    public private(set) var filteredTracks: [Track] = []
    public private(set) var totalDuration: String = "0 min"
    public private(set) var isLoading = false
    public private(set) var hasLoadedTracks = false
    public private(set) var hasUnavailableTracks = false
    public private(set) var error: String?
    public var filterOptions: FilterOptions {
        didSet {
            updateDerivedTrackState()
            FilterPersistence.save(filterOptions, for: "MergedPlaylistDetail-\(displayPlaylist.title)")
        }
    }

    private let playlistRepository: PlaylistRepositoryProtocol
    private let syncCoordinator: SyncCoordinator
    private let mutationCoordinator: MutationCoordinator
    private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var subscriptions: [StreamSubscription] = []
    @ObservationIgnored private var isStarted = false
    private var shouldSkipNextLoadAfterLocalEdit = false
    private var hasPendingTrackLoad = false
    private var trackLoadTask: Task<Void, Never>?
    private var trackSnapshotRevision: UInt64 = 0
    private var uneditablePlaylistIDs = Set<String>()
    private var loadedTrackCountsByPlaylistID: [String: Int] = [:]
    private var loadedItemsByPlaylistID: [String: [PlaylistItem]] = [:]

    @ObservationIgnored private let libraryChanges: LibraryChanges?

    public init(
        displayPlaylist: DisplayPlaylist,
        playlistRepository: PlaylistRepositoryProtocol,
        syncCoordinator: SyncCoordinator,
        mutationCoordinator: MutationCoordinator,
        libraryChanges: LibraryChanges? = nil
    ) {
        self.libraryChanges = libraryChanges
        self.displayPlaylist = displayPlaylist
        self.playlistRepository = playlistRepository
        self.syncCoordinator = syncCoordinator
        self.mutationCoordinator = mutationCoordinator
        self.filterOptions = FilterPersistence.load(for: "MergedPlaylistDetail-\(displayPlaylist.title)")
        updateDerivedTrackState(refreshGenres: true)
    }

    /// Starts reloading on playlist, download, and metadata changes. Safe to
    /// call on every appearance.
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        observeReloadTriggers()
        observePlaylistRefresh()
    }

    // MARK: - Setup

    private func observePlaylistRefresh() {
        subscriptions.append(ViewModelChangeObserver.observePlaylistRefresh(
            from: syncCoordinator,
            for: self,
            matchingSourceKeys: { model in
                Set(model.displayPlaylist.playlists.compactMap {
                    MediaSourceIdentity.serverSourceKey(from: $0.sourceCompositeKey)
                })
            }
        ) { model, _ in
            await model.loadTracks()
        })
    }

    private func observeReloadTriggers() {
        subscriptions += ViewModelChangeObserver.observeDownloadAndMetadataChanges(from: libraryChanges, for: self) { model in
            await model.loadTracks()
        }
    }

    // MARK: - Track Loading

    /// Loads tracks from all constituent playlists and interleaves them round-robin
    public func loadTracks() async {
        if shouldSkipNextLoadAfterLocalEdit {
            shouldSkipNextLoadAfterLocalEdit = false
            return
        }

        if let trackLoadTask {
            hasPendingTrackLoad = true
            await trackLoadTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isLoading = true
            self.error = nil
            repeat {
                self.hasPendingTrackLoad = false
                await self.performTrackLoad()
            } while self.hasPendingTrackLoad
            self.hasLoadedTracks = true
            self.isLoading = false
            self.trackLoadTask = nil
        }
        trackLoadTask = task
        await task.value
    }

    private func performTrackLoad() async {
        if shouldSkipNextLoadAfterLocalEdit {
            shouldSkipNextLoadAfterLocalEdit = false
            return
        }
        let playlists = displayPlaylist.playlists
        let revision = trackSnapshotRevision
        do {
            let snapshot = try await loadConstituentTrackSets(for: playlists)
            guard revision == trackSnapshotRevision,
                  playlists == displayPlaylist.playlists else { return }
            let loadedTracks = DisplayPlaylist.interleave(snapshot.trackSets)
            if uneditablePlaylistIDs != snapshot.uneditablePlaylistIDs {
                uneditablePlaylistIDs = snapshot.uneditablePlaylistIDs
            }
            if loadedTrackCountsByPlaylistID != snapshot.loadedTrackCountsByPlaylistID {
                loadedTrackCountsByPlaylistID = snapshot.loadedTrackCountsByPlaylistID
            }
            if loadedItemsByPlaylistID != snapshot.loadedItemsByPlaylistID {
                loadedItemsByPlaylistID = snapshot.loadedItemsByPlaylistID
            }
            if hasUnavailableTracks != snapshot.hasUnavailableTracks {
                hasUnavailableTracks = snapshot.hasUnavailableTracks
            }
            if tracks != loadedTracks { tracks = loadedTracks }
        } catch is CancellationError {
            // A changed constituent list is handled by the coalesced trailing load.
        } catch {
            guard revision == trackSnapshotRevision,
                  playlists == displayPlaylist.playlists else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadConstituentTrackSets(for playlists: [Playlist]) async throws -> MergedPlaylistTrackSnapshot {
        let references = playlists.compactMap { playlist -> SourceScopedArtworkReference? in
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { return nil }
            return SourceScopedArtworkReference(ratingKey: playlist.id, sourceCompositeKey: sourceCompositeKey)
        }

        guard references.count == playlists.count else {
            return try await loadConstituentTrackSetsOneByOne(playlists)
        }

        let playlistsByKey = try await playlistRepository.fetchPlaylistBodies(forReferences: references)
        guard playlists == displayPlaylist.playlists else { throw CancellationError() }
        var uneditablePlaylistIDs = Set<String>()
        var loadedTrackCountsByPlaylistID: [String: Int] = [:]
        var loadedItemsByPlaylistID: [String: [PlaylistItem]] = [:]
        var hasUnavailableTracks = false
        let trackSets: [[Track]] = playlists.map { playlist -> [Track] in
            guard let sourceCompositeKey = playlist.sourceCompositeKey else { return [] }
            let key = SourceScopedArtworkReference(
                ratingKey: playlist.id,
                sourceCompositeKey: sourceCompositeKey
            ).lookupKey
            guard let cachedPlaylist = playlistsByKey[key] else {
                if playlist.trackCount > 0 {
                    uneditablePlaylistIDs.insert(playlist.sourceScopedID)
                    hasUnavailableTracks = true
                }
                return []
            }

            let items = cachedPlaylist.playlistItemsArray.map(PlaylistItem.init(from:))
            loadedItemsByPlaylistID[playlist.sourceScopedID] = items
            loadedTrackCountsByPlaylistID[playlist.sourceScopedID] = items.count
            hasUnavailableTracks = hasUnavailableTracks || cachedPlaylist.hasUnavailableTracks
            if playlist.sourceType?.capabilities.playlistEditsRequireItemIdentifiers == true,
               items.contains(where: { $0.playlistItemID == nil }) {
                uneditablePlaylistIDs.insert(playlist.sourceScopedID)
            }
            return items.map(\.track)
        }
        return MergedPlaylistTrackSnapshot(
            trackSets: trackSets,
            uneditablePlaylistIDs: uneditablePlaylistIDs,
            loadedTrackCountsByPlaylistID: loadedTrackCountsByPlaylistID,
            loadedItemsByPlaylistID: loadedItemsByPlaylistID,
            hasUnavailableTracks: hasUnavailableTracks
        )
    }

    private func loadConstituentTrackSetsOneByOne(_ playlists: [Playlist]) async throws -> MergedPlaylistTrackSnapshot {
        var trackSets: [[Track]] = []
        var uneditablePlaylistIDs = Set<String>()
        var loadedTrackCountsByPlaylistID: [String: Int] = [:]
        var loadedItemsByPlaylistID: [String: [PlaylistItem]] = [:]
        var hasUnavailableTracks = false
        trackSets.reserveCapacity(playlists.count)
        for playlist in playlists {
            if let cached = try await playlistRepository.fetchPlaylist(
                ratingKey: playlist.id,
                sourceCompositeKey: playlist.sourceCompositeKey
            ) {
                let items = cached.playlistItemsArray.map(PlaylistItem.init(from:))
                loadedItemsByPlaylistID[playlist.sourceScopedID] = items
                loadedTrackCountsByPlaylistID[playlist.sourceScopedID] = items.count
                hasUnavailableTracks = hasUnavailableTracks || cached.hasUnavailableTracks
                if playlist.sourceType?.capabilities.playlistEditsRequireItemIdentifiers == true,
                   items.contains(where: { $0.playlistItemID == nil }) {
                    uneditablePlaylistIDs.insert(playlist.sourceScopedID)
                }
                trackSets.append(items.map(\.track))
            } else {
                if playlist.trackCount > 0 {
                    uneditablePlaylistIDs.insert(playlist.sourceScopedID)
                    hasUnavailableTracks = true
                }
                trackSets.append([])
            }
        }
        guard playlists == displayPlaylist.playlists else { throw CancellationError() }
        return MergedPlaylistTrackSnapshot(
            trackSets: trackSets,
            uneditablePlaylistIDs: uneditablePlaylistIDs,
            loadedTrackCountsByPlaylistID: loadedTrackCountsByPlaylistID,
            loadedItemsByPlaylistID: loadedItemsByPlaylistID,
            hasUnavailableTracks: hasUnavailableTracks
        )
    }

    public func editAvailability(for playlist: Playlist) -> MusicItemActionAvailability {
        let availability = playlist.actionAvailability(for: .reorder)
        guard availability.isAvailable else { return availability }
        guard !uneditablePlaylistIDs.contains(playlist.sourceScopedID) else {
            return .unavailable(reason: "Playlist contents are not available to edit.")
        }
        guard loadedTrackCountsByPlaylistID[playlist.sourceScopedID, default: 0] > 0 else {
            return .unavailable(reason: "Playlist has no songs to edit.")
        }
        return .available
    }

    public func canRemoveTrackFromPlaylist(_ track: Track) -> Bool {
        guard let playlist = playlistOwningTrack(track) else { return false }
        return editAvailability(for: playlist).isAvailable
    }

    /// Sync all constituent playlists then reload
    public func refreshFromServer() async {
        guard !syncCoordinator.isOffline, !syncCoordinator.isSyncing else {
            await loadTracks()
            return
        }

        error = nil
        await Task.detached { [syncCoordinator] in
            await syncCoordinator.syncPlaylistsOnly()
        }.value
        await loadTracks()
    }

    // MARK: - Filtered Collections

    @discardableResult
    public func removeTrackFromPlaylist(_ track: Track, displayIndex: Int? = nil) async -> Bool {
        guard !displayPlaylist.editablePlaylists.isEmpty else {
            error = PlaylistMutationError.smartPlaylistReadOnly.localizedDescription
            return false
        }

        let selectedTrack = selectedTrack(for: track, displayIndex: displayIndex)
        guard let targetPlaylist = playlistOwningTrack(selectedTrack) else {
            error = "Could not determine which server playlist owns this track."
            return false
        }
        guard targetPlaylist.supportsPlaylistEditing else {
            error = PlaylistMutationError.smartPlaylistReadOnly.localizedDescription
            return false
        }
        guard !uneditablePlaylistIDs.contains(targetPlaylist.sourceScopedID) else {
            error = PlaylistMutationError.incompletePlaylistContents.localizedDescription
            return false
        }

        guard let originalItems = loadedItemsByPlaylistID[targetPlaylist.sourceScopedID] else {
            error = PlaylistMutationError.incompletePlaylistContents.localizedDescription
            return false
        }
        let targetTracks = originalItems.map(\.track)
        guard let removalIndex = playlistTrackIndex(for: selectedTrack, displayIndex: displayIndex, in: targetTracks),
              let mergedIndex = mergedTrackIndex(for: selectedTrack, displayIndex: displayIndex) else {
            error = "Track is no longer in this playlist."
            return false
        }

        let previousTracks = tracks
        var editedItems = originalItems
        editedItems.remove(at: removalIndex)

        trackSnapshotRevision &+= 1
        shouldSkipNextLoadAfterLocalEdit = true
        loadedItemsByPlaylistID[targetPlaylist.sourceScopedID] = editedItems
        tracks.remove(at: mergedIndex)

        do {
            try await mutationCoordinator.editPlaylistItems(
                targetPlaylist,
                originalItems: originalItems,
                editedItems: editedItems
            )
            Task {
                // Refresh from cache once the source playlist mutation has synced back.
                try? await Task.sleep(nanoseconds: 500_000_000)
                self.shouldSkipNextLoadAfterLocalEdit = false
                await self.loadTracks()
            }
            return true
        } catch {
            trackSnapshotRevision &+= 1
            tracks = previousTracks
            loadedItemsByPlaylistID[targetPlaylist.sourceScopedID] = originalItems
            shouldSkipNextLoadAfterLocalEdit = false
            self.error = error.localizedDescription
            return false
        }
    }

    private func updateDerivedTrackState(refreshGenres: Bool = false) {
        if refreshGenres {
            let genres = PlaylistDetailTrackDerivation.genres(in: tracks)
            if availableGenres != genres { availableGenres = genres }
        }
        PlaylistDetailTrackDerivation.make(tracks: tracks, filterOptions: filterOptions)
            .publishChanges(
                filteredTracks: &filteredTracks,
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
        guard let trackServerSourceKey = mutationSourceKey(track.sourceCompositeKey) else {
            return displayPlaylist.playlists.count == 1 ? displayPlaylist.primaryPlaylist : nil
        }

        let matches = displayPlaylist.playlists.filter { playlist in
            mutationSourceKey(playlist.sourceCompositeKey) == trackServerSourceKey
        }
        return matches.count == 1 ? matches[0] : nil
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
            mutationSourceKey(lhs.sourceCompositeKey) == mutationSourceKey(rhs.sourceCompositeKey)
    }

    private func mutationSourceKey(_ sourceKey: String?) -> String? {
        MediaSourceIdentity.playlistScopeKey(from: sourceKey)
    }

    private func trackPassesCurrentFilters(_ track: Track) -> Bool {
        !PlaylistDetailTrackDerivation.filter([track], with: filterOptions).isEmpty
    }

    /// Updates the display playlist (e.g., when merge state changes and constituents are refreshed)
    public func updateDisplayPlaylist(_ dp: DisplayPlaylist) async {
        guard displayPlaylist != dp else { return }
        trackSnapshotRevision &+= 1
        displayPlaylist = dp
        shouldSkipNextLoadAfterLocalEdit = false
        await loadTracks()
    }
}
