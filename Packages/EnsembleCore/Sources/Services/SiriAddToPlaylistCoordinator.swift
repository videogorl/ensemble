import EnsemblePersistence
import Foundation

/// Executes Siri "add to playlist" requests inside the main app process.
@MainActor
public final class SiriAddToPlaylistCoordinator {
    private let playbackService: PlaybackServiceProtocol
    private let mutationCoordinator: MutationCoordinator
    private let playlistRepository: PlaylistRepositoryProtocol
    private let toastCenter: ToastCenter

    public init(
        playbackService: PlaybackServiceProtocol,
        mutationCoordinator: MutationCoordinator,
        playlistRepository: PlaylistRepositoryProtocol,
        toastCenter: ToastCenter
    ) {
        self.playbackService = playbackService
        self.mutationCoordinator = mutationCoordinator
        self.playlistRepository = playlistRepository
        self.toastCenter = toastCenter
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

        let playlist = Playlist(from: cdPlaylist)

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
