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

    static func fetchItems(kind: SiriMediaKind) -> [SiriMediaIndexItem] {
        SiriMediaIndexResolver.items(in: loadIndex(), kind: kind)
    }

    static func findItems(kind: SiriMediaKind, matching rawQuery: String, limit: Int = 10) -> [SiriMediaIndexItem] {
        let results = SiriMediaIndexResolver.findItems(
            in: loadIndex(),
            kind: kind,
            matching: rawQuery,
            limit: limit
        )
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: findItems kind=\(kind.rawValue, privacy: .public) raw='\(rawQuery, privacy: .private)' matches=\(results.count, privacy: .public)"
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
        return SiriMediaIndexResolver.loadIndex(from: url)
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
struct EnsembleTrackEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Track")
    static var defaultQuery = EnsembleTrackEntityQuery()

    let id: String
    let ratingKey: String
    let title: String
    let subtitle: String?
    let sourceCompositeKey: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

@available(iOS 16.0, *)
struct EnsembleTrackEntityQuery: EntityStringQuery {
    func entities(for identifiers: [EnsembleTrackEntity.ID]) async throws -> [EnsembleTrackEntity] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }

        return SiriIndexLookup.fetchItems(kind: .track)
            .map { item in
                EnsembleTrackEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    subtitle: item.secondaryText,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnsembleTrackEntity] {
        let results = SiriIndexLookup.findItems(kind: .track, matching: string).map { item in
            EnsembleTrackEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                subtitle: item.secondaryText,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: track entities(matching:) raw='\(string, privacy: .private)' resolved=\(results.count, privacy: .public)"
        )
        return results
    }

    func suggestedEntities() async throws -> [EnsembleTrackEntity] {
        []
    }
}

@available(iOS 16.0, *)
struct EnsembleArtistEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Artist")
    static var defaultQuery = EnsembleArtistEntityQuery()

    let id: String
    let ratingKey: String
    let title: String
    let sourceCompositeKey: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

@available(iOS 16.0, *)
struct EnsembleArtistEntityQuery: EntityStringQuery {
    func entities(for identifiers: [EnsembleArtistEntity.ID]) async throws -> [EnsembleArtistEntity] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else { return [] }

        return SiriIndexLookup.fetchItems(kind: .artist)
            .map { item in
                EnsembleArtistEntity(
                    id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                    ratingKey: item.id,
                    title: item.displayName,
                    sourceCompositeKey: item.sourceCompositeKey
                )
            }
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnsembleArtistEntity] {
        let results = SiriIndexLookup.findItems(kind: .artist, matching: string).map { item in
            EnsembleArtistEntity(
                id: makeCompositeEntityID(ratingKey: item.id, sourceCompositeKey: item.sourceCompositeKey),
                ratingKey: item.id,
                title: item.displayName,
                sourceCompositeKey: item.sourceCompositeKey
            )
        }
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: artist entities(matching:) raw='\(string, privacy: .private)' resolved=\(results.count, privacy: .public)"
        )
        return results
    }

    func suggestedEntities() async throws -> [EnsembleArtistEntity] {
        []
    }
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
    static func play(
        kind: SiriMediaKind,
        ratingKey: String,
        sourceCompositeKey: String?,
        displayName: String,
        shuffle: Bool = false
    ) async throws {
        let payload = SiriPlaybackRequestPayload(
            kind: kind,
            entityID: ratingKey,
            sourceCompositeKey: sourceCompositeKey,
            displayName: displayName,
            shuffle: shuffle
        )
        try await DependencyContainer.shared.siriPlaybackCoordinator.execute(payload: payload)
    }
}

/// AppIntent fallback for album playback when SiriKit media-domain routing misses the app.
@available(iOS 16.0, *)
struct PlayEnsembleTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Track in Ensemble"
    static var description = IntentDescription("Plays a specific track from your Ensemble library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Track")
    var track: EnsembleTrackEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform track title='\(track.title, privacy: .private)' id='\(track.id, privacy: .private)'"
        )
        let parsedID = parseCompositeEntityID(track.id)
        try await SiriShortcutPlaybackExecutor.play(
            kind: .track,
            ratingKey: parsedID.ratingKey,
            sourceCompositeKey: parsedID.sourceCompositeKey,
            displayName: track.title
        )
        return .result(dialog: IntentDialog("Playing \(track.title) in Ensemble."))
    }
}

/// AppIntent fallback for artist playback when SiriKit media-domain routing misses the app.
@available(iOS 16.0, *)
struct PlayEnsembleArtistIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Artist in Ensemble"
    static var description = IntentDescription("Plays music by a specific artist from your Ensemble library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Artist")
    var artist: EnsembleArtistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform artist title='\(artist.title, privacy: .private)' id='\(artist.id, privacy: .private)'"
        )
        let parsedID = parseCompositeEntityID(artist.id)
        try await SiriShortcutPlaybackExecutor.play(
            kind: .artist,
            ratingKey: parsedID.ratingKey,
            sourceCompositeKey: parsedID.sourceCompositeKey,
            displayName: artist.title
        )
        return .result(dialog: IntentDialog("Playing \(artist.title) in Ensemble."))
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

/// AppIntent fallback for shuffled playlist playback when SiriKit drops the media item slot.
@available(iOS 16.0, *)
struct ShuffleEnsemblePlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Playlist in Ensemble"
    static var description = IntentDescription("Shuffles a specific playlist from your Ensemble library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Playlist")
    var playlist: EnsemblePlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform shuffle playlist title='\(playlist.title, privacy: .private)' id='\(playlist.id, privacy: .private)'"
        )
        let parsedID = parseCompositeEntityID(playlist.id)
        try await SiriShortcutPlaybackExecutor.play(
            kind: .playlist,
            ratingKey: parsedID.ratingKey,
            sourceCompositeKey: parsedID.sourceCompositeKey,
            displayName: playlist.title,
            shuffle: true
        )
        return .result(dialog: IntentDialog("Shuffling \(playlist.title) in Ensemble."))
    }
}

/// Registers explicit Siri phrases so Ensemble can be invoked even when media-domain parsing fails.
@available(iOS 16.0, *)
struct EnsembleAppShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayEnsembleTrackIntent(),
            phrases: [
                "Play track \(\.$track) on \(.applicationName)",
                "In \(.applicationName), play track \(\.$track)"
            ],
            shortTitle: "Play Track",
            systemImageName: "music.note"
        )

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
            intent: PlayEnsembleArtistIntent(),
            phrases: [
                "Play artist \(\.$artist) on \(.applicationName)",
                "In \(.applicationName), play artist \(\.$artist)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
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

        AppShortcut(
            intent: ShuffleEnsemblePlaylistIntent(),
            phrases: [
                "Shuffle playlist \(\.$playlist) on \(.applicationName)",
                "Shuffle the playlist \(\.$playlist) on \(.applicationName)",
                "Shuffle \(\.$playlist) on \(.applicationName)",
                "Shuffle \(\.$playlist) playlist on \(.applicationName)",
                "In \(.applicationName), shuffle the playlist \(\.$playlist)",
                "In \(.applicationName), shuffle playlist \(\.$playlist)"
            ],
            shortTitle: "Shuffle Playlist",
            systemImageName: "shuffle"
        )
    }
}
#endif
