import Foundation
import Intents
import OSLog

public final class AddMediaIntentHandler: NSObject, INAddMediaIntentHandling {
    private static let pendingFilename = "siri-pending-addtoplaylist.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingAddToPlaylist"
    private static let disambiguationThreshold = 0.1

    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "AddMediaIntentHandler"
    )

    public override init() {
        super.init()
        SiriExtensionLogger.info("SIRI_EXT: AddMediaIntentHandler.init()")
    }

    // MARK: - INAddMediaIntentHandling

    public func resolveMediaItems(
        for intent: INAddMediaIntent,
        with completion: @escaping ([INAddMediaMediaItemResolutionResult]) -> Void
    ) {
        // The "media to add" is the current track -- no resolution needed.
        logger.info("resolveMediaItems: returning success for current track")
        completion([.success(with: SiriMatchingHelpers.currentTrackMediaItem())])
    }

    public func resolveMediaDestination(
        for intent: INAddMediaIntent,
        with completion: @escaping (INAddMediaMediaDestinationResolutionResult) -> Void
    ) {
        guard let destination = intent.mediaDestination,
              let playlistName = destination.playlistName, !playlistName.isEmpty else {
            logger.info("resolveMediaDestination: no playlist name; requesting value")
            completion(.needsValue())
            return
        }

        logger.info("resolveMediaDestination: queryLength=\(playlistName.count, privacy: .public)")

        guard let index = SiriMatchingHelpers.loadIndex() else {
            logger.warning("resolveMediaDestination: index unavailable; returning needsValue")
            completion(.needsValue())
            return
        }

        let ranked = SiriMatchingHelpers.rankPlaylistCandidates(for: playlistName, index: index)

        guard let top = ranked.first else {
            logger.info("resolveMediaDestination: no playlist match found")
            completion(.unsupported(forReason: .playlistNameNotFound))
            return
        }

        // Check if disambiguation is needed
        if ranked.count > 1 {
            let second = ranked[1]
            if abs(top.score - second.score) <= Self.disambiguationThreshold {
                logger.info("resolveMediaDestination: disambiguating \(ranked.count, privacy: .public) options")
                let options = Array(ranked.prefix(6)).map { ranked in
                    INMediaDestination.playlist(ranked.item.displayName)
                }
                completion(.disambiguation(with: options))
                return
            }
        }

        logger.info("resolveMediaDestination: matched playlist")
        completion(.success(with: INMediaDestination.playlist(top.item.displayName)))
    }

    public func handle(
        intent: INAddMediaIntent,
        completion: @escaping (INAddMediaIntentResponse) -> Void
    ) {
        // Resolve the playlist from the destination
        guard let destination = intent.mediaDestination,
              let playlistName = destination.playlistName, !playlistName.isEmpty else {
            logger.error("handle: missing playlist destination")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        logger.info("handle: playlistNameLength=\(playlistName.count, privacy: .public)")

        // Find the playlist in the index to get its ratingKey
        guard let index = SiriMatchingHelpers.loadIndex() else {
            logger.error("handle: index unavailable")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let ranked = SiriMatchingHelpers.rankPlaylistCandidates(for: playlistName, index: index)
        guard let match = ranked.first else {
            logger.error("handle: no matching playlist found")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let payload = PendingAddToPlaylistPayload(
            playlistRatingKey: match.item.id,
            sourceCompositeKey: match.item.sourceCompositeKey ?? "",
            playlistDisplayName: match.item.displayName
        )
        guard SiriPendingIntentBridge.writePayload(
            payload,
            filename: Self.pendingFilename,
            logger: logger,
            context: "add-to-playlist"
        ) else {
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        SiriPendingIntentBridge.postDarwinNotification(
            named: Self.darwinNotificationName,
            logger: logger,
            context: "add-to-playlist"
        )

        logger.info("handle: wrote pending add-to-playlist file + posted Darwin notification, returning success")
        completion(INAddMediaIntentResponse(code: .success, userActivity: nil))
    }
}

private struct PendingAddToPlaylistPayload: Encodable {
    let schemaVersion = 1
    let playlistRatingKey: String
    let sourceCompositeKey: String
    let playlistDisplayName: String
}
