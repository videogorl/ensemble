import Foundation

/// Shared resolver for SiriKit, App Shortcuts, Spotlight, and system media donations.
public enum SiriMediaIndexResolver {
    public struct RankedItem: Sendable, Equatable {
        public let item: SiriMediaIndexItem
        public let score: Double

        public init(item: SiriMediaIndexItem, score: Double) {
            self.item = item
            self.score = score
        }
    }

    public static let defaultMinimumMatchScore = 0.6

    public static func loadIndex(
        appGroupIdentifier: String = SiriSharedConstants.appGroupIdentifier,
        filename: String = SiriSharedConstants.indexFilename,
        fileManager: FileManager = .default
    ) -> SiriMediaIndex? {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        return loadIndex(from: containerURL.appendingPathComponent(filename))
    }

    public static func loadIndex(from url: URL) -> SiriMediaIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiriMediaIndex.self, from: data)
    }

    public static func items(
        in index: SiriMediaIndex?,
        kind: SiriMediaKind
    ) -> [SiriMediaIndexItem] {
        index?.items.filter { $0.kind == kind } ?? []
    }

    public static func findItems(
        in index: SiriMediaIndex?,
        kind: SiriMediaKind,
        matching rawQuery: String,
        limit: Int = 10,
        minimumScore: Double = defaultMinimumMatchScore
    ) -> [SiriMediaIndexItem] {
        let ranked = rankCandidates(
            for: rawQuery,
            requestedKinds: [kind],
            index: index,
            minimumScore: minimumScore
        )
        return Array(deduplicateEquivalentItems(ranked.map(\.item)).prefix(limit))
    }

    public static func rankPlaylistCandidates(
        for rawQuery: String,
        index: SiriMediaIndex?,
        minimumScore: Double = 0
    ) -> [RankedItem] {
        rankCandidates(
            for: rawQuery,
            requestedKinds: [.playlist],
            index: index,
            minimumScore: minimumScore
        )
    }

    public static func rankCandidates(
        for rawQuery: String,
        requestedKinds: Set<SiriMediaKind>?,
        index: SiriMediaIndex?,
        artistHint: String? = nil,
        minimumScore: Double = 0
    ) -> [RankedItem] {
        let queryVariants = SiriPhraseNormalizer.queryVariants(for: rawQuery)
        guard !queryVariants.isEmpty, let index else { return [] }

        let normalizedArtistHint = artistHint.map { SiriPhraseNormalizer.basic($0) }

        return index.items
            .compactMap { item -> RankedItem? in
                if let requestedKinds, !requestedKinds.contains(item.kind) {
                    return nil
                }

                let primaryScore = SiriMatchScorer.scoreMatch(
                    queries: queryVariants,
                    candidate: SiriPhraseNormalizer.basic(item.displayName)
                )
                let secondaryScore = SiriMatchScorer.scoreMatch(
                    queries: queryVariants,
                    candidate: SiriPhraseNormalizer.basic(item.secondaryText ?? "")
                ) * 0.35

                var score = max(primaryScore, secondaryScore)
                guard score >= minimumScore, score > 0 else { return nil }

                if let hint = normalizedArtistHint,
                   let secondary = item.secondaryText,
                   !hint.isEmpty {
                    let artistMatch = SiriMatchScorer.scoreMatch(
                        query: hint,
                        candidate: SiriPhraseNormalizer.basic(secondary)
                    )
                    if artistMatch >= 0.7 {
                        score = min(score + 0.15, 1.0)
                    }
                }

                return RankedItem(item: item, score: score)
            }
            .sorted(by: rankSort)
    }

    public static func matchingItem(
        for payload: SiriPlaybackRequestPayload,
        in index: SiriMediaIndex?
    ) -> SiriMediaIndexItem? {
        index?.items.first {
            $0.kind == payload.kind
                && $0.id == payload.entityID
                && sourceMatches(requestSource: payload.sourceCompositeKey, candidateSource: $0.sourceCompositeKey)
        }
    }

    public static func sourceMatches(
        requestSource: String?,
        candidateSource: String?
    ) -> Bool {
        guard let requestSource else { return true }
        guard let candidateSource else { return false }
        if candidateSource == requestSource { return true }
        if requestSource.split(separator: ":").count == 3 {
            return candidateSource.hasPrefix("\(requestSource):")
        }
        return false
    }

    public static func kindInferred(from rawQuery: String) -> SiriMediaKind? {
        let normalized = SiriPhraseNormalizer.strippingLeadingPlaybackCommandPrefix(
            from: SiriPhraseNormalizer.basic(rawQuery)
        )
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
            return .track
        }
        return nil
    }

    public static func deduplicateEquivalentItems(_ items: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        var seenKeys = Set<String>()
        var results: [SiriMediaIndexItem] = []
        results.reserveCapacity(items.count)

        for item in items {
            let displayKey = SiriPhraseNormalizer.normalized(item.displayName)
            let secondaryKey = SiriPhraseNormalizer.normalized(item.secondaryText ?? "")
            let canonicalKey = "\(item.kind.rawValue)|\(displayKey)|\(secondaryKey)"
            if seenKeys.insert(canonicalKey).inserted {
                results.append(item)
            }
        }

        return results
    }

    private static func rankSort(lhs: RankedItem, rhs: RankedItem) -> Bool {
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
