import EnsembleSiriShared
import Foundation
import Intents
import OSLog

public final class AddMediaIntentHandler: NSObject, INAddMediaIntentHandling {
    private static let pendingFilename = "siri-pending-addtoplaylist.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingAddToPlaylist"

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
            SiriMatchingHelpers.record("resolveDestination", "needsName")
            completion(.needsValue())
            return
        }

        logger.info("resolveMediaDestination: queryLength=\(playlistName.count, privacy: .public)")

        guard let index = SiriMatchingHelpers.loadIndex() else {
            logger.warning("resolveMediaDestination: index unavailable; returning needsValue")
            SiriMatchingHelpers.record("resolveDestination", "indexUnavailable")
            completion(.needsValue())
            return
        }

        switch SiriMatchingHelpers.resolveVoiceAdd(named: playlistName, in: index, event: "resolveDestination") {
        case .deferToApp:
            // No presentation for this index: the name goes to the app as spoken, which resolves it itself.
            logger.info("resolveMediaDestination: no playlist presentation; deferring the name to the app")
            completion(.success(with: INMediaDestination.playlist(playlistName)))
        case let .chosen(destination):
            logger.info("resolveMediaDestination: matched playlist")
            completion(.success(with: INMediaDestination.playlist(destination.name)))
        case let .choices(options):
            logger.info("resolveMediaDestination: disambiguating \(options.count, privacy: .public) options")
            completion(.disambiguation(with: options.map { INMediaDestination.playlist($0.name) }))
        case .notFound:
            logger.info("resolveMediaDestination: no playlist match found")
            completion(.unsupported(forReason: .playlistNameNotFound))
        case .notEditable:
            logger.info("resolveMediaDestination: the best match is a smart playlist; not writable")
            completion(.unsupported(forReason: .playlistNotEditable))
        }
    }

    public func handle(
        intent: INAddMediaIntent,
        completion: @escaping (INAddMediaIntentResponse) -> Void
    ) {
        // Resolve the playlist from the destination
        guard let destination = intent.mediaDestination,
              let playlistName = destination.playlistName, !playlistName.isEmpty else {
            logger.error("handle: missing playlist destination")
            SiriMatchingHelpers.record("handleAdd", "missingDestination")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        logger.info("handle: playlistNameLength=\(playlistName.count, privacy: .public)")

        guard let index = SiriMatchingHelpers.loadIndex() else {
            logger.error("handle: index unavailable")
            SiriMatchingHelpers.record("handleAdd", "indexUnavailable")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        // Only a name that stands for exactly one playlist is written; with no presentation, a name-only request the
        // app resolves itself.
        let payload: PendingAddToPlaylistPayload
        switch SiriMatchingHelpers.resolveVoiceAdd(named: playlistName, in: index, event: "handleAdd") {
        case .deferToApp:
            payload = PendingAddToPlaylistPayload(playlistRatingKey: "", sourceCompositeKey: "", playlistDisplayName: playlistName)
        case let .chosen(destination):
            payload = PendingAddToPlaylistPayload(
                playlistRatingKey: destination.item.id,
                sourceCompositeKey: destination.item.sourceCompositeKey ?? "",
                playlistDisplayName: destination.item.displayName
            )
        case .choices, .notFound, .notEditable:
            logger.error("handle: destination name does not stand for exactly one playlist")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        guard SiriPendingIntentBridge.writePayload(
            payload,
            filename: Self.pendingFilename,
            logger: logger,
            context: "add-to-playlist"
        ) else {
            SiriMatchingHelpers.record("handleAdd", "writeFailed")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        SiriPendingIntentBridge.postDarwinNotification(
            named: Self.darwinNotificationName,
            logger: logger,
            context: "add-to-playlist"
        )

        SiriMatchingHelpers.record("handleAdd", "handedToApp")
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
