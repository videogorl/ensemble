import Combine
import Foundation
import EnsemblePersistence
import Nuke
import SwiftUI

#if os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#endif

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
    @Published public var lastPlaylistTarget: LastPlaylistTarget?
    @Published public private(set) var artworkImage: PlatformImage?
    @Published private var optimisticTrackRatings: [String: Int] = [:]

    private let playbackService: PlaybackServiceProtocol
    private let syncCoordinator: SyncCoordinator
    private let libraryRepository: LibraryRepositoryProtocol
    private let navigationCoordinator: NavigationCoordinator
    private let toastCenter: ToastCenter
    private let pendingMutationQueue: PendingMutationQueue
    private var cancellables = Set<AnyCancellable>()
    
    // Artwork loading state
    private var artworkLoadTask: Task<Void, Never>?
    private var currentLoadTrackID: String?
    
    // Track if we're currently updating the rating to prevent overwriting
    private var isUpdatingRating = false
    private var favoriteUpdatesInFlight = Set<String>()
    internal var trackRatingMutationHandlerForTesting: ((Track, Int?) async throws -> Void)?
    internal var trackRatingStoreHandlerForTesting: ((String, Int) async throws -> Void)?

    public init(
        playbackService: PlaybackServiceProtocol,
        syncCoordinator: SyncCoordinator,
        libraryRepository: LibraryRepositoryProtocol,
        navigationCoordinator: NavigationCoordinator,
        toastCenter: ToastCenter,
        pendingMutationQueue: PendingMutationQueue
    ) {
        self.playbackService = playbackService
        self.syncCoordinator = syncCoordinator
        self.libraryRepository = libraryRepository
        self.navigationCoordinator = navigationCoordinator
        self.toastCenter = toastCenter
        self.pendingMutationQueue = pendingMutationQueue
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

        // Reset duration when track changes, then let periodic playback updates refine it.
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self else { return }
                if track == nil {
                    self.duration = 0
                } else {
                    self.duration = self.playbackService.duration
                }
            }
            .store(in: &cancellables)

        // Keep duration synchronized with AVPlayer's effective item duration as playback advances.
        playbackService.currentTimePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let latestDuration = self.playbackService.duration
                guard latestDuration.isFinite else { return }
                if abs(self.duration - latestDuration) > 0.05 {
                    self.duration = latestDuration
                }
            }
            .store(in: &cancellables)
        
        // Update rating when track changes (but not if we're actively updating it)
        $currentTrack
            .sink { [weak self] track in
                guard let self = self, !self.isUpdatingRating else { return }
                guard let track = track else {
                    self.currentRating = .none
                    return
                }
                self.currentRating = TrackRating.from(rating: self.trackDisplayRating(for: track))
            }
            .store(in: &cancellables)

        // Automatically load artwork when track changes
        $currentTrack
            .receive(on: DispatchQueue.main)
            .sink { [weak self] track in
                guard let self = self else { return }
                if let track = track {
                    self.loadArtworkImage(for: track)
                } else {
                    self.artworkLoadTask?.cancel()
                    self.artworkImage = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Artwork Management

    private func loadArtworkImage(for track: Track) {
        let trackID = track.id
        guard currentLoadTrackID != trackID else { return }
        
        artworkLoadTask?.cancel()
        currentLoadTrackID = trackID
        
        artworkLoadTask = Task { @MainActor in
            // Check if cancelled early
            guard !Task.isCancelled else { return }
            
            // Get artwork URL
            let deps = DependencyContainer.shared
            if let artworkURL = await deps.artworkLoader.artworkURLAsync(
                for: track.thumbPath,
                sourceKey: track.sourceCompositeKey,
                ratingKey: track.id,
                fallbackPath: track.fallbackThumbPath,
                fallbackRatingKey: track.fallbackRatingKey,
                size: 600 // Use slightly larger size for background
            ) {
                guard !Task.isCancelled else { return }
                
                // Check Nuke cache first for instant display
                let request = Nuke.ImageRequest(url: artworkURL)
                
                // Try synchronous cache lookup first
                if let cachedImage = Nuke.ImagePipeline.shared.cache.cachedImage(for: request) {
                    guard !Task.isCancelled else { return }
                    
                    if self.currentLoadTrackID == trackID {
                        self.artworkImage = cachedImage.image
                    }
                    return
                }
                
                // Load asynchronously if not cached
                if let result = try? await Nuke.ImagePipeline.shared.image(for: request) {
                    guard !Task.isCancelled else { return }
                    
                    // Only update if this is still the current track
                    if self.currentLoadTrackID == trackID {
                        // Using a smooth cross-fade transition.
                        // DO NOT REMOVE THIS - it ensures beautiful track transitions.
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.artworkImage = result
                        }
                    }
                }
            } else {
                // No artwork URL available - clear previous artwork
                guard !Task.isCancelled else { return }
                
                if self.currentLoadTrackID == trackID {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.artworkImage = nil
                    }
                }
            }
        }
    }

    // MARK: - Computed Properties

    public var currentTime: TimeInterval {
        playbackService.currentTimeValue
    }

    /// Keeps the scrubber from reaching 100% while playback is still active when
    /// stream metadata under-reports duration.
    public var scrubberDuration: TimeInterval {
        let baseDuration = max(0, duration)
        guard currentTrack != nil else { return baseDuration }

        switch playbackState {
        case .playing, .buffering, .loading:
            return max(baseDuration, currentTime + 1.0)
        default:
            return max(baseDuration, currentTime)
        }
    }

    public var progress: Double {
        let displayDuration = scrubberDuration
        guard displayDuration > 0 else { return 0 }
        return max(0, min(1, currentTime / displayDuration))
    }

    public var bufferedProgress: Double {
        max(0, min(1, playbackService.bufferedProgressValue))
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
        let remaining = max(0, scrubberDuration - currentTime)
        return "-" + formatTime(remaining)
    }
    
    /// Queue split into sections for UI display
    public var queueSections: QueueSections {
        playbackService.queueSections
    }

    // MARK: - Album Metadata

    /// Fetch album metadata for the current track (for Info card display)
    public func fetchAlbumForCurrentTrack() async -> Album? {
        guard let albumRatingKey = currentTrack?.albumRatingKey else { return nil }
        do {
            if let cdAlbum = try await libraryRepository.fetchAlbum(ratingKey: albumRatingKey) {
                return Album(from: cdAlbum)
            }
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Failed to fetch album for current track: \(error)")
            #endif
        }
        return nil
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
        let time = progress * scrubberDuration
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

    public func playNext(_ tracks: [Track]) {
        playbackService.playNext(tracks)
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

        // If offline, enqueue the mutation and show a deferred confirmation toast.
        if syncCoordinator.isOffline, let playlistSourceKey = playlist.sourceCompositeKey {
            let tracksBySource = Dictionary(grouping: tracks) { $0.sourceCompositeKey ?? playlistSourceKey }
            for (sourceKey, sourceTracks) in tracksBySource {
                let payload = PlaylistMutationPayload(
                    playlistRatingKey: playlist.id,
                    playlistSourceCompositeKey: playlistSourceKey,
                    trackRatingKeys: sourceTracks.map(\.id),
                    trackSourceCompositeKey: sourceKey
                )
                await pendingMutationQueue.enqueuePlaylistAdd(payload)
            }
            toastCenter.show(
                ToastPayload(
                    style: .info,
                    iconSystemName: "clock.arrow.circlepath",
                    title: "Queued for \(playlist.title)",
                    message: "Will be added when back online.",
                    dedupeKey: "playlist-add-queued-\(playlist.id)"
                )
            )
            return PlaylistMutationResult(addedCount: 0, skippedCount: 0)
        }

        let result = try await syncCoordinator.addTracksToPlaylist(tracks, playlist: playlist)
        await MainActor.run {
            if result.skippedCount > 0 {
                self.toastCenter.show(
                    ToastPayload(
                        style: .warning,
                        iconSystemName: "exclamationmark.triangle.fill",
                        title: "Added to \(playlist.title)",
                        message: "Added \(result.addedCount), skipped \(result.skippedCount) incompatible.",
                        tapHandler: { [weak self] in
                            self?.navigationCoordinator.navigateFromNowPlaying(
                                to: .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
                            )
                        },
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
                        tapHandler: { [weak self] in
                            self?.navigationCoordinator.navigateFromNowPlaying(
                                to: .playlist(id: playlist.id, sourceKey: playlist.sourceCompositeKey)
                            )
                        },
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
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.playArtistRadio() called for: \(artist.name)")
        #endif
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            #if DEBUG
            EnsembleLogger.debug("⚠️ Use enableRadio(tracks:) instead")
            #endif
        }
    }

    public func playAlbumRadio(for album: Album) {
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.playAlbumRadio() called for: \(album.title)")
        #endif
        Task {
            // This will be handled by the view passing filteredTracks from the detail view
            // For now this is a placeholder for backwards compatibility
            #if DEBUG
            EnsembleLogger.debug("⚠️ Use enableRadio(tracks:) instead")
            #endif
        }
    }

    public func enableRadio(tracks: [Track]) {
        #if DEBUG
        EnsembleLogger.debug("🎙️ NowPlayingViewModel.enableRadio() called with \(tracks.count) tracks")
        #endif
        Task {
            await playbackService.enableRadio(tracks: tracks)
        }
    }

    // MARK: - Rating Management

    public func isTrackFavorited(_ track: Track) -> Bool {
        trackDisplayRating(for: track) >= 8
    }

    public func setTrackFavorite(_ isFavorite: Bool, for track: Track) async {
        guard !favoriteUpdatesInFlight.contains(track.id) else { return }
        favoriteUpdatesInFlight.insert(track.id)
        defer { favoriteUpdatesInFlight.remove(track.id) }

        let plexRating: Int? = isFavorite ? 10 : nil
        let optimisticRating = isFavorite ? 10 : 0
        let previousRating = trackDisplayRating(for: track)
        let loadingToast = ToastPayload(
            style: .info,
            iconSystemName: "heart.fill",
            title: isFavorite ? "Adding to Favorites..." : "Removing from Favorites...",
            isPersistent: true,
            dedupeKey: "favorite-toggle-loading-\(track.id)",
            showsActivityIndicator: true
        )
        toastCenter.show(loadingToast)
        defer { toastCenter.dismiss(id: loadingToast.id) }

        do {
            // Optimistically update local state so UI reflects the change immediately.
            optimisticTrackRatings[track.id] = optimisticRating
            try await storeTrackRating(trackId: track.id, rating: optimisticRating)
            applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: optimisticRating)

            // If offline, keep the optimistic state and queue the mutation for later.
            if syncCoordinator.isOffline {
                if let sourceKey = track.sourceCompositeKey {
                    let payload = TrackRatingMutationPayload(
                        trackRatingKey: track.id,
                        sourceCompositeKey: sourceKey,
                        rating: plexRating
                    )
                    await pendingMutationQueue.enqueueTrackRating(payload)
                }
                toastCenter.show(
                    ToastPayload(
                        style: .info,
                        iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
                        title: isFavorite ? "Saved — will sync when online" : "Removed — will sync when online",
                        message: track.title,
                        dedupeKey: "favorite-toggle-queued-\(track.id)-\(isFavorite ? 1 : 0)"
                    )
                )
                return
            }

            if let trackRatingMutationHandlerForTesting {
                try await trackRatingMutationHandlerForTesting(track, plexRating)
            } else {
                try await syncCoordinator.rateTrack(track: track, rating: plexRating)
            }

            if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                let refreshedTrack = Track(from: updatedTrack)
                optimisticTrackRatings[track.id] = refreshedTrack.rating
                updateCurrentTrackIfNeeded(refreshedTrack)
            } else {
                optimisticTrackRatings[track.id] = optimisticRating
            }

            toastCenter.show(
                ToastPayload(
                    style: .success,
                    iconSystemName: isFavorite ? "heart.fill" : "heart.slash.fill",
                    title: isFavorite ? "Added to Favorites" : "Removed from Favorites",
                    message: track.title,
                    dedupeKey: "favorite-toggle-success-\(track.id)-\(isFavorite ? 1 : 0)"
                )
            )
        } catch {
            // Roll back optimistic state if server mutation fails.
            optimisticTrackRatings[track.id] = previousRating
            try? await storeTrackRating(trackId: track.id, rating: previousRating)
            applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: previousRating)

            toastCenter.show(
                ToastPayload(
                    style: .error,
                    iconSystemName: "xmark.octagon.fill",
                    title: "Could not update favorite",
                    message: error.localizedDescription,
                    dedupeKey: "favorite-toggle-error-\(track.id)"
                )
            )
            #if DEBUG
            EnsembleLogger.debug("Failed to set favorite state: \(error)")
            #endif
        }
    }

    public func toggleTrackFavorite(_ track: Track) async {
        await setTrackFavorite(!isTrackFavorited(track), for: track)
    }
    
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
            
            let previousRating = trackDisplayRating(for: track)
            let nextPlexRating = newRating.plexRating
            let nextDisplayRating = nextPlexRating ?? 0

            // Mark that we're updating to prevent overwriting
            await MainActor.run {
                self.isUpdatingRating = true
                self.currentRating = newRating
                self.optimisticTrackRatings[track.id] = nextDisplayRating
            }
            
            // Send to server
            do {
                // Apply optimistic local update for immediate consistency with swipe-driven state.
                try await storeTrackRating(trackId: track.id, rating: nextDisplayRating)
                applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: nextDisplayRating)

                if let trackRatingMutationHandlerForTesting {
                    try await trackRatingMutationHandlerForTesting(track, nextPlexRating)
                } else {
                    try await syncCoordinator.rateTrack(
                        track: track,
                        rating: nextPlexRating
                    )
                }
                
                // Refresh the track to get updated data
                if let updatedTrack = try? await libraryRepository.fetchTrack(ratingKey: track.id) {
                    let refreshedTrack = Track(from: updatedTrack)
                    await MainActor.run {
                        self.optimisticTrackRatings[track.id] = refreshedTrack.rating
                        // Update currentTrack if it's still the same track
                        if self.currentTrack?.id == track.id {
                            self.currentTrack = refreshedTrack
                        }
                    }
                } else {
                    await MainActor.run {
                        self.optimisticTrackRatings[track.id] = nextDisplayRating
                    }
                }
                
                // Clear the updating flag
                await MainActor.run {
                    self.isUpdatingRating = false
                }
            } catch {
                #if DEBUG
                EnsembleLogger.debug("Failed to update rating: \(error)")
                #endif
                // Revert on error
                await MainActor.run {
                    self.optimisticTrackRatings[track.id] = previousRating
                    self.isUpdatingRating = false
                    self.currentRating = TrackRating.from(rating: previousRating)
                }
                try? await storeTrackRating(trackId: track.id, rating: previousRating)
                applyCurrentTrackRatingIfNeeded(trackId: track.id, rating: previousRating)
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

    private func storeTrackRating(trackId: String, rating: Int) async throws {
        if let trackRatingStoreHandlerForTesting {
            try await trackRatingStoreHandlerForTesting(trackId, rating)
        } else {
            try await updateTrackRatingInDatabase(trackId: trackId, rating: rating)
        }
    }

    private func applyCurrentTrackRatingIfNeeded(trackId: String, rating: Int) {
        guard let currentTrack, currentTrack.id == trackId else { return }
        self.currentTrack = trackWithRating(currentTrack, rating: rating)
        currentRating = TrackRating.from(rating: rating)
    }

    private func updateCurrentTrackIfNeeded(_ track: Track) {
        guard currentTrack?.id == track.id else { return }
        currentTrack = track
        currentRating = TrackRating.from(rating: track.rating)
    }

    private func trackDisplayRating(for track: Track) -> Int {
        optimisticTrackRatings[track.id] ?? track.rating
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

    private func trackWithRating(_ track: Track, rating: Int) -> Track {
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
            rating: rating,
            playCount: track.playCount,
            sourceCompositeKey: track.sourceCompositeKey
        )
    }
}
