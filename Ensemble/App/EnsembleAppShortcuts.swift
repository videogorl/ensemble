#if os(iOS)
import AppIntents
import EnsembleCore
import EnsembleSiriShared
import Foundation
import OSLog

@available(iOS 16.0, *)
private enum SiriAppShortcutLogger {
    static let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-appshortcuts",
        category: "AppShortcuts"
    )
}

@available(iOS 16.0, *)
private enum SiriIndexLookup {
    private static let appGroupIdentifier = SiriSharedConstants.appGroupIdentifier
    private static let filename = SiriSharedConstants.indexFilename
    private static let minimumMatchScore = 0.6

    static func fetchItems(kind: SiriMediaKind) -> [SiriMediaIndexItem] {
        guard let index = loadIndex() else { return [] }
        return index.items.filter { $0.kind == kind }
    }

    static func findItems(kind: SiriMediaKind, matching rawQuery: String, limit: Int = 10) -> [SiriMediaIndexItem] {
        let query = SiriPhraseNormalizer.normalized(rawQuery)
        guard !query.isEmpty else { return [] }

        let scored: [(item: SiriMediaIndexItem, score: Double)] = fetchItems(kind: kind)
            .compactMap { item in
                let score = SiriMatchScorer.scoreMatch(
                    query: query,
                    candidate: SiriPhraseNormalizer.normalized(item.displayName)
                )
                guard score >= minimumMatchScore else { return nil }
                return (item: item, score: score)
            }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsName = lhs.item.displayName
            let rhsName = rhs.item.displayName
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        let deduplicated = deduplicateEquivalentItems(sorted.map(\.item))
        let results = Array(deduplicated.prefix(limit))
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: findItems kind=\(kind.rawValue, privacy: .public) raw='\(rawQuery, privacy: .private)' normalized='\(query, privacy: .private)' matches=\(results.count, privacy: .public)"
        )
        return results
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

    private static func deduplicateEquivalentItems(_ items: [SiriMediaIndexItem]) -> [SiriMediaIndexItem] {
        var seenKeys = Set<String>()
        var results: [SiriMediaIndexItem] = []
        results.reserveCapacity(items.count)

        for item in items {
            let displayKey = SiriPhraseNormalizer.normalized(item.displayName)
            let secondaryKey = SiriPhraseNormalizer.normalized(item.secondaryText ?? "")
            let canonicalKey = "\(displayKey)|\(secondaryKey)"
            if seenKeys.insert(canonicalKey).inserted {
                results.append(item)
            }
        }

        return results
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
        let results = SiriIndexLookup.findItems(kind: .album, matching: string).map { item in
            EnsembleAlbumEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: album entities(matching:) raw='\(string, privacy: .private)' resolved=\(results.count, privacy: .public)"
        )
        return results
    }

    func suggestedEntities() async throws -> [EnsembleAlbumEntity] {
        // Avoid broad fallback suggestions for albums because Siri may auto-pick
        // an unrelated entry when speech capture is incomplete.
        []
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
        let results = SiriIndexLookup.findItems(kind: .playlist, matching: string).map { item in
            EnsemblePlaylistEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: playlist entities(matching:) raw='\(string, privacy: .private)' resolved=\(results.count, privacy: .public)"
        )
        return results
    }

    func suggestedEntities() async throws -> [EnsemblePlaylistEntity] {
        // Keep playlist resolution strict for voice use; show no generic list on low confidence.
        []
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
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform album title='\(album.title, privacy: .private)' id='\(album.id, privacy: .private)'"
        )
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
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform playlist title='\(playlist.title, privacy: .private)' id='\(playlist.id, privacy: .private)'"
        )
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
                "In \(.applicationName), play album \(\.$album)"
            ],
            shortTitle: "Play Album",
            systemImageName: "opticaldisc"
        )

        AppShortcut(
            intent: PlayEnsemblePlaylistIntent(),
            phrases: [
                "Play playlist \(\.$playlist) on \(.applicationName)",
                "In \(.applicationName), play playlist \(\.$playlist)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
    }
}
#endif
