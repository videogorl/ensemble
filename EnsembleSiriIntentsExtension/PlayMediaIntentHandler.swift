import Intents

final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let indexFilename = "siri-media-index.json"
    private static let activityType = "com.videogorl.ensemble.siri.playmedia"
    private static let payloadUserInfoKey = "siriPlaybackPayload"

    func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        guard let query = queryText(from: intent), !query.isEmpty else {
            completion([.needsValue()])
            return
        }

        guard let index = loadIndex() else {
            completion([.unsupported()])
            return
        }

        let filtered = rankCandidates(
            for: query,
            mediaType: intent.mediaSearch?.mediaType ?? .unknown,
            index: index
        )

        guard let top = filtered.first else {
            completion([.unsupported()])
            return
        }

        if filtered.count == 1 {
            completion([.success(with: makeMediaItem(from: top))])
            return
        }

        let topScore = top.score
        let secondScore = filtered[1].score
        if abs(topScore - secondScore) <= 0.1 {
            let options = Array(filtered.prefix(6)).map { makeMediaItem(from: $0) }
            completion([.disambiguation(with: options)])
            return
        }

        completion([.success(with: makeMediaItem(from: top))])
    }

    func confirm(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard loadIndex() != nil else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }
        completion(INPlayMediaIntentResponse(code: .ready, userActivity: nil))
    }

    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        guard let mediaItem = intent.mediaItems?.first else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        guard let identifier = mediaItem.identifier,
              let payload = decodePayloadIdentifier(identifier),
              let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        let activity = NSUserActivity(activityType: Self.activityType)
        activity.title = "Play in Ensemble"
        activity.userInfo = [Self.payloadUserInfoKey: payloadData]
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false

        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity))
    }

    private func queryText(from intent: INPlayMediaIntent) -> String? {
        if let explicit = intent.mediaItems?.first?.title, !explicit.isEmpty {
            return explicit
        }
        if let searched = intent.mediaSearch?.mediaName, !searched.isEmpty {
            return searched
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
            .compactMap { item -> RankedItem? in
                let score = scoreMatch(query: normalizedQuery, candidate: item.normalizedDisplayName)
                guard score > 0 else { return nil }
                return RankedItem(item: item, score: score)
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                if $0.item.lastPlayed != $1.item.lastPlayed {
                    return ($0.item.lastPlayed ?? .distantPast) > ($1.item.lastPlayed ?? .distantPast)
                }
                if $0.item.trackCount != $1.item.trackCount {
                    return ($0.item.trackCount ?? 0) > ($1.item.trackCount ?? 0)
                }
                return $0.item.displayName.localizedCaseInsensitiveCompare($1.item.displayName) == .orderedAscending
            }
    }

    private func scoreMatch(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) { return 0.8 }
        if candidate.contains(query) { return 0.55 }
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
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "kind": ranked.item.kind,
            "entityID": ranked.item.id,
            "sourceCompositeKey": ranked.item.sourceCompositeKey as Any,
            "displayName": ranked.item.displayName
        ]
        let identifier: String
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
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

    private func decodePayloadIdentifier(_ identifier: String) -> [String: Any]? {
        guard let data = Data(base64Encoded: identifier),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
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
