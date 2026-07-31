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

    static func fetchItems() -> [SiriMediaIndexItem] {
        loadIndex()?.items ?? []
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

    static func findItems(matching rawQuery: String, limit: Int = 10) -> [SiriMediaIndexItem] {
        let ranked = SiriMediaIndexResolver.rankCandidates(
            for: rawQuery,
            requestedKinds: nil,
            index: loadIndex(),
            minimumScore: SiriMediaIndexResolver.defaultMinimumMatchScore
        )
        return Array(SiriMediaIndexResolver.deduplicateEquivalentItems(ranked.map(\.item)).prefix(limit))
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
    static var parameterSummary: some ParameterSummary {
        Summary("Play artist \(\.$artist)")
    }

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

/// AppIntent fallback for shuffled artist playback when SiriKit drops the media item slot.
@available(iOS 16.0, *)
struct ShuffleEnsembleArtistIntent: AppIntent {
    static var title: LocalizedStringResource = "Shuffle Artist in Ensemble"
    static var description = IntentDescription("Shuffles music by a specific artist from your Ensemble library.")
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true
    static var parameterSummary: some ParameterSummary {
        Summary("Shuffle the artist \(\.$artistName)")
    }

    @Parameter(title: "Artist")
    var artistName: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let matches = SiriIndexLookup.findItems(kind: .artist, matching: artistName, limit: 3)
        guard let artist = matches.first else {
            SiriAppShortcutLogger.logger.info(
                "SIRI_SHORTCUT: perform shuffle artist raw='\(artistName, privacy: .private)' resolved=0"
            )
            return .result(dialog: IntentDialog("I couldn't find \(artistName) in Ensemble."))
        }

        SiriAppShortcutLogger.logger.info(
            "SIRI_SHORTCUT: perform shuffle artist raw='\(artistName, privacy: .private)' title='\(artist.displayName, privacy: .private)' id='\(artist.id, privacy: .private)' matches=\(matches.count, privacy: .public)"
        )
        try await SiriShortcutPlaybackExecutor.play(
            kind: .artist,
            ratingKey: artist.id,
            sourceCompositeKey: artist.sourceCompositeKey,
            displayName: artist.displayName,
            shuffle: true
        )
        return .result(dialog: IntentDialog("Shuffling \(artist.displayName) in Ensemble."))
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
    static var isDiscoverable: Bool = false
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

@available(iOS 16.0, *)
struct EnsembleMediaEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ensemble Media")
    static var defaultQuery = EnsembleMediaEntityQuery()

    let id: String
    let kindRawValue: String
    let ratingKey: String
    let title: String
    let sourceCompositeKey: String?
    let artistName: String?
    let albumTitle: String?
    let duration: TimeInterval?
    let trackNumber: Int?
    let discNumber: Int?
    let isSmartPlaylist: Bool?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(kind.displayName)"
        )
    }

    var kind: SiriMediaKind {
        SiriMediaKind(rawValue: kindRawValue) ?? .track
    }

    var permalink: EnsemblePermalink {
        EnsemblePermalink(
            kind: kind,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            trackNumber: trackNumber,
            discNumber: discNumber,
            isSmartPlaylist: isSmartPlaylist
        )
    }

    init(item: SiriMediaIndexItem) {
        id = item.reference.sourceScopedIdentifier
        kindRawValue = item.kind.rawValue
        ratingKey = item.id
        title = item.displayName
        sourceCompositeKey = item.sourceCompositeKey
        artistName = item.artistName ?? item.secondaryText
        albumTitle = item.albumTitle
        duration = item.duration
        trackNumber = item.trackNumber
        discNumber = item.discNumber
        isSmartPlaylist = item.isSmartPlaylist
    }
}

@available(iOS 16.0, *)
struct EnsembleMediaEntityQuery: EntityStringQuery {
    func entities(for identifiers: [EnsembleMediaEntity.ID]) async throws -> [EnsembleMediaEntity] {
        let wanted = Set(identifiers)
        return SiriIndexLookup.fetchItems()
            .map(EnsembleMediaEntity.init(item:))
            .filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [EnsembleMediaEntity] {
        SiriIndexLookup.findItems(matching: string).map(EnsembleMediaEntity.init(item:))
    }

    func suggestedEntities() async throws -> [EnsembleMediaEntity] {
        []
    }
}

@available(iOS 16.0, *)
private extension SiriMediaKind {
    var displayName: String {
        switch self {
        case .track: return "Song"
        case .album: return "Album"
        case .artist: return "Artist"
        case .playlist: return "Playlist"
        }
    }
}

/// Opens a selected local media item without starting playback.
@available(iOS 16.0, *)
struct OpenEnsembleMediaIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Media in Ensemble"
    static var description = IntentDescription("Opens a song, artist, album, or playlist in Ensemble without playing it.")
    static var openAppWhenRun = true

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$media) in Ensemble")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reference = SystemMediaReference(
            kind: media.kind,
            id: media.ratingKey,
            sourceCompositeKey: media.sourceCompositeKey,
            displayName: media.title
        )
        if let destination = NavigationCoordinator.systemMediaDestination(
            fromSourceScopedIdentifier: reference.sourceScopedIdentifier
        ) {
            _ = NavigationCoordinator.routeExternalSearchInActiveScene(to: destination)
        }
        return .result(dialog: IntentDialog("Opening \(media.title) in Ensemble."))
    }
}

/// Produces the same portable URL used by the in-app Share Ensemble Link action.
@available(iOS 16.0, *)
struct GetEnsembleLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Ensemble Link"
    static var description = IntentDescription("Creates a library-independent Ensemble link for selected media.")

    @Parameter(title: "Media")
    var media: EnsembleMediaEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get an Ensemble link for \(\.$media)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
        guard let url = media.permalink.url else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        return .result(value: url, dialog: IntentDialog("Created an Ensemble link for \(media.title)."))
    }
}

@available(iOS 16.0, *)
private enum EnsembleFocusFilterLogger {
    static let logger = Logger(
        subsystem: "com.videogorl.ensemble.focus-filter",
        category: "FocusFilter"
    )
}

@available(iOS 16.0, *)
enum EnsembleFocusScrobblingSetting: String, AppEnum {
    case useAppSetting
    case enabled
    case disabled

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Scrobbling")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .useAppSetting: "Use Ensemble Setting",
        .enabled: "Enabled",
        .disabled: "Disabled"
    ]

    var overrideValue: Bool? {
        switch self {
        case .useAppSetting: return nil
        case .enabled: return true
        case .disabled: return false
        }
    }

    var summary: String {
        switch self {
        case .useAppSetting: return "App scrobbling setting"
        case .enabled: return "Scrobbling on"
        case .disabled: return "Scrobbling off"
        }
    }
}

@available(iOS 16.0, *)
struct EnsembleLibraryEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Library")
    static var defaultQuery = EnsembleLibraryEntityQuery()

    let id: String
    let title: String
    let subtitle: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: subtitle.map { "\($0)" }
        )
    }
}

@available(iOS 16.0, *)
struct EnsembleLibraryEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [EnsembleLibraryEntity.ID]) async throws -> [EnsembleLibraryEntity] {
        let wanted = Set(identifiers)
        return Self.availableLibraries().filter { wanted.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [EnsembleLibraryEntity] {
        Self.availableLibraries()
    }

    @MainActor
    private static func availableLibraries() -> [EnsembleLibraryEntity] {
        let accountManager = DependencyContainer.shared.accountManager
        if accountManager.credentialLoadState == .loading, accountManager.plexAccounts.isEmpty {
            accountManager.loadAccounts()
        }

        return accountManager.enabledSources().compactMap { source in
            guard let presentation = accountManager.sourcePresentation(for: source.compositeKey) else {
                return nil
            }
            if source.type == .appleMusic {
                return EnsembleLibraryEntity(
                    id: source.compositeKey,
                    title: presentation.capabilities.displayName,
                    subtitle: nil
                )
            }
            return EnsembleLibraryEntity(
                id: source.compositeKey,
                title: presentation.libraryName,
                subtitle: "\(presentation.serverName) • \(presentation.accountName)"
            )
        }
        .sorted {
            ($0.title, $0.subtitle ?? "", $0.id) < ($1.title, $1.subtitle ?? "", $1.id)
        }
    }
}

/// Applies temporary playback and library-visibility overrides for the active system Focus.
@available(iOS 16.0, *)
struct EnsembleFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Playback & Libraries"
    static var description = IntentDescription(
        "Choose which Ensemble libraries are visible and whether playback scrobbles while this Focus is active."
    )

    @Parameter(title: "Libraries to Show")
    var visibleLibraries: [EnsembleLibraryEntity]?

    @Parameter(title: "Scrobbling", default: .useAppSetting)
    var scrobbling: EnsembleFocusScrobblingSetting

    var displayRepresentation: DisplayRepresentation {
        let librarySummary: String
        switch visibleLibraries?.count {
        case nil:
            librarySummary = "App library visibility"
        case 1:
            librarySummary = visibleLibraries?.first?.title ?? "1 library"
        case let count?:
            librarySummary = "\(count) libraries"
        }
        return DisplayRepresentation(
            title: "Filter Ensemble",
            subtitle: "\(librarySummary), \(scrobbling.summary)"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        apply(resetsLibraryBypass: true)
        return .result()
    }

    @MainActor
    static func refreshCurrent() async {
        do {
            let currentFilter = try await Self.current
            currentFilter.apply(resetsLibraryBypass: false)
        } catch {
            clearOverrides()
            EnsembleFocusFilterLogger.logger.info(
                "FOCUS_FILTER: using app settings because no active configuration was found"
            )
        }
    }

    @MainActor
    private func apply(resetsLibraryBypass: Bool) {
        let visibleSourceKeys = visibleLibraries.map { Set($0.map(\.id)) }
        DependencyContainer.shared.libraryVisibilityStore.setFocusVisibleSourceCompositeKeys(
            visibleSourceKeys,
            resetsBypass: resetsLibraryBypass
        )
        DependencyContainer.shared.settingsManager.setFocusScrobblingOverride(
            scrobbling.overrideValue
        )
        EnsembleFocusFilterLogger.logger.info(
            "FOCUS_FILTER: applied libraries=\(visibleSourceKeys?.count ?? 0, privacy: .public) libraryOverride=\(visibleSourceKeys != nil, privacy: .public) scrobbling=\(scrobbling.rawValue, privacy: .public)"
        )
    }

    @MainActor
    private static func clearOverrides() {
        DependencyContainer.shared.libraryVisibilityStore.setFocusVisibleSourceCompositeKeys(nil)
        DependencyContainer.shared.settingsManager.setFocusScrobblingOverride(nil)
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
                "Play the artist \(\.$artist) on \(.applicationName)",
                "Play music by \(\.$artist) on \(.applicationName)",
                "In \(.applicationName), play artist \(\.$artist)"
            ],
            shortTitle: "Play Artist",
            systemImageName: "music.mic"
        )

        AppShortcut(
            intent: PlayEnsemblePlaylistIntent(),
            phrases: [
                "Play playlist \(\.$playlist) on \(.applicationName)",
                "Play the playlist \(\.$playlist) on \(.applicationName)",
                "In \(.applicationName), play playlist \(\.$playlist)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )

        AppShortcut(
            intent: OpenEnsembleMediaIntent(),
            phrases: [
                "Open \(\.$media) in \(.applicationName)"
            ],
            shortTitle: "Open Media",
            systemImageName: "arrow.up.forward.app"
        )

    }
}
#endif
