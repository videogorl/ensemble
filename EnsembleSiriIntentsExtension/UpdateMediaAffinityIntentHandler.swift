import Foundation
import Intents
import os

public final class UpdateMediaAffinityIntentHandler: NSObject, INUpdateMediaAffinityIntentHandling {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let pendingFilename = "siri-pending-affinity.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingAffinity"

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
        // We act on whatever is currently playing -- no resolution needed.
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

        // Write payload to shared App Group file for the main app to pick up
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "affinityType": affinityType
        ]

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            logger.error("handle: App Group container unavailable")
            completion(INUpdateMediaAffinityIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let fileURL = containerURL.appendingPathComponent(Self.pendingFilename)

        do {
            let data = try JSONSerialization.data(withJSONObject: payloadDict)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("handle: failed to write pending file: \(error.localizedDescription, privacy: .public)")
            completion(INUpdateMediaAffinityIntentResponse(code: .failure, userActivity: nil))
            return
        }

        // Post Darwin notification to wake the main app (which is running since music is playing)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotificationName as CFString),
            nil, nil, true
        )

        logger.info("handle: wrote pending affinity file + posted Darwin notification, returning success")
        completion(INUpdateMediaAffinityIntentResponse(code: .success, userActivity: nil))
    }
}
