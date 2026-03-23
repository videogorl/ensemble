import Foundation
import Intents
import os

public final class UpdateMediaAffinityIntentHandler: NSObject, INUpdateMediaAffinityIntentHandling {
    private static let activityType = "com.videogorl.ensemble.siri.updateaffinity"
    private static let payloadUserInfoKey = "siriAffinityPayload"

    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "UpdateMediaAffinityIntentHandler"
    )

    public override init() {
        super.init()
        os_log(.info, "SIRI_EXT: UpdateMediaAffinityIntentHandler.init()")
    }

    // MARK: - INUpdateMediaAffinityIntentHandling

    public func resolveMediaItems(
        for intent: INUpdateMediaAffinityIntent,
        with completion: @escaping ([INUpdateMediaAffinityMediaItemResolutionResult]) -> Void
    ) {
        logger.info("resolveMediaItems: returning success for current track")
        // We act on whatever is currently playing — no resolution needed.
        let currentTrackItem = INMediaItem(
            identifier: "current-track",
            title: "Current Track",
            type: .song,
            artwork: nil
        )
        completion([.success(with: currentTrackItem)])
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

        // Build payload
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "affinityType": affinityType
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadDict) else {
            logger.error("handle: failed to encode payload")
            completion(INUpdateMediaAffinityIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = "Update Affinity in Ensemble"
        activity.userInfo = [Self.payloadUserInfoKey: payloadData]
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false

        // INUpdateMediaAffinityIntentResponseCode doesn't have .handleInApp,
        // so we use .failureRequiringAppLaunch which delivers the NSUserActivity to the app.
        logger.info("handle: returning failureRequiringAppLaunch for affinity=\(affinityType, privacy: .public)")
        completion(INUpdateMediaAffinityIntentResponse(code: .failureRequiringAppLaunch, userActivity: activity))
    }
}
