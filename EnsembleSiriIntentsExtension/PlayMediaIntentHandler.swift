import Foundation
import Intents
import os

public final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let indexFilename = "siri-media-index.json"
    private static let activityType = "com.videogorl.ensemble.siri.playmedia"
    private static let payloadUserInfoKey = "siriPlaybackPayload"
    private static let currentPayloadSchemaVersion = 1
    private static let disambiguationThreshold = 0.1
    private static let payloadResolutionThreshold = 0.66
    private static let appNameSuffixes = [" ensemble music", " ensemble"]
    private static let trailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    private static let leadingMediaTypePrefixes = [
        "the playlist ",
        "playlist ",
        "the album ",
        "album ",
        "the artist ",
        "artist ",
        "the song ",
        "song ",
        "the track ",
        "track "
    ]
    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "PlayMediaIntentHandler"
    )

    public override init() {
        super.init()
        os_log(.info, "SIRI_EXT: PlayMediaIntentHandler.init() called")
    }

    public func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        os_log(.info, "SIRI_EXT: resolveMediaItems ENTRY")
        logger.info("resolveMediaItems: ENTRY - received intent")

        // Siri may re-enter resolution after the user taps a disambiguation option.
        // If we already have a valid payload identifier, keep it stable and avoid loops.
        if let selected = intent.mediaItems?.first,
           let identifier = selected.identifier,
           let payload = decodePayloadIdentifier(identifier),
           payload.schemaVersion == Self.currentPayloadSchemaVersion {
            logger.debug("resolveMediaItems: using preselected media item to avoid re-disambiguation")
            completion([.success(with: selected)])
            return
        }

        guard let query = queryText(from: intent), !query.isEmpty else {
            logger.info("resolveMediaItems: missing query; requesting value from Siri")
            completion([.needsValue()])
            return
        }
        let normalizedQuery = bestQueryVariant(from: query) ?? query

        let requestedMediaType = resolvedMediaType(from: intent, query: query)
        logger.info(
            "resolveMediaItems: query=\(normalizedQuery, privacy: .public), mediaType=\(requestedMediaType.rawValue, privacy: .public)"
        )

        guard let index = loadIndex(), !index.items.isEmpty else {
            logger.debug("resolveMediaItems: index unavailable or empty; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: normalizedQuery,
                mediaType: requestedMediaType
            )
            completion([.success(with: fallback)])
            return
        }

        let ranked = rankCandidates(
            for: normalizedQuery,
            mediaType: requestedMediaType,
            index: index
        )
        guard let top = ranked.first else {
            logger.debug("resolveMediaItems: no ranked match; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: normalizedQuery,
                mediaType: requestedMediaType
            )
            completion([.success(with: fallback)])
            return
        }

        let allowDisambiguation = requestedMediaType == .unknown
        if allowDisambiguation && ranked.count > 1 {
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

    public func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let requestedMediaType = resolvedMediaType(from: intent, query: queryText(from: intent) ?? "")
        os_log(.info, "SIRI_EXT: confirm ENTRY mediaType=%{public}ld", requestedMediaType.rawValue)
        logger.debug("confirm: mediaType=\(requestedMediaType.rawValue, privacy: .public)")

        // Return ready so Siri can continue into handle(intent:), which preserves
        // media-domain routing semantics better than forcing continueInApp.
        guard let payload = payloadIdentifier(from: intent, mediaType: requestedMediaType),
              playbackUserActivity(for: payload) != nil else {
            logger.debug("confirm: no payload available; returning ready")
            os_log(.info, "SIRI_EXT: confirm returning ready (no payload)")
            completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
            return
        }

        logger.debug("confirm: returning ready for payload kind=\(payload.kind, privacy: .public)")
        os_log(.info, "SIRI_EXT: confirm returning ready kind=%{public}@", payload.kind)
        completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    public func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let requestedMediaType = resolvedMediaType(from: intent, query: queryText(from: intent) ?? "")
        os_log(.info, "SIRI_EXT: handle ENTRY mediaType=%{public}ld", requestedMediaType.rawValue)
        logger.debug("handle: mediaType=\(requestedMediaType.rawValue, privacy: .public)")

        guard let payload = payloadIdentifier(from: intent, mediaType: requestedMediaType) else {
            logger.error("handle: missing identifier and query; returning failureUnknownMediaType")
            os_log(.info, "SIRI_EXT: handle returning failureUnknownMediaType")
            completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
            return
        }

        // Do not fail in the extension based on index trackCount metadata.
        // Index data can be stale or partial, so playback viability must be
        // validated in-app by SiriPlaybackCoordinator against live CoreData.

        guard let activity = playbackUserActivity(for: payload) else {
            logger.error("handle: failed to construct playback user activity")
            os_log(.info, "SIRI_EXT: handle returning failure (no activity)")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        logger.debug("handle: returning handleInApp for payload kind=\(payload.kind, privacy: .public)")
        os_log(.info, "SIRI_EXT: handle returning handleInApp kind=%{public}@", payload.kind)
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity))
    }

    private func payloadIdentifier(
        from intent: INPlayMediaIntent,
        mediaType: INMediaItemType
    ) -> SiriPayloadIdentifier? {
        if let identifier = (intent.mediaItems?.first?.identifier ?? intent.mediaContainer?.identifier),
           let decodedPayload = decodePayloadIdentifier(identifier),
           decodedPayload.schemaVersion == Self.currentPayloadSchemaVersion {
            logger.debug("payloadIdentifier: using decoded payload identifier")
            return decodedPayload
        }

        guard let query = queryText(from: intent), !query.isEmpty else {
            return nil
        }
        let fallbackQuery = bestQueryVariant(from: query) ?? query

        if let index = loadIndex(),
           let top = rankCandidates(
                for: fallbackQuery,
                mediaType: mediaType,
                index: index
           ).first,
           top.score >= Self.payloadResolutionThreshold {
            logger.debug("payloadIdentifier: resolved fallback payload from index top candidate")
            return SiriPayloadIdentifier(
                schemaVersion: Self.currentPayloadSchemaVersion,
                kind: top.item.kind,
                entityID: top.item.id,
                sourceCompositeKey: top.item.sourceCompositeKey,
                displayName: top.item.displayName
            )
        }

        logger.debug("payloadIdentifier: building fallback payload from query=\(fallbackQuery, privacy: .public)")
        return SiriPayloadIdentifier(
            schemaVersion: Self.currentPayloadSchemaVersion,
            kind: primaryKindFor(mediaType: mediaType, query: fallbackQuery),
            entityID: fallbackQuery,
            sourceCompositeKey: nil,
            displayName: fallbackQuery
        )
    }

    private func playbackUserActivity(for payload: SiriPayloadIdentifier) -> NSUserActivity? {
        guard let payloadData = try? JSONEncoder().encode(payload) else {
            return nil
        }

        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = "Play in Ensemble"
        activity.userInfo = [Self.payloadUserInfoKey: payloadData]
        // HomePod requests may need cross-device handoff semantics to wake the iPhone host app.
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        return activity
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
        let queryVariants = normalizedQueryVariants(for: query)
        let kinds = kindsFor(mediaType: mediaType)

        return index.items
            .compactMap { item in
                // If specific kind requested, filter for it.
                // If unknown, allow searching across all kinds.
                if mediaType != .unknown && !kinds.contains(item.kind) {
                    return nil
                }

                let primaryScore = scoreMatch(queries: queryVariants, candidate: normalize(item.displayName))
                let secondaryScore = scoreMatch(queries: queryVariants, candidate: normalize(item.secondaryText ?? "")) * 0.35
                let score = max(primaryScore, secondaryScore)
                guard score > 0 else { return nil }
                return RankedItem(item: item, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                
                // Tie-breaker: prefer the kind that matches the requested media type
                if mediaType != .unknown {
                    let lhsMatchesKind = kinds.contains(lhs.item.kind)
                    let rhsMatchesKind = kinds.contains(rhs.item.kind)
                    if lhsMatchesKind != rhsMatchesKind {
                        return lhsMatchesKind
                    }
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

    private func scoreMatch(queries: [String], candidate: String) -> Double {
        queries.reduce(0) { best, query in
            max(best, scoreMatch(query: query, candidate: candidate))
        }
    }

    private func scoreMatch(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 } // exact normalized
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.84 } // prefix on either side
        if candidate.contains(query) || query.contains(candidate) { return 0.7 } // containment on either side

        var score = 0.0
        let overlap = tokenOverlapScore(query: query, candidate: candidate)
        if overlap >= 0.67 {
            score = max(score, 0.45 + overlap * 0.35)
        }

        let fuzzySimilarity = normalizedEditSimilarity(lhs: query, rhs: candidate)
        if fuzzySimilarity >= 0.66 {
            score = max(score, 0.35 + fuzzySimilarity * 0.4)
        }

        return score
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
        let fallbackKind = primaryKindFor(mediaType: mediaType, query: query)
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

    private func primaryKindFor(mediaType: INMediaItemType, query: String? = nil) -> String {
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
            if let query {
                switch inferMediaType(from: query) {
                case .album:
                    return "album"
                case .artist:
                    return "artist"
                case .playlist:
                    return "playlist"
                case .song:
                    return "track"
                default:
                    break
                }
            }
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

        // Return unknown if no specific type can be determined.
        // This allows rankCandidates to search across all kinds.
        return .unknown
    }

    private func resolvedMediaType(from intent: INPlayMediaIntent, query: String) -> INMediaItemType {
        let explicitType = mediaType(from: intent)
        if explicitType != .unknown {
            return explicitType
        }
        return inferMediaType(from: query)
    }

    private func inferMediaType(from query: String) -> INMediaItemType {
        let normalized = normalize(query)
        if normalized.hasPrefix("the playlist ") || normalized.hasPrefix("playlist ") {
            return .playlist
        }
        if normalized.hasPrefix("the album ") || normalized.hasPrefix("album ") {
            return .album
        }
        if normalized.hasPrefix("the artist ") || normalized.hasPrefix("artist ") {
            return .artist
        }
        if normalized.hasPrefix("the song ")
            || normalized.hasPrefix("song ")
            || normalized.hasPrefix("the track ")
            || normalized.hasPrefix("track ") {
            return .song
        }
        return .unknown
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

    private func normalizedQueryVariants(for raw: String) -> [String] {
        let base = normalize(raw)
        guard !base.isEmpty else { return [] }

        var variants = Set<String>()
        variants.insert(base)
        variants.insert(strippingLeadingMediaTypePrefix(from: base))
        let trimmedBase = trimTrailingConnectorWords(in: base)
        variants.insert(trimmedBase)
        variants.insert(strippingLeadingMediaTypePrefix(from: trimmedBase))

        for suffix in Self.appNameSuffixes where base.hasSuffix(suffix) {
            let trimmed = base.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            variants.insert(trimTrailingConnectorWords(in: trimmed))
            variants.insert(
                strippingLeadingMediaTypePrefix(
                    from: trimTrailingConnectorWords(in: trimmed)
                )
            )
        }

        return variants
            .filter { !$0.isEmpty }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count
                }
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    private func bestQueryVariant(from raw: String) -> String? {
        normalizedQueryVariants(for: raw).first
    }

    private func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, Self.trailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private func strippingLeadingMediaTypePrefix(from value: String) -> String {
        for prefix in Self.leadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return value
    }

    /// Scores overlap based on shared query/candidate tokens.
    private func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        let referenceCount = max(queryTokens.count, candidateTokens.count)
        return Double(overlap) / Double(referenceCount)
    }

    /// Uses edit-distance similarity so Siri transcript drift can still map to indexed entities.
    private func normalizedEditSimilarity(lhs: String, rhs: String) -> Double {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        guard !lhsChars.isEmpty, !rhsChars.isEmpty else { return 0 }

        var previous = Array(0...rhsChars.count)
        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhsChars.count + 1)

            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsChar == rhsChar ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }

            previous = current
        }

        let distance = previous.last ?? max(lhsChars.count, rhsChars.count)
        let normalizer = max(lhsChars.count, rhsChars.count)
        return 1 - (Double(distance) / Double(normalizer))
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
    let sourceCompositeKey: String?
    let secondaryText: String?
    let lastPlayed: Date?
    let playCount: Int?
    let trackCount: Int?
}
