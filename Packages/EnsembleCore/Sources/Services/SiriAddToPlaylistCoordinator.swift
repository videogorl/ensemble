import EnsemblePersistence
import EnsembleSiriShared
import Foundation

/// Executes Siri "add to playlist" requests inside the main app process.
@MainActor
public final class SiriAddToPlaylistCoordinator {
    private let playbackService: PlaybackServiceProtocol
    private let mutationCoordinator: MutationCoordinator
    private let playlistRepository: PlaylistRepositoryProtocol
    private let toastCenter: ToastCenter
    private let addTarget: @MainActor (Playlist, [Track]) async throws -> Playlist?

    public init(
        playbackService: PlaybackServiceProtocol,
        mutationCoordinator: MutationCoordinator,
        playlistRepository: PlaylistRepositoryProtocol,
        toastCenter: ToastCenter,
        addTarget: @escaping @MainActor (Playlist, [Track]) async throws -> Playlist?
    ) {
        self.playbackService = playbackService
        self.mutationCoordinator = mutationCoordinator
        self.playlistRepository = playlistRepository
        self.toastCenter = toastCenter
        self.addTarget = addTarget
    }

    /// Decodes and executes a Siri add-to-playlist payload routed through NSUserActivity.
    @discardableResult
    public func handle(userActivity: NSUserActivity) async -> Bool {
        guard userActivity.activityType == SiriAddToPlaylistActivityCodec.activityType,
              let payload = SiriAddToPlaylistActivityCodec.payload(from: userActivity.userInfo) else {
            return false
        }

        do {
            try await execute(payload: payload)
            return true
        } catch {
            EnsembleLogger.debug("Siri add-to-playlist handling failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Executes a Siri add-to-playlist payload.
    public func execute(payload: SiriAddToPlaylistRequestPayload) async throws {
        guard payload.schemaVersion == SiriAddToPlaylistRequestPayload.currentSchemaVersion else {
            return
        }

        guard let currentTrack = playbackService.currentTrack else {
            toastCenter.show(ToastPayload(
                style: .warning,
                iconSystemName: "exclamationmark.triangle",
                title: "No track playing",
                message: "Play a track first, then try again."
            ))
            return
        }

        // Resolve the playlist from CoreData
        guard let cdPlaylist = try await playlistRepository.fetchPlaylist(
            ratingKey: payload.playlistRatingKey,
            sourceCompositeKey: payload.sourceCompositeKey
        ) else {
            let name = payload.playlistDisplayName ?? payload.playlistRatingKey
            toastCenter.show(ToastPayload(
                style: .error,
                iconSystemName: "exclamationmark.triangle",
                title: "Playlist not found",
                message: "\"\(name)\" could not be found."
            ))
            return
        }

        // A merged group takes the song on its own server, as the Add to Playlist sheet does.
        guard let playlist = try await addTarget(Playlist(from: cdPlaylist), [currentTrack]) else {
            toastCenter.show(ToastPayload(
                style: .warning,
                iconSystemName: "exclamationmark.triangle",
                title: "Can't add to that playlist",
                message: "The song and the playlist are on different music sources. Pick a playlist on the same server as the song."
            ))
            return
        }

        let (_, outcome) = try await mutationCoordinator.addTracksToPlaylist(
            [currentTrack],
            playlist: playlist
        )

        let message: String? = outcome == .queued ? "Will sync when online" : nil
        toastCenter.show(ToastPayload(
            style: .success,
            iconSystemName: "text.badge.plus",
            title: "Added to \(playlist.title)",
            message: message ?? "\(currentTrack.title)"
        ))
    }
}
