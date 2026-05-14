import EnsembleSiriShared
import Foundation
import Intents
import OSLog

typealias RankedItem = SiriMediaIndexResolver.RankedItem

struct SiriPayloadIdentifier: Codable {
    let schemaVersion: Int
    let kind: SiriMediaKind
    let entityID: String
    let sourceCompositeKey: String?
    let displayName: String?
    let artistHint: String?
    var shuffle: Bool? = nil
}

// MARK: - Shared helpers

enum SiriMatchingHelpers {
    static let appGroupIdentifier = SiriSharedConstants.appGroupIdentifier
    static let indexFilename = SiriSharedConstants.indexFilename

    static func loadIndex() -> SiriMediaIndex? {
        SiriMediaIndexResolver.loadIndex(
            appGroupIdentifier: appGroupIdentifier,
            filename: indexFilename
        )
    }

    static func normalize(_ raw: String) -> String {
        SiriPhraseNormalizer.basic(raw)
    }

    static func scoreMatch(query: String, candidate: String) -> Double {
        SiriMatchScorer.scoreMatch(query: query, candidate: candidate)
    }

    static func scoreMatch(queries: [String], candidate: String) -> Double {
        SiriMatchScorer.scoreMatch(queries: queries, candidate: candidate)
    }

    static func currentTrackMediaItem() -> INMediaItem {
        INMediaItem(
            identifier: "current-track",
            title: "Current Track",
            type: .song,
            artwork: nil
        )
    }

    /// Rank index items matching a playlist query by fuzzy score.
    static func rankPlaylistCandidates(
        for query: String,
        index: SiriMediaIndex
    ) -> [RankedItem] {
        SiriMediaIndexResolver.rankPlaylistCandidates(for: query, index: index)
    }
}

enum SiriPendingIntentBridge {
    static func writePayload<T: Encodable>(
        _ payload: T,
        filename: String,
        logger: Logger,
        context: String
    ) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SiriMatchingHelpers.appGroupIdentifier
        ) else {
            logger.error("\(context, privacy: .public): App Group container unavailable")
            return false
        }

        let fileURL = containerURL.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            logger.info("\(context, privacy: .public): wrote pending payload to \(fileURL.path, privacy: .public)")
            return true
        } catch {
            logger.error("\(context, privacy: .public): failed to write pending payload: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func postDarwinNotification(
        named notificationName: String,
        logger: Logger,
        context: String
    ) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
        logger.info("\(context, privacy: .public): posted Darwin notification")
    }
}
