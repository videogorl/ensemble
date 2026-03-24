import Foundation
import Intents
import os

public final class AddMediaIntentHandler: NSObject, INAddMediaIntentHandling {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let pendingFilename = "siri-pending-addtoplaylist.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingAddToPlaylist"
    private static let disambiguationThreshold = 0.1

    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "AddMediaIntentHandler"
    )

    public override init() {
        super.init()
        os_log(.info, "SIRI_EXT: AddMediaIntentHandler.init()")
    }

    // MARK: - INAddMediaIntentHandling

    public func resolveMediaItems(
        for intent: INAddMediaIntent,
        with completion: @escaping ([INAddMediaMediaItemResolutionResult]) -> Void
    ) {
        // The "media to add" is the current track -- no resolution needed.
        logger.info("resolveMediaItems: returning success for current track")
        let currentTrackItem = INMediaItem(
            identifier: "current-track",
            title: "Current Track",
            type: .song,
            artwork: nil
        )
        completion([.success(with: currentTrackItem)])
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

        logger.info("resolveMediaDestination: query=\(playlistName, privacy: .public)")

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

        logger.info("resolveMediaDestination: matched playlist \(top.item.displayName, privacy: .public)")
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

        logger.info("handle: playlist=\(playlistName, privacy: .public)")

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

        // Write payload to shared App Group file for the main app to pick up
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "playlistRatingKey": match.item.id,
            "sourceCompositeKey": match.item.sourceCompositeKey ?? "",
            "playlistDisplayName": match.item.displayName
        ].compactMapValues { $0 }

        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            logger.error("handle: App Group container unavailable")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let fileURL = containerURL.appendingPathComponent(Self.pendingFilename)

        do {
            let data = try JSONSerialization.data(withJSONObject: payloadDict)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("handle: failed to write pending file: \(error.localizedDescription, privacy: .public)")
            completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        // Post Darwin notification to wake the main app
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.darwinNotificationName as CFString),
            nil, nil, true
        )

        logger.info("handle: wrote pending add-to-playlist file + posted Darwin notification, returning success")
        completion(INAddMediaIntentResponse(code: .success, userActivity: nil))
    }
}
