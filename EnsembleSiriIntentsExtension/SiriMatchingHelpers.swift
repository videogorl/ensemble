import EnsembleSiriShared
import Foundation
import Intents
import OSLog

// MARK: - Shared models for Siri intent handlers

struct SiriMediaIndexSnapshot: Decodable {
    let schemaVersion: Int
    let generatedAt: Date
    let items: [SiriMediaIndexItemSnapshot]
}

struct SiriMediaIndexItemSnapshot: Decodable {
    let kind: String
    let id: String
    let displayName: String
    let sourceCompositeKey: String?
    let secondaryText: String?
    let lastPlayed: Date?
    let playCount: Int?
    let trackCount: Int?
}

struct RankedItem {
    let item: SiriMediaIndexItemSnapshot
    let score: Double
}

struct SiriPayloadIdentifier: Codable {
    let schemaVersion: Int
    let kind: String
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

    static func loadIndex() -> SiriMediaIndexSnapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        let url = containerURL.appendingPathComponent(indexFilename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SiriMediaIndexSnapshot.self, from: data)
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
        index: SiriMediaIndexSnapshot
    ) -> [RankedItem] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return [] }

        return index.items
            .compactMap { item in
                guard item.kind == "playlist" else { return nil }
                let score = scoreMatch(query: normalizedQuery, candidate: normalize(item.displayName))
                guard score > 0 else { return nil }
                return RankedItem(item: item, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.item.trackCount != rhs.item.trackCount {
                    return (lhs.item.trackCount ?? 0) > (rhs.item.trackCount ?? 0)
                }
                return lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName) == .orderedAscending
            }
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
