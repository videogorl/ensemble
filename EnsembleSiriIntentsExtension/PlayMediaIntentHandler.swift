import Foundation
import Intents
import os

final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let indexFilename = "siri-media-index.json"
    private static let activityType = "com.videogorl.ensemble.siri.playmedia"
    private static let payloadUserInfoKey = "siriPlaybackPayload"
    private static let currentPayloadSchemaVersion = 1
    private static let disambiguationThreshold = 0.1
    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "PlayMediaIntentHandler"
    )

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let query = queryText(from: intent), !query.isEmpty else {
            logger.debug("resolveMediaItems: missing query; requesting value from Siri")
            completion([.needsValue()])
            return
        }

        let requestedMediaType = mediaType(from: intent)
        logger.debug(
            "resolveMediaItems: query=\(query, privacy: .public), mediaType=\(requestedMediaType.rawValue, privacy: .public)"
        )

        guard let index = loadIndex(), !index.items.isEmpty else {
            logger.debug("resolveMediaItems: index unavailable or empty; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: query,
                mediaType: requestedMediaType
            )
            completion([.success(with: fallback)])
            return
        }

        let ranked = rankCandidates(
            for: query,
            mediaType: requestedMediaType,
            index: index
        )
        guard let top = ranked.first else {
            logger.debug("resolveMediaItems: no ranked match; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: query,
                mediaType: requestedMediaType
            )
            completion([.success(with: fallback)])
            return
        }

        if ranked.count > 1 {
            let second = ranked[1]
            if abs(top.score - second.score) <= Self.disambiguationThreshold {
                logger.debug("resolveMediaItems: returning disambiguation with \(ranked.count, privacy: .public) options")
                let options = Array(ranked.prefix(6)).map(makeMediaItem(from:))
                completion([.disambiguation(with: options)])
                return
            }
        }

        logger.debug("resolveMediaItems: selected top candidate \(top.item.displayName, privacy: .public)")
        completion([.success(with: makeMediaItem(from: top))])
    }

    func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        logger.debug("confirm: returning ready")
        completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let requestedMediaType = mediaType(from: intent)
        logger.debug("handle: mediaType=\(requestedMediaType.rawValue, privacy: .public)")

        let payload: SiriPayloadIdentifier
        if let identifier = (intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier),
           let decodedPayload = decodePayloadIdentifier(identifier),
           decodedPayload.schemaVersion == Self.currentPayloadSchemaVersion {
            logger.debug("handle: using decoded payload identifier")
            payload = decodedPayload
        } else if let query = queryText(from: intent), !query.isEmpty {
            logger.debug("handle: building fallback payload from query=\(query, privacy: .public)")
            payload = SiriPayloadIdentifier(
                schemaVersion: Self.currentPayloadSchemaVersion,
                kind: primaryKindFor(mediaType: requestedMediaType),
                entityID: query,
                sourceCompositeKey: nil,
                displayName: query
            )
        } else {
            logger.error("handle: missing identifier and query; returning failureUnknownMediaType")
            completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
            return
        }

        if let index = loadIndex(), !index.items.isEmpty {
            if let matchedItem = matchingItem(for: payload, in: index),
               requiresPlayableTracks(kind: payload.kind),
               let trackCount = matchedItem.trackCount,
               trackCount <= 0 {
                logger.error("handle: matched container has no playable tracks")
                completion(INPlayMediaIntentResponse(code: .failureNoUnplayedContent, userActivity: nil))
                return
            }
        }

        guard let payloadData = try? JSONEncoder().encode(payload) else {
            logger.error("handle: failed to encode payload")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = "Play in Ensemble"
        activity.userInfo = [Self.payloadUserInfoKey: payloadData]
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        logger.debug("handle: returning handleInApp for payload kind=\(payload.kind, privacy: .public)")
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity))
    }

    private func queryText(from intent: INPlayMediaIntent) -> String? {
        if let explicit = intent.mediaItems?.first?.title, !explicit.isEmpty {
            return explicit
        }
        if let containerTitle = intent.mediaContainer?.title, !containerTitle.isEmpty {
            return containerTitle
        }
        if let mediaSearch = intent.mediaSearch {
            if let searched = mediaSearch.mediaName, !searched.isEmpty {
                return searched
            }
            if let artistName = mediaSearch.artistName, !artistName.isEmpty {
                return artistName
            }
            if let albumName = mediaSearch.albumName, !albumName.isEmpty {
                return albumName
            }
            if let genreName = mediaSearch.genreNames?.first, !genreName.isEmpty {
                return genreName
            }
            if let moodName = mediaSearch.moodNames?.first, !moodName.isEmpty {
                return moodName
            }
        }
        return nil
    }

    private func rankCandidates(
        for query: String,
        mediaType: INMediaItemType,
        index: SiriMediaIndexSnapshot
    ) -> [RankedItem] {
        let normalizedQuery = normalize(query)
        let kinds = kindsFor(mediaType: mediaType)

        return index.items
            .filter { kinds.contains($0.kind) }
            .compactMap { item in
                let score = scoreMatch(query: normalizedQuery, candidate: item.normalizedDisplayName)
                guard score > 0 else { return nil }
                return RankedItem(item: item, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                if lhs.item.lastPlayed != rhs.item.lastPlayed {
                    return (lhs.item.lastPlayed ?? .distantPast) > (rhs.item.lastPlayed ?? .distantPast)
                }
                if lhs.item.playCount != rhs.item.playCount {
                    return (lhs.item.playCount ?? 0) > (rhs.item.playCount ?? 0)
                }
                if lhs.item.trackCount != rhs.item.trackCount {
                    return (lhs.item.trackCount ?? 0) > (rhs.item.trackCount ?? 0)
                }
                let nameCompare = lhs.item.displayName.localizedCaseInsensitiveCompare(rhs.item.displayName)
                if nameCompare != .orderedSame {
                    return nameCompare == .orderedAscending
                }
                return lhs.item.id.localizedCaseInsensitiveCompare(rhs.item.id) == .orderedAscending
            }
    }

    private func scoreMatch(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }         // exact normalized
        if candidate.hasPrefix(query) { return 0.8 } // prefix
        if candidate.contains(query) { return 0.55 } // contains
        return 0
    }

    private func kindsFor(mediaType: INMediaItemType) -> Set<String> {
        switch mediaType {
        case .song:
            return ["track"]
        case .album:
            return ["album"]
        case .artist:
            return ["artist"]
        case .playlist:
            return ["playlist"]
        default:
            return ["track", "album", "artist", "playlist"]
        }
    }

    private func makeMediaItem(from ranked: RankedItem) -> INMediaItem {
        let payload = SiriPayloadIdentifier(
            schemaVersion: Self.currentPayloadSchemaVersion,
            kind: ranked.item.kind,
            entityID: ranked.item.id,
            sourceCompositeKey: ranked.item.sourceCompositeKey,
            displayName: ranked.item.displayName
        )

        let identifier: String
        if let data = try? JSONEncoder().encode(payload) {
            identifier = data.base64EncodedString()
        } else {
            identifier = ""
        }

        return INMediaItem(
            identifier: identifier,
            title: ranked.item.displayName,
            type: mediaTypeFor(kind: ranked.item.kind),
            artwork: nil
        )
    }

    private func makeFallbackMediaItem(query: String, mediaType: INMediaItemType) -> INMediaItem {
        let fallbackKind = primaryKindFor(mediaType: mediaType)
        let payload = SiriPayloadIdentifier(
            schemaVersion: Self.currentPayloadSchemaVersion,
            kind: fallbackKind,
            entityID: query,
            sourceCompositeKey: nil,
            displayName: query
        )

        let identifier: String
        if let data = try? JSONEncoder().encode(payload) {
            identifier = data.base64EncodedString()
        } else {
            identifier = ""
        }

        return INMediaItem(
            identifier: identifier,
            title: query,
            type: mediaType == .unknown ? mediaTypeFor(kind: fallbackKind) : mediaType,
            artwork: nil
        )
    }

    private func decodePayloadIdentifier(_ identifier: String) -> SiriPayloadIdentifier? {
        guard let data = Data(base64Encoded: identifier) else { return nil }
        return try? JSONDecoder().decode(SiriPayloadIdentifier.self, from: data)
    }

    private func matchingItem(for payload: SiriPayloadIdentifier, in index: SiriMediaIndexSnapshot) -> SiriMediaIndexItemSnapshot? {
        index.items.first {
            $0.kind == payload.kind &&
            $0.id == payload.entityID &&
            sourceMatches(requestSource: payload.sourceCompositeKey, candidateSource: $0.sourceCompositeKey)
        }
    }

    private func requiresPlayableTracks(kind: String) -> Bool {
        kind == "album" || kind == "artist" || kind == "playlist"
    }

    private func sourceMatches(requestSource: String?, candidateSource: String?) -> Bool {
        guard let requestSource else { return true }
        guard let candidateSource else { return false }
        if candidateSource == requestSource { return true }
        if requestSource.split(separator: ":").count == 3 {
            return candidateSource.hasPrefix("\(requestSource):")
        }
        return false
    }

    private func mediaTypeFor(kind: String) -> INMediaItemType {
        switch kind {
        case "track":
            return .song
        case "album":
            return .album
        case "artist":
            return .artist
        case "playlist":
            return .playlist
        default:
            return .unknown
        }
    }

    private func primaryKindFor(mediaType: INMediaItemType) -> String {
        switch mediaType {
        case .song:
            return "track"
        case .album:
            return "album"
        case .artist:
            return "artist"
        case .playlist:
            return "playlist"
        default:
            return "track"
        }
    }

    private func mediaType(from intent: INPlayMediaIntent) -> INMediaItemType {
        let searchedType = intent.mediaSearch?.mediaType ?? .unknown
        if searchedType != .unknown {
            return searchedType
        }

        let containerType = intent.mediaContainer?.type ?? .unknown
        if containerType != .unknown {
            return containerType
        }

        let firstMediaItemType = intent.mediaItems?.first?.type ?? .unknown
        if firstMediaItemType != .unknown {
            return firstMediaItemType
        }

        if let mediaSearch = intent.mediaSearch {
            if let artistName = mediaSearch.artistName, !artistName.isEmpty {
                return .artist
            }
            if let albumName = mediaSearch.albumName, !albumName.isEmpty {
                return .album
            }
        }

        // Default unknown requests to songs so Siri always receives a concrete type.
        return .song
    }

    private func loadIndex() -> SiriMediaIndexSnapshot? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }
        let url = containerURL.appendingPathComponent(Self.indexFilename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SiriMediaIndexSnapshot.self, from: data)
    }

    private func normalize(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct RankedItem {
    let item: SiriMediaIndexItemSnapshot
    let score: Double
}

private struct SiriPayloadIdentifier: Codable {
    let schemaVersion: Int
    let kind: String
    let entityID: String
    let sourceCompositeKey: String?
    let displayName: String?
}

private struct SiriMediaIndexSnapshot: Decodable {
    let schemaVersion: Int
    let generatedAt: Date
    let items: [SiriMediaIndexItemSnapshot]
}

private struct SiriMediaIndexItemSnapshot: Decodable {
    let kind: String
    let id: String
    let displayName: String
    let normalizedDisplayName: String
    let sourceCompositeKey: String?
    let secondaryText: String?
    let lastPlayed: Date?
    let playCount: Int?
    let trackCount: Int?
}
