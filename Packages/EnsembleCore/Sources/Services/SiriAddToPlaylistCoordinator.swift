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
    /// The one visible, editable playlist a spoken name stands for; used when Siri sent no identity.
    private let resolveName: @MainActor (String) async throws -> CDPlaylist?

    public init(
        playbackService: PlaybackServiceProtocol,
        mutationCoordinator: MutationCoordinator,
        playlistRepository: PlaylistRepositoryProtocol,
        toastCenter: ToastCenter,
        addTarget: @escaping @MainActor (Playlist, [Track]) async throws -> Playlist?,
        resolveName: @escaping @MainActor (String) async throws -> CDPlaylist?
    ) {
        self.playbackService = playbackService
        self.mutationCoordinator = mutationCoordinator
        self.playlistRepository = playlistRepository
        self.toastCenter = toastCenter
        self.addTarget = addTarget
        self.resolveName = resolveName
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

    /// Executes a Siri add-to-playlist payload, logging the request and its outcome (codes only, no titles).
    public func execute(payload: SiriAddToPlaylistRequestPayload) async throws {
        let nameOnly = payload.playlistRatingKey.isEmpty
        EnsembleLogger.info("SIRI_APP: add-to-playlist request nameOnly=\(nameOnly) nameLength=\(payload.playlistDisplayName?.count ?? 0)")
        do {
            let outcome = try await perform(payload: payload)
            EnsembleLogger.info("SIRI_APP: add-to-playlist outcome=\(outcome) nameOnly=\(nameOnly)")
        } catch {
            EnsembleLogger.error("SIRI_APP: add-to-playlist outcome=error nameOnly=\(nameOnly) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func perform(payload: SiriAddToPlaylistRequestPayload) async throws -> String {
        guard payload.schemaVersion == SiriAddToPlaylistRequestPayload.currentSchemaVersion else {
            return "unsupportedSchema"
        }

        guard let currentTrack = playbackService.currentTrack else {
            toastCenter.show(ToastPayload(
                style: .warning,
                iconSystemName: "exclamationmark.triangle",
                title: "No track playing",
                message: "Play a track first, then try again."
            ))
            return "noCurrentTrack"
        }

        // Resolve the playlist from CoreData. A name-only request (no identity) is resolved here, where the playlist
        // screen's visibility rules are known.
        let resolved: CDPlaylist?
        if payload.playlistRatingKey.isEmpty, let name = payload.playlistDisplayName {
            resolved = try await resolveName(name)
        } else {
            resolved = try await playlistRepository.fetchPlaylist(
                ratingKey: payload.playlistRatingKey,
                sourceCompositeKey: payload.sourceCompositeKey
            )
        }
        guard let cdPlaylist = resolved else {
            let name = payload.playlistDisplayName ?? payload.playlistRatingKey
            toastCenter.show(ToastPayload(
                style: .error,
                iconSystemName: "exclamationmark.triangle",
                title: "Playlist not found",
                message: "\"\(name)\" could not be found."
            ))
            return "playlistNotFound"
        }

        // A merged group takes the song on its own server, as the Add to Playlist sheet does.
        guard let playlist = try await addTarget(Playlist(from: cdPlaylist), [currentTrack]) else {
            toastCenter.show(ToastPayload(
                style: .warning,
                iconSystemName: "exclamationmark.triangle",
                title: "Can't add to that playlist",
                message: "The song and the playlist are on different music sources. Pick a playlist on the same server as the song."
            ))
            return "differentSources"
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
        return outcome == .queued ? "queued" : "added"
    }
}
