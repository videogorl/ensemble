import Foundation
import Intents
import OSLog

public final class UpdateMediaAffinityIntentHandler: NSObject, INUpdateMediaAffinityIntentHandling {
    private static let pendingFilename = "siri-pending-affinity.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingAffinity"

    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "UpdateMediaAffinityIntentHandler"
    )

    public override init() {
        super.init()
        SiriExtensionLogger.info("SIRI_EXT: UpdateMediaAffinityIntentHandler.init()")
    }

    // MARK: - INUpdateMediaAffinityIntentHandling

    public func resolveMediaItems(
        for intent: INUpdateMediaAffinityIntent,
        with completion: @escaping ([INUpdateMediaAffinityMediaItemResolutionResult]) -> Void
    ) {
        logger.info("resolveMediaItems: returning success for current track")
        // We act on whatever is currently playing -- no resolution needed.
        completion([.success(with: SiriMatchingHelpers.currentTrackMediaItem())])
    }

    public func resolveAffinityType(
        for intent: INUpdateMediaAffinityIntent,
        with completion: @escaping (INMediaAffinityTypeResolutionResult) -> Void
    ) {
        let affinityType = intent.affinityType
        logger.info("resolveAffinityType: \(affinityType.rawValue, privacy: .public)")

        switch affinityType {
        case .like:
            completion(.success(with: .like))
        case .dislike:
            completion(.success(with: .dislike))
        default:
            // Default to like for "love this song" / "heart this"
            completion(.success(with: .like))
        }
    }

    public func handle(
        intent: INUpdateMediaAffinityIntent,
        completion: @escaping (INUpdateMediaAffinityIntentResponse) -> Void
    ) {
        logger.info("handle: affinityType=\(intent.affinityType.rawValue, privacy: .public)")

        let affinityType: String
        switch intent.affinityType {
        case .like:
            affinityType = "love"
        case .dislike:
            affinityType = "dislike"
        default:
            affinityType = "love"
        }

        let payload = PendingAffinityPayload(affinityType: affinityType)
        guard SiriPendingIntentBridge.writePayload(
            payload,
            filename: Self.pendingFilename,
            logger: logger,
            context: "affinity"
        ) else {
            completion(INUpdateMediaAffinityIntentResponse(code: .failure, userActivity: nil))
            return
        }

        SiriPendingIntentBridge.postDarwinNotification(
            named: Self.darwinNotificationName,
            logger: logger,
            context: "affinity"
        )

        logger.info("handle: wrote pending affinity file + posted Darwin notification, returning success")
        completion(INUpdateMediaAffinityIntentResponse(code: .success, userActivity: nil))
    }
}

private struct PendingAffinityPayload: Encodable {
    let schemaVersion = 1
    let affinityType: String
}
