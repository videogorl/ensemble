import Foundation

/// Shared App Group and index filenames used by the app, Core, and Siri extension.
public enum SiriSharedConstants {
    public static let appGroupIdentifier = "group.com.videogorl.ensemble"
    public static let indexFilename = "siri-media-index.json"
}

/// Normalizes spoken Siri phrases and indexed media titles into comparable strings.
public enum SiriPhraseNormalizer {
    public static let appNameSuffixes = [" ensemble music", " ensemble"]
    public static let trailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    public static let leadingMediaTypePrefixes = [
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

    /// Applies only case, diacritic, punctuation, and whitespace normalization.
    public static func basic(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    /// Optional-friendly basic normalization for Core repository fields.
    public static func basic(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return basic(raw)
    }

    /// Normalizes a user query for broad Siri lookup by removing app and media-type words.
    public static func normalized(_ raw: String) -> String {
        var candidate = basic(raw)
        for suffix in appNameSuffixes where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        candidate = trimTrailingConnectorWords(in: candidate)
        candidate = strippingLeadingMediaTypePrefix(from: candidate)
        return candidate
    }

    /// Optional-friendly broad normalization for Core repository fields.
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return normalized(raw)
    }

    /// Returns all useful query forms for matching Siri requests against stored media names.
    public static func queryVariants(for raw: String?) -> [String] {
        guard let raw else { return [] }
        let base = basic(raw)
        guard !base.isEmpty else { return [] }

        var variants = Set<String>()
        variants.insert(base)
        variants.insert(strippingLeadingMediaTypePrefix(from: base))

        let trimmedBase = trimTrailingConnectorWords(in: base)
        variants.insert(trimmedBase)
        variants.insert(strippingLeadingMediaTypePrefix(from: trimmedBase))

        for suffix in appNameSuffixes where base.hasSuffix(suffix) {
            let trimmed = base.dropLast(suffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let phraseWithoutConnector = trimTrailingConnectorWords(in: trimmed)
            variants.insert(phraseWithoutConnector)
            variants.insert(strippingLeadingMediaTypePrefix(from: phraseWithoutConnector))
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

    /// Returns the shortest usable query variant, which is generally best for UI labels.
    public static func bestQueryVariant(for raw: String?) -> String? {
        queryVariants(for: raw).first
    }

    public static func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, trailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    public static func strippingLeadingMediaTypePrefix(from value: String) -> String {
        for prefix in leadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty {
                return stripped
            }
        }
        return value
    }
}

/// Scores normalized Siri queries against normalized media names.
public enum SiriMatchScorer {
    public static let prefixScore = 0.84
    public static let containmentScore = 0.7

    /// Scores one normalized query against one normalized candidate.
    public static func scoreMatch(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if candidate == query { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return prefixScore }
        if candidate.contains(query) || query.contains(candidate) { return containmentScore }

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

    /// Scores multiple normalized query variants against one normalized candidate.
    public static func scoreMatch(queries: [String], candidate: String) -> Double {
        queries.reduce(0) { best, query in
            max(best, scoreMatch(query: query, candidate: candidate))
        }
    }

    /// Scores overlap based on shared query/candidate tokens.
    public static func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        let referenceCount = max(queryTokens.count, candidateTokens.count)
        return Double(overlap) / Double(referenceCount)
    }

    /// Uses edit-distance similarity so Siri transcript drift can still map to indexed entities.
    public static func normalizedEditSimilarity(lhs: String, rhs: String) -> Double {
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
