#if os(iOS)
import AppIntents
import EnsembleCore
import Foundation

@available(iOS 16.0, *)
private enum SiriPhraseSanitizer {
    static let appNameSuffixes = [" ensemble music", " ensemble"]
    static let trailingConnectorWords: Set<String> = ["on", "in", "using", "with"]
    static let leadingMediaTypePrefixes = [
        "the playlist ", "playlist ", "the album ", "album ",
        "the artist ", "artist ", "the song ", "song ",
        "the track ", "track "
    ]

    static func normalized(_ value: String) -> String {
        let base = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^a-zA-Z0-9 ]", with: " ", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var candidate = base
        for suffix in appNameSuffixes where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        candidate = trimTrailingConnectorWords(in: candidate)
        candidate = stripLeadingMediaPrefix(in: candidate)
        return candidate
    }

    private static func trimTrailingConnectorWords(in value: String) -> String {
        var tokens = value.split(separator: " ").map(String.init)
        while let last = tokens.last, trailingConnectorWords.contains(last) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static func stripLeadingMediaPrefix(in value: String) -> String {
        for prefix in leadingMediaTypePrefixes where value.hasPrefix(prefix) {
            let stripped = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !stripped.isEmpty { return stripped }
        }
        return value
    }
}

@available(iOS 16.0, *)
private enum SiriIndexLookup {
    private static let appGroupIdentifier = "group.com.videogorl.ensemble"
    private static let filename = "siri-media-index.json"

    static func fetchItems(kind: SiriMediaKind) -> [SiriMediaIndexItem] {
        guard let index = loadIndex() else { return [] }
        return index.items.filter { $0.kind == kind }
    }

    static func findItems(kind: SiriMediaKind, matching rawQuery: String, limit: Int = 10) -> [SiriMediaIndexItem] {
        let query = SiriPhraseSanitizer.normalized(rawQuery)
        guard !query.isEmpty else { return [] }

        let scored: [(item: SiriMediaIndexItem, score: Double)] = fetchItems(kind: kind)
            .compactMap { item in
                let score = matchScore(query: query, candidate: SiriPhraseSanitizer.normalized(item.displayName))
                guard score > 0 else { return nil }
                return (item: item, score: score)
            }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsName = lhs.item.displayName
            let rhsName = rhs.item.displayName
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        return Array(sorted.prefix(limit).map { $0.item })
    }

    private static func loadIndex() -> SiriMediaIndex? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }

        let url = containerURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SiriMediaIndex.self, from: data)
    }

    private static func matchScore(query: String, candidate: String) -> Double {
        guard !query.isEmpty, !candidate.isEmpty else { return 0 }
        if query == candidate { return 1.0 }
        if candidate.hasPrefix(query) || query.hasPrefix(candidate) { return 0.85 }
        if candidate.contains(query) || query.contains(candidate) { return 0.7 }

        let overlap = tokenOverlapScore(query: query, candidate: candidate)
        if overlap >= 0.67 {
            return 0.45 + overlap * 0.35
        }
        return 0
    }

    private static func tokenOverlapScore(query: String, candidate: String) -> Double {
        let queryTokens = Set(query.split(separator: " ").map(String.init))
        let candidateTokens = Set(candidate.split(separator: " ").map(String.init))
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return 0 }

        let overlap = queryTokens.intersection(candidateTokens).count
        let referenceCount = max(queryTokens.count, candidateTokens.count)
        return Double(overlap) / Double(referenceCount)
    }
}

@available(iOS 16.0, *)
private func makeCompositeEntityID(ratingKey: String, sourceCompositeKey: String?) -> String {
    let source = sourceCompositeKey ?? ""
    return "\(ratingKey)||\(source)"
}

@available(iOS 16.0, *)
private func parseCompositeEntityID(_ id: String) -> (ratingKey: String, sourceCompositeKey: String?) {
    let components = id.components(separatedBy: "||")
    guard let ratingKey = components.first else {
        return (id, nil)
    }
    let source = components.count > 1 ? components[1] : ""
    return (ratingKey, source.isEmpty ? nil : source)
}

@available(iOS 16.0, *)
struct EnsembleAlbumEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Album")
    static var defaultQuery = EnsembleAlbumEntityQuery()

    let id: String
    let ratingKey: String
    let title: String
    let sourceCompositeKey: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

@available(iOS 16.0, *)
struct EnsembleAlbumEntityQuery: EntityStringQuery {
    func entities(for identifiers: [EnsembleAlbumEntity.ID]) async throws -> [EnsembleAlbumEntity] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }

        return SiriIndexLookup.fetchItems(kind: .album)
            .map { item in
                EnsembleAlbumEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnsembleAlbumEntity] {
        SiriIndexLookup.findItems(kind: .album, matching: string).map { item in
            EnsembleAlbumEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
    }

    func suggestedEntities() async throws -> [EnsembleAlbumEntity] {
        SiriIndexLookup.fetchItems(kind: .album)
            .prefix(20)
            .map { item in
                EnsembleAlbumEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
    }
}

@available(iOS 16.0, *)
struct EnsemblePlaylistEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playlist")
    static var defaultQuery = EnsemblePlaylistEntityQuery()

    let id: String
    let ratingKey: String
    let title: String
    let sourceCompositeKey: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

@available(iOS 16.0, *)
struct EnsemblePlaylistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [EnsemblePlaylistEntity.ID]) async throws -> [EnsemblePlaylistEntity] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }

        return SiriIndexLookup.fetchItems(kind: .playlist)
            .map { item in
                EnsemblePlaylistEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnsemblePlaylistEntity] {
        SiriIndexLookup.findItems(kind: .playlist, matching: string).map { item in
            EnsemblePlaylistEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
    }

    func suggestedEntities() async throws -> [EnsemblePlaylistEntity] {
        SiriIndexLookup.fetchItems(kind: .playlist)
            .prefix(20)
            .map { item in
                EnsemblePlaylistEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
    }
}

@available(iOS 16.0, *)
private struct SiriShortcutPlaybackExecutor {
    @MainActor
    static func play(kind: SiriMediaKind, ratingKey: String, sourceCompositeKey: String?, displayName: String) async throws {
        let payload = SiriPlaybackRequestPayload(
            kind: kind,
            entityID: ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName
        )
        try await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
    }
}

/// AppIntent fallback for album playback when SiriKit media-domain routing misses the app.
@available(iOS 16.0, *)
struct PlayEnsembleAlbumIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Album in Ensemble"
    static var description = IntentDescription("Plays a specific album from your Ensemble library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Album")
    var album: EnsembleAlbumEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsedID = parseCompositeEntityID(album.id)
        try await SiriShortcutPlaybackExecutor.play(
            kind: .album,
            ratingKey: parsedID.ratingKey,
            sourceCompositeKey: parsedID.sourceCompositeKey,
            displayName: album.title
        )
        return .result(dialog: IntentDialog("Playing \(album.title) in Ensemble."))
    }
}

/// AppIntent fallback for playlist playback when SiriKit media-domain routing misses the app.
@available(iOS 16.0, *)
struct PlayEnsemblePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Playlist in Ensemble"
    static var description = IntentDescription("Plays a specific playlist from your Ensemble library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let parsedID = parseCompositeEntityID(playlist.id)
        try await SiriShortcutPlaybackExecutor.play(
            kind: .playlist,
            ratingKey: parsedID.ratingKey,
            sourceCompositeKey: parsedID.sourceCompositeKey,
            displayName: playlist.title
        )
        return .result(dialog: IntentDialog("Playing \(playlist.title) in Ensemble."))
    }
}

/// Registers explicit Siri phrases so Ensemble can be invoked even when media-domain parsing fails.
@available(iOS 16.0, *)
struct EnsembleAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayEnsembleAlbumIntent(),
            phrases: [
                "Play album \(\.$album) on \(.applicationName)",
                "In \(.applicationName), play album \(\.$album)",
                "Ask \(.applicationName) to play album \(\.$album)"
            ],
            shortTitle: "Play Album",
            systemImageName: "opticaldisc"
        )

        AppShortcut(
            intent: PlayEnsemblePlaylistIntent(),
            phrases: [
                "Play playlist \(\.$playlist) on \(.applicationName)",
                "In \(.applicationName), play playlist \(\.$playlist)",
                "Ask \(.applicationName) to play playlist \(\.$playlist)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
#endif
