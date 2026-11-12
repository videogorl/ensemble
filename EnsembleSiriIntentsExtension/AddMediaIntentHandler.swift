import EnsembleSiriShared
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

        // No presentation yet: nothing can be shown to be visible, so the name goes to the app as spoken.
        guard let offered = SiriMatchingHelpers.offeredPlaylists(in: index) else {
            logger.info("resolveMediaDestination: no playlist presentation; deferring the name to the app")
            completion(.success(with: INMediaDestination.playlist(playlistName)))
            return
        }

        // A name this resolver offered earlier (server-qualified when two playlists share a title) is already chosen.
        if let chosen = SiriPlaylistRows.destination(named: playlistName, among: offered) {
            completion(.success(with: INMediaDestination.playlist(SiriPlaylistRows.destinationName(for: chosen, among: offered))))
            return
        }

        let ranked = Self.rankOffered(playlistName, offered: offered, index: index)
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
                    INMediaDestination.playlist(SiriPlaylistRows.destinationName(for: ranked.item, among: offered))
                }
                completion(.disambiguation(with: options))
                return
            }
        }

        logger.info("resolveMediaDestination: matched playlist")
        completion(.success(with: INMediaDestination.playlist(SiriPlaylistRows.destinationName(for: top.item, among: offered))))
    }

    /// Playlist candidates for a spoken name, limited to the playlists the app offers.
    private static func rankOffered(_ name: String, offered: [SiriMediaIndexItem], index: SiriMediaIndex) -> [RankedItem] {
        let shown = Set(offered.map(\.reference.sourceScopedIdentifier))
        return SiriMediaIndexResolver.rankPlaylistCandidates(for: name, index: index)
            .filter { shown.contains($0.item.reference.sourceScopedIdentifier) }
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

        // The playlist the chosen name stands for; with no presentation, a name-only request the app resolves itself.
        let payload: PendingAddToPlaylistPayload
        if let offered = SiriMatchingHelpers.offeredPlaylists(in: index) {
            guard let match = SiriPlaylistRows.destination(named: playlistName, among: offered)
                    ?? Self.rankOffered(playlistName, offered: offered, index: index).first?.item else {
                logger.error("handle: no matching playlist found")
                completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }
            payload = PendingAddToPlaylistPayload(
                playlistRatingKey: match.id,
                sourceCompositeKey: match.sourceCompositeKey ?? "",
                playlistDisplayName: match.displayName
            )
        } else {
            payload = PendingAddToPlaylistPayload(playlistRatingKey: "", sourceCompositeKey: "", playlistDisplayName: playlistName)
        }
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
