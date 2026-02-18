import Combine
import Foundation
import EnsemblePersistence

/// Rating states for the three-state heart button
public enum TrackRating: Equatable {
    case none       // No rating (empty heart)
    case disliked   // 1 star (broken heart)
    case loved      // 5 stars (filled heart)
    
    public var icon: String {
        switch self {
        case .none: return "heart"
        case .disliked: return "heart.slash"
        case .loved: return "heart.fill"
        }
    }
    
    var plexRating: Int? {
        switch self {
        case .none: return nil  // 0 removes rating
        case .disliked: return 2  // 1 star = 2
        case .loved: return 10  // 5 stars = 10
        }
    }
    
    static func from(rating: Int) -> TrackRating {
        switch rating {
        case 0: return .none
        case 1...4: return .disliked
        case 5...10: return .loved
        default: return .none
        }
    }
}

public struct PlaylistServerOption: Identifiable, Equatable {
    public let id: String   // server-level source key: plex:account:server
    public let name: String
}

public struct LastPlaylistTarget: Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let sourceCompositeKey: String?
}

public enum PlaylistActionError: LocalizedError {
    case operationInProgress

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "A playlist update is already in progress. Please wait."
        }
    }
}

@MainActor
public final class NowPlayingViewModel: ObservableObject {
    @Published public private(set) var currentTrack: Track?
    @Published public private(set) var playbackState: PlaybackState = .stopped
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var queue: [QueueItem] = []
    @Published public private(set) var currentQueueIndex: Int = -1
    @Published public private(set) var playbackHistory: [QueueItem] = []
    @Published public private(set) var isShuffleEnabled = false
    @Published public private(set) var repeatMode: RepeatMode = .off
    @Published public private(set) var waveformHeights: [Double] = []
    @Published public var currentRating: TrackRating = .none
    @Published public private(set) var isAutoplayEnabled = false
    @Published public private(set) var autoplayTracks: [Track] = []
    @Published public private(set) var isAutoplayActive = false
    @Published public private(set) var radioMode: RadioMode = .off
    @Published public private(set) var recommendationsExhausted = false
    @Published public var showHistory: Bool = false
    @Published public private(set) var isPlaylistMutationInProgress = false
    @Published public private(set) var lastPlaylistTarget: LastPlaylistTarget?

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private let toastCenter: ToastCenter
    private var cancellables = Set<AnyCancellable>()
    
    // Track if we're currently updating the rating to prevent overwriting
    private var isUpdatingRating = false

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator,
        toastCenter: ToastCenter
    ) {
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        self.toastCenter = toastCenter
        self.lastPlaylistTarget = syncCoordinator.lastPlaylistTarget
        setupBindings()
    }

    private func setupBindings() {
        playbackService.currentTrackPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentTrack)

        playbackService.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackState)

        playbackService.queuePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$queue)

        playbackService.currentQueueIndexPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentQueueIndex)

        playbackService.historyPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackHistory)

        playbackService.shufflePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isShuffleEnabled)

        playbackService.repeatModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$repeatMode)
        
        playbackService.waveformPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$waveformHeights)

        playbackService.autoplayEnabledPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayEnabled)

        playbackService.autoplayTracksPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$autoplayTracks)

        playbackService.autoplayActivePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$isAutoplayActive)

        playbackService.radioModePublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$radioMode)

        playbackService.recommendationsExhaustedPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: &$recommendationsExhausted)

        syncCoordinator.$lastPlaylistTarget
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastPlaylistTarget)

        // Update duration when track changes
        $currentTrack
            .compactMap { $0?.duration }
            .assign(to: &$duration)
        
        // Update rating when track changes (but not if we're actively updating it)
        $currentTrack
            .sink { [weak self] track in
                guard let self = self, !self.isUpdatingRating else { return }
                guard let track = track else {
                    self.currentRating = .none
                    return
                }
                self.currentRating = TrackRating.from(rating: track.rating)
            }
            .store(in: &cancellables)
    }

    // MARK: - Computed Properties

    public var currentTime: TimeInterval {
        playbackService.currentTimeValue
    }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    public var isPlaying: Bool {
        playbackState == .playing
    }

    public var hasCurrentTrack: Bool {
        currentTrack != nil
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    public var formattedRemainingTime: String {
        let remaining = max(0, duration - currentTime)
        return "-" + formatTime(remaining)
    }
    
    /// Queue split into sections for UI display
    public var queueSections: QueueSections {
        playbackService.queueSections
    }

    // MARK: - Playback Controls

    public func play(track: Track) {
        Task {
            await playbackService.play(track: track)
        }
    }

    public func play(tracks: [Track], startingAt index: Int = 0) {
        Task {
            await playbackService.play(tracks: tracks, startingAt: index)
        }
    }
    
    public func shufflePlay(tracks: [Track]) {
        Task {
            await playbackService.shufflePlay(tracks: tracks)
        }
    }

    public func togglePlayPause() {
        if isPlaying {
            playbackService.pause()
        } else {
            playbackService.resume()
        }
    }

    public func pause() {
        playbackService.pause()
    }

    public func resume() {
        playbackService.resume()
    }

    public func stop() {
        playbackService.stop()
    }
    
    public func retryCurrentTrack() async {
        await playbackService.retryCurrentTrack()
    }

    public func next() {
        playbackService.next()
    }

    public func previous() {
        playbackService.previous()
    }

    public func seek(to time: TimeInterval) {
        playbackService.seek(to: time)
    }

    public func seekToProgress(_ progress: Double) {
        let time = progress * duration
        seek(to: time)
    }

    // MARK: - Queue Management

    public func addToQueue(_ track: Track) {
        playbackService.addToQueue(track)
    }

    public func addToQueue(_ tracks: [Track]) {
        playbackService.addToQueue(tracks)
    }

    public func playNext(_ track: Track) {
        playbackService.playNext(track)
    }
    
    public func playLast(_ track: Track) {
        playbackService.playLast(track)
    }
    
    public func playLast(_ tracks: [Track]) {
        playbackService.playLast(tracks)
    }
    
    public func moveQueueItem(byId itemId: String, from sourceIndex: Int, to destinationIndex: Int) {
        playbackService.moveQueueItem(byId: itemId, from: sourceIndex, to: destinationIndex)
    }
    
    public func moveQueueItem(from sourceIndex: Int, to destinationIndex: Int) {
        playbackService.moveQueueItem(from: sourceIndex, to: destinationIndex)
    }

    public func removeFromQueue(at index: Int) {
        playbackService.removeFromQueue(at: index)
    }

    // MARK: - Playlist Management

    /// Candidate server options for playlist creation. Deduplicated at server level.
    public func playlistServerOptions() -> [PlaylistServerOption] {
        var options: [PlaylistServerOption] = []
        for account in syncCoordinator.accountManager.plexAccounts {
            for server in account.servers {
                let sourceKey = "plex:\(account.id):\(server.id)"
                options.append(PlaylistServerOption(id: sourceKey, name: server.name))
            }
        }
        return options.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func defaultPlaylistServerSourceKey(for tracks: [Track]) -> String? {
        // Prefer the source from the explicitly provided tracks first.
        for track in tracks {
            if let source = serverSourceKey(from: track.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack,
           let source = serverSourceKey(from: currentTrack.sourceCompositeKey) {
            return source
        }
        return nil
    }

    public func resolveDefaultPlaylistServerSourceKey(for tracks: [Track]) async -> String? {
        if let inferred = defaultPlaylistServerSourceKey(for: tracks) {
            return inferred
        }

        for track in tracks {
            if let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id),
               let source = serverSourceKey(from: cachedTrack.sourceCompositeKey) {
                return source
            }
        }

        if let currentTrack,
           let cachedTrack = try? await libraryRepository.fetchTrack(ratingKey: currentTrack.id),
           let source = serverSourceKey(from: cachedTrack.sourceCompositeKey) {
            return source
        }

        return nil
    }

    public func loadPlaylists(forServerSourceKey sourceKey: String? = nil) async throws -> [Playlist] {
        try await syncCoordinator.fetchPlaylists(forServerSourceKey: sourceKey)
    }

    public func addCurrentTrack(to playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        guard let currentTrack else {
            throw PlaylistMutationError.emptySelection
        }
        return try await addTracks([currentTrack], to: playlist)
    }

    public func addTracks(_ tracks: [Track], to playlist: Playlist) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let result = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
        await MainActor.run {
            if result.skippedCount > 0 {
                self.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "exclamationmark.triangle.fill",
                        title: "Added to \(playlist.title)",
                        message: "Added \(result.addedCount), skipped \(result.skippedCount) incompatible.",
                        dedupeKey: "playlist-add-\(playlist.id)"
                    )
                )
            } else {
                self.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "checkmark.circle.fill",
                        title: "Added to \(playlist.title)",
                        message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
                        dedupeKey: "playlist-add-\(playlist.id)"
                    )
                )
            }
        }
        return result
    }

    public func createPlaylist(
        title: String,
        tracks: [Track],
        serverSourceKey: String
    ) async throws -> PlaylistMutationResult {
        guard !isPlaylistMutationInProgress else {
            throw PlaylistActionError.operationInProgress
        }
        isPlaylistMutationInProgress = true
        defer { isPlaylistMutationInProgress = false }

        let result = try await syncCoordinator.createPlaylist(
            title: title,
            tracks: tracks,
            serverSourceKey: serverSourceKey
        )
        await MainActor.run {
            if result.skippedCount > 0 {
                self.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        message: "Added \(result.addedCount), skipped \(result.skippedCount).",
                        dedupeKey: "playlist-create-\(title.lowercased())"
                    )
                )
            } else {
                self.toastCenter.show(
                    ToastPayload(
                        style: .success,
                        iconSystemName: "plus.circle.fill",
                        title: "Created \(title)",
                        message: result.addedCount == 1 ? "1 track added." : "\(result.addedCount) tracks added.",
                        dedupeKey: "playlist-create-\(title.lowercased())"
                    )
                )
            }
        }
        return result
    }

    public func resolveLastPlaylistTarget() async -> Playlist? {
        guard let lastPlaylistTarget else { return nil }
        do {
            let playlists = try await loadPlaylists(forServerSourceKey: lastPlaylistTarget.sourceCompositeKey)
            return playlists.first { $0.id == lastPlaylistTarget.id }
        } catch {
            return nil
        }
    }

    public func resolveLastPlaylistTarget(for tracks: [Track]) async -> Playlist? {
        let serverSourceKey = defaultPlaylistServerSourceKey(for: tracks)
        guard let target = syncCoordinator.lastPlaylistTarget(forServerSourceKey: serverSourceKey) else {
            return nil
        }
        do {
            let playlists = try await loadPlaylists(forServerSourceKey: serverSourceKey)
            return playlists.first { $0.id == target.id }
        } catch {
            return nil
        }
    }

    public func compatibleTrackCount(_ tracks: [Track], for playlist: Playlist) -> Int {
        guard let playlistServerSourceKey = playlist.sourceCompositeKey else { return 0 }
        return tracks.reduce(0) { count, track in
            guard let trackServerSourceKey = serverSourceKey(from: track.sourceCompositeKey) else {
                // Unknown source should not hard-block selection; mutation flow resolves via cache lookup.
                return count + 1
            }
            return count + (trackServerSourceKey == playlistServerSourceKey ? 1 : 0)
        }
    }

    public func compatibleTrackCount(_ tracks: [Track], forServerSourceKey serverSourceKey: String?) -> Int {
        guard let serverSourceKey else { return 0 }
        return tracks.reduce(0) { count, track in
            guard let trackServerSourceKey = self.serverSourceKey(from: track.sourceCompositeKey) else {
                return count + 1
            }
            return count + (trackServerSourceKey == serverSourceKey ? 1 : 0)
        }
    }

    public func tracks(_ tracks: [Track], compatibleWithServerSourceKey serverSourceKey: String?) -> [Track] {
        guard let serverSourceKey else { return [] }
        var seen = Set<String>()
        var filtered: [Track] = []
        for track in tracks {
            if let trackServerSourceKey = self.serverSourceKey(from: track.sourceCompositeKey),
               trackServerSourceKey != serverSourceKey {
                continue
            }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            if track.sourceCompositeKey == nil {
                filtered.append(trackWithSourceCompositeKey(track, sourceCompositeKey: serverSourceKey))
            } else {
                filtered.append(track)
            }
        }
        return filtered
    }

    /// Queue snapshot used by "Save current queue":
    /// history + current + upcoming, excluding autoplay tracks and deduping by track id.
    public func queueSnapshotForPlaylistSave() -> [Track] {
        var combined: [Track] = playbackHistory.map(\.track)
        if let currentTrack {
            combined.append(currentTrack)
        }

        let upcomingStart = max(0, currentQueueIndex + 1)
        if upcomingStart < queue.count {
            combined.append(contentsOf: queue[upcomingStart...].map(\.track))
        }

        var seen = Set<String>()
        var deduped: [Track] = []
        for track in combined {
            if isTrackAutoGenerated(track.id) { continue }
            guard !seen.contains(track.id) else { continue }
            seen.insert(track.id)
            deduped.append(track)
        }
        return deduped
    }

    public func clearQueue() {
        playbackService.clearQueue()
    }

    public func playFromQueue(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        Task {
            await playbackService.playQueueIndex(index)
        }
    }

    public func playFromHistory(at historyIndex: Int) {
        Task {
            await playbackService.playFromHistory(at: historyIndex)
        }
    }

    // MARK: - Shuffle & Repeat

    public func toggleShuffle() {
        playbackService.toggleShuffle()
    }

    public func cycleRepeatMode() {
        playbackService.cycleRepeatMode()
    }

    // MARK: - Autoplay & Radio

    public func toggleAutoplay() {
        playbackService.toggleAutoplay()
    }

    public func toggleHistory() {
        showHistory.toggle()
    }

    public func isTrackAutoGenerated(_ trackId: String) -> Bool {
        playbackService.isTrackAutoGenerated(trackId: trackId)
    }

    public func playArtistRadio(for artist: Artist) {
        print("🎙️ NowPlayingViewModel.playArtistRadio() called for: \(artist.name)")
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            print("⚠️ Use enableRadio(tracks:) instead")
        }
    }

    public func playAlbumRadio(for album: Album) {
        print("🎙️ NowPlayingViewModel.playAlbumRadio() called for: \(album.title)")
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            print("⚠️ Use enableRadio(tracks:) instead")
        }
    }

    public func enableRadio(tracks: [Track]) {
        print("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        Task {
            await playbackService.enableRadio(tracks: tracks)
        }
    }

    // MARK: - Rating Management
    
    /// Toggle rating through three states: none → loved → disliked → none
    public func toggleRating() {
        Task {
            guard let track = currentTrack else { return }
            
            let newRating: TrackRating
            switch currentRating {
            case .none:
                newRating = .loved
            case .loved:
                newRating = .disliked
            case .disliked:
                newRating = .none
            }
            
            // Mark that we're updating to prevent overwriting
            await MainActor.run {
                self.isUpdatingRating = true
                self.currentRating = newRating
            }
            
            // Send to server
            do {
                try await syncCoordinator.rateTrack(
                    track: track,
                    rating: newRating.plexRating
                )
                
                // Update in CoreData
                try await updateTrackRatingInDatabase(trackId: track.id, rating: newRating.plexRating ?? 0)
                
                // Refresh the track to get updated data
                if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                    let refreshedTrack = Track(from: updatedTrack)
                    await MainActor.run {
                        // Update currentTrack if it's still the same track
                        if self.currentTrack?.id == track.id {
                            self.currentTrack = refreshedTrack
                        }
                    }
                }
                
                // Clear the updating flag
                await MainActor.run {
                    self.isUpdatingRating = false
                }
            } catch {
                print("Failed to update rating: \(error)")
                // Revert on error
                await MainActor.run {
                    self.isUpdatingRating = false
                    self.currentRating = TrackRating.from(rating: track.rating)
                }
            }
        }
    }
    
    private func updateTrackRatingInDatabase(trackId: String, rating: Int) async throws {
        // Use LibraryRepository implementation's CoreDataStack
        let context = CoreDataStack.shared.newBackgroundContext()
        try await context.perform {
            let request = CDTrack.fetchRequest()
            request.predicate = NSPredicate(format: "ratingKey == %@", trackId)
            
            if let cdTrack = try context.fetch(request).first {
                cdTrack.rating = Int16(rating)
                try context.save()
            }
        }
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func serverSourceKey(from sourceCompositeKey: String?) -> String? {
        guard let sourceCompositeKey else { return nil }
        let components = sourceCompositeKey.split(separator: ":")
        guard components.count >= 3 else { return nil }
        return "\(components[0]):\(components[1]):\(components[2])"
    }

    private func trackWithSourceCompositeKey(_ track: Track, sourceCompositeKey: String) -> Track {
        Track(
            id: track.id,
            key: track.key,
            title: track.title,
            artistName: track.artistName,
            albumName: track.albumName,
            albumRatingKey: track.albumRatingKey,
            artistRatingKey: track.artistRatingKey,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            duration: track.duration,
            thumbPath: track.thumbPath,
            fallbackThumbPath: track.fallbackThumbPath,
            fallbackRatingKey: track.fallbackRatingKey,
            streamKey: track.streamKey,
            streamId: track.streamId,
            localFilePath: track.localFilePath,
            dateAdded: track.dateAdded,
            dateModified: track.dateModified,
            lastPlayed: track.lastPlayed,
            rating: track.rating,
            playCount: track.playCount,
            sourceCompositeKey: sourceCompositeKey
        )
    }
}
