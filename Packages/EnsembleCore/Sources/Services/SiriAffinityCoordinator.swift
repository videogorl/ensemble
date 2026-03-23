import Foundation

/// Executes Siri affinity (love/dislike) requests inside the main app process.
@MainActor
public final class SiriAffinityCoordinator {
    private let playbackService: PlaybackServiceProtocol
    private let mutationCoordinator: MutationCoordinator
    private let toastCenter: ToastCenter

    public init(
        playbackService: PlaybackServiceProtocol,
        mutationCoordinator: MutationCoordinator,
        toastCenter: ToastCenter
    ) {
        self.playbackService = playbackService
        self.mutationCoordinator = mutationCoordinator
        self.toastCenter = toastCenter
    }

    /// Decodes and executes a Siri affinity payload routed through NSUserActivity.
    @discardableResult
    public func handle(userActivity: NSUserActivity) async -> Bool {
        guard userActivity.activityType == SiriAffinityActivityCodec.activityType,
              let payload = SiriAffinityActivityCodec.payload(from: userActivity.userInfo) else {
            return false
        }

        do {
            try await execute(payload: payload)
            return true
        } catch {
            #if DEBUG
            EnsembleLogger.debug("Siri affinity handling failed: \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Executes a Siri affinity payload.
    public func execute(payload: SiriAffinityRequestPayload) async throws {
        guard payload.schemaVersion == SiriAffinityRequestPayload.currentSchemaVersion else {
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

        // Map affinity type to Plex rating:
        // love = 10 (loved), dislike = 2 (disliked), remove = nil (unrated)
        let rating: Int?
        let toastTitle: String
        let toastIcon: String

        switch payload.affinityType {
        case .love:
            rating = 10
            toastTitle = "Loved \(currentTrack.title)"
            toastIcon = "heart.fill"
        case .dislike:
            rating = 2
            toastTitle = "Disliked \(currentTrack.title)"
            toastIcon = "hand.thumbsdown.fill"
        case .remove:
            rating = nil
            toastTitle = "Removed rating for \(currentTrack.title)"
            toastIcon = "heart.slash"
        }

        let outcome = try await mutationCoordinator.rateTrack(currentTrack, rating: rating)

        let message: String? = outcome == .queued ? "Will sync when online" : nil
        toastCenter.show(ToastPayload(
            style: .success,
            iconSystemName: toastIcon,
            title: toastTitle,
            message: message
        ))
    }
}
