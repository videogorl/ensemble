import Foundation

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
    static let appGroupIdentifier = "group.com.videogorl.ensemble"
    static let indexFilename = "siri-media-index.json"

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
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func scoreMatch(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.84 }
        if candidate.contains(query) || query.contains(candidate) { return 0.7 }

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

    static func scoreMatch(queries: [String], candidate: String) -> Double {
        queries.reduce(0) { best, query in
            max(best, scoreMatch(query: query, candidate: candidate))
        }
    }

    static func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        let referenceCount = max(queryTokens.count, candidateTokens.count)
        return Double(overlap) / Double(referenceCount)
    }

    static func normalizedEditSimilarity(lhs: String, rhs: String) -> Double {
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
