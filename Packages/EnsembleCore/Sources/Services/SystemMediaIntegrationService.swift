import CoreSpotlight
import EnsemblePersistence
import EnsembleSiriShared
import Foundation
import UniformTypeIdentifiers

#if !os(macOS)
import Intents
#endif

public enum PlaybackStartOrigin: String, Codable, Sendable, Equatable {
    case appUI
    case siri
    case appShortcut
    case remoteCommand
    case autoplay
    case gaplessAdvance
    case queueRestoration
    case backgroundRecovery
}

public enum PlaybackStartSource: String, Codable, Sendable, Equatable {
    case track
    case album
    case artist
    case playlist
    case radio
    case downloads
    case unknown

    init(kind: SiriMediaKind) {
        switch kind {
        case .track:
            self = .track
        case .album:
            self = .album
        case .artist:
            self = .artist
        case .playlist:
            self = .playlist
        }
    }

    var siriMediaKind: SiriMediaKind? {
        switch self {
        case .track:
            return .track
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        case .radio, .downloads, .unknown:
            return nil
        }
    }
}

public struct PlaybackStartContext: Sendable, Equatable {
    public let origin: PlaybackStartOrigin
    public let source: PlaybackStartSource
    public let reference: SystemMediaReference?

    public init(
        origin: PlaybackStartOrigin = .appUI,
        source: PlaybackStartSource = .unknown,
        reference: SystemMediaReference? = nil
    ) {
        self.origin = origin
        self.source = source
        self.reference = reference
    }

    public static let userInitiated = PlaybackStartContext(origin: .appUI)

    public static func media(
        origin: PlaybackStartOrigin = .appUI,
        source: PlaybackStartSource,
        id: String,
        sourceCompositeKey: String?,
        displayName: String,
        secondaryText: String? = nil
    ) -> PlaybackStartContext {
        PlaybackStartContext(
            origin: origin,
            source: source,
            reference: source.siriMediaKind.map {
                SystemMediaReference(
                    kind: $0,
                    id: id,
                    sourceCompositeKey: sourceCompositeKey,
                    displayName: displayName,
                    secondaryText: secondaryText
                )
            }
        )
    }

    public var isDonationEligible: Bool {
        origin == .appUI && reference != nil
    }
}

@MainActor
public protocol SystemMediaIntegrationServiceProtocol: AnyObject {
    func donatePlaybackStart(
        reference: SystemMediaReference,
        shuffle: Bool,
        origin: PlaybackStartOrigin
    ) async
    func refreshSpotlightIndex() async
    func deleteUnavailableSystemMedia(_ references: [SystemMediaReference]) async
    func updateMediaUserContext() async
}

@MainActor
public final class NoOpSystemMediaIntegrationService: SystemMediaIntegrationServiceProtocol {
    public init() {}

    public func donatePlaybackStart(
        reference: SystemMediaReference,
        shuffle: Bool,
        origin: PlaybackStartOrigin
    ) async {}

    public func refreshSpotlightIndex() async {}

    public func deleteUnavailableSystemMedia(_ references: [SystemMediaReference]) async {}

    public func updateMediaUserContext() async {}
}

protocol SystemSpotlightIndexing: AnyObject {
    var isIndexingAvailable: Bool { get }
    func indexSearchableItems(_ items: [CSSearchableItem]) async throws
    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws
}

final class CoreSpotlightSystemIndex: SystemSpotlightIndexing {
    private let index: CSSearchableIndex

    init(index: CSSearchableIndex = CSSearchableIndex(name: "SystemMedia", protectionClass: FileProtectionType.completeUntilFirstUserAuthentication)) {
        self.index = index
    }

    var isIndexingAvailable: Bool {
        CSSearchableIndex.isIndexingAvailable()
    }

    func indexSearchableItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deleteSearchableItems(withIdentifiers identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withIdentifiers: identifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String]) async throws {
        guard !domainIdentifiers.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: domainIdentifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

#if !os(macOS)
protocol SystemMediaIntentDonating: AnyObject {
    func donate(_ interaction: INInteraction) async throws
    func deleteInteractions(withIdentifiers identifiers: [String]) async throws
}

protocol SystemMediaArtworkProviding: AnyObject {
    func artworkData(for reference: SystemMediaReference) async -> Data?
}

protocol SystemMediaVocabularyRegistering: AnyObject {
    func setVocabularyStrings(_ vocabulary: NSOrderedSet, of type: INVocabularyStringType)
}

final class LiveSystemMediaIntentDonor: SystemMediaIntentDonating {
    func donate(_ interaction: INInteraction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            interaction.donate { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func deleteInteractions(withIdentifiers identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            INInteraction.delete(with: identifiers) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

final class LocalSystemMediaArtworkProvider: SystemMediaArtworkProviding {
    func artworkData(for reference: SystemMediaReference) async -> Data? {
        await Task.detached(priority: .utility) {
            SystemMediaIntegrationService.localArtworkData(for: reference)
        }.value
    }
}

final class LiveSystemMediaArtworkProvider: SystemMediaArtworkProviding {
    private static let remoteArtworkTimeout: TimeInterval = 8

    private let artworkLoader: ArtworkLoaderProtocol
    private let session: URLSession

    init(
        artworkLoader: ArtworkLoaderProtocol,
        session: URLSession = .shared
    ) {
        self.artworkLoader = artworkLoader
        self.session = session
    }

    func artworkData(for reference: SystemMediaReference) async -> Data? {
        if let localData = await localArtworkData(for: reference) {
            return localData
        }

        guard let artworkPath = reference.artworkPath, !artworkPath.isEmpty else {
            return nil
        }

        guard let artworkURL = await artworkLoader.artworkURLAsync(
            for: artworkPath,
            sourceKey: reference.sourceCompositeKey,
            ratingKey: reference.artworkCacheKey ?? reference.id,
            fallbackPath: nil,
            fallbackRatingKey: nil,
            size: SystemMediaIntegrationService.systemSuggestionArtworkSize
        ) else {
            return nil
        }

        if artworkURL.isFileURL {
            return await Task.detached(priority: .utility) {
                SystemMediaIntegrationService.artworkData(at: artworkURL)
            }.value
        }

        do {
            let request = URLRequest(
                url: artworkURL,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: Self.remoteArtworkTimeout
            )
            let (data, response) = try await session.data(for: request)
            guard Self.isSuccessfulArtworkResponse(response),
                  SystemMediaIntegrationService.isValidSystemArtworkData(data) else {
                return nil
            }
            return data
        } catch {
            EnsembleLogger.debug("[SystemMedia] Failed to fetch suggestion artwork: \(error.localizedDescription)")
            return nil
        }
    }

    private func localArtworkData(for reference: SystemMediaReference) async -> Data? {
        await Task.detached(priority: .utility) {
            SystemMediaIntegrationService.localArtworkData(for: reference)
        }.value
    }

    private static func isSuccessfulArtworkResponse(_ response: URLResponse) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else {
            return true
        }
        return (200...299).contains(httpResponse.statusCode)
    }
}

final class LiveSystemMediaVocabularyRegistrar: SystemMediaVocabularyRegistering {
    func setVocabularyStrings(_ vocabulary: NSOrderedSet, of type: INVocabularyStringType) {
        INVocabulary.shared().setVocabularyStrings(vocabulary, of: type)
    }
}
#endif

@MainActor
public final class SystemMediaIntegrationService: SystemMediaIntegrationServiceProtocol {
    private static let spotlightChunkSize = 200
    private static let siriVocabularyLimit = 750
    nonisolated static let systemSuggestionArtworkSize = 500
    nonisolated static let maximumSystemArtworkBytes = 5 * 1024 * 1024

    private let siriMediaIndexStore: SiriMediaIndexStore
    private let mediaUserContextManager: SiriMediaUserContextManagerProtocol
    private let spotlightIndex: SystemSpotlightIndexing
    private let notificationCenter: NotificationCenter
    private weak var foregroundWorkScheduler: ForegroundWorkScheduling?
    private var rebuildObserverToken: NSObjectProtocol?

    #if !os(macOS)
    private let intentDonor: SystemMediaIntentDonating
    private let artworkProvider: SystemMediaArtworkProviding
    private let vocabularyRegistrar: SystemMediaVocabularyRegistering
    #endif

    public convenience init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol,
        artworkLoader: ArtworkLoaderProtocol? = nil,
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        #if os(macOS)
        self.init(
            siriMediaIndexStore: siriMediaIndexStore,
            mediaUserContextManager: mediaUserContextManager,
            spotlightIndex: CoreSpotlightSystemIndex(),
            foregroundWorkScheduler: foregroundWorkScheduler
        )
        #else
        self.init(
            siriMediaIndexStore: siriMediaIndexStore,
            mediaUserContextManager: mediaUserContextManager,
            spotlightIndex: CoreSpotlightSystemIndex(),
            intentDonor: LiveSystemMediaIntentDonor(),
            artworkProvider: artworkLoader.map { LiveSystemMediaArtworkProvider(artworkLoader: $0) }
                ?? LocalSystemMediaArtworkProvider(),
            vocabularyRegistrar: LiveSystemMediaVocabularyRegistrar(),
            foregroundWorkScheduler: foregroundWorkScheduler
        )
        #endif
    }

    #if os(macOS)
    init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol,
        spotlightIndex: SystemSpotlightIndexing,
        notificationCenter: NotificationCenter = .default,
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        self.siriMediaIndexStore = siriMediaIndexStore
        self.mediaUserContextManager = mediaUserContextManager
        self.spotlightIndex = spotlightIndex
        self.notificationCenter = notificationCenter
        self.foregroundWorkScheduler = foregroundWorkScheduler
        installRebuildObserver()
    }
    #else
    init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol,
        spotlightIndex: SystemSpotlightIndexing,
        intentDonor: SystemMediaIntentDonating,
        artworkProvider: SystemMediaArtworkProviding,
        vocabularyRegistrar: SystemMediaVocabularyRegistering,
        notificationCenter: NotificationCenter = .default,
        foregroundWorkScheduler: ForegroundWorkScheduling? = nil
    ) {
        self.siriMediaIndexStore = siriMediaIndexStore
        self.mediaUserContextManager = mediaUserContextManager
        self.spotlightIndex = spotlightIndex
        self.intentDonor = intentDonor
        self.artworkProvider = artworkProvider
        self.vocabularyRegistrar = vocabularyRegistrar
        self.notificationCenter = notificationCenter
        self.foregroundWorkScheduler = foregroundWorkScheduler
        installRebuildObserver()
    }
    #endif

    deinit {
        if let rebuildObserverToken {
            notificationCenter.removeObserver(rebuildObserverToken)
        }
    }

    private func installRebuildObserver() {
        rebuildObserverToken = notificationCenter.addObserver(
            forName: SiriMediaIndexNotifications.rebuildRequested,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refreshSpotlightIndex()
            }
        }
    }

    public func donatePlaybackStart(
        reference: SystemMediaReference,
        shuffle: Bool,
        origin: PlaybackStartOrigin
    ) async {
        guard origin == .appUI else {
            EnsembleLogger.debug("[SystemMedia] Skipping playback donation for origin=\(origin.rawValue)")
            return
        }

        #if os(macOS)
        EnsembleLogger.debug("[SystemMedia] Playback donation skipped on macOS")
        #else
        let artworkData = await artworkProvider.artworkData(for: reference)
        let intent = Self.makePlayMediaIntent(
            reference: reference,
            shuffle: shuffle,
            artworkData: artworkData
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = Self.donationIdentifier(reference: reference, shuffle: shuffle)
        interaction.groupIdentifier = Self.donationGroupIdentifier(for: reference)
        interaction.direction = .outgoing

        do {
            try await intentDonor.donate(interaction)
            EnsembleLogger.debug("[SystemMedia] Donated PlayMedia start kind=\(reference.kind.rawValue) id=\(reference.id) source=\(reference.sourceCompositeKey ?? "nil") shuffle=\(shuffle)")
        } catch {
            EnsembleLogger.debug("[SystemMedia] Failed PlayMedia donation kind=\(reference.kind.rawValue) id=\(reference.id): \(error.localizedDescription)")
        }
        #endif
    }

    public func refreshSpotlightIndex() async {
        if let foregroundWorkScheduler {
            guard await foregroundWorkScheduler.waitUntilAllowed(.systemMediaIndexing, policy: .idleOnly) else {
                EnsembleLogger.debug("[SystemMedia] Spotlight refresh skipped; foreground work is not available")
                return
            }
        }

        let previousIndex = siriMediaIndexStore.loadIndexUnbounded()
        let rebuiltIndex = await siriMediaIndexStore.rebuildIndex()
        let index = rebuiltIndex ?? previousIndex
        guard let index else {
            EnsembleLogger.debug("[SystemMedia] Spotlight refresh skipped; no media index")
            return
        }

        if let rebuiltIndex {
            let staleReferences = Self.staleSystemMediaReferences(previous: previousIndex, current: rebuiltIndex)
            await deleteUnavailableSystemMedia(staleReferences)
        }

        refreshSiriVocabulary(from: index)

        guard spotlightIndex.isIndexingAvailable else {
            EnsembleLogger.debug("[SystemMedia] Spotlight indexing unavailable")
            return
        }

        let items = Self.makeSpotlightItems(from: index.items)
        do {
            for chunk in items.chunked(into: Self.spotlightChunkSize) {
                try await spotlightIndex.indexSearchableItems(chunk)
            }
            EnsembleLogger.debug("[SystemMedia] Spotlight indexed \(items.count) media items")
        } catch {
            EnsembleLogger.debug("[SystemMedia] Spotlight indexing failed: \(error.localizedDescription)")
        }
    }

    public func deleteUnavailableSystemMedia(_ references: [SystemMediaReference]) async {
        guard !references.isEmpty else { return }

        let identifiers = Array(Set(references.map(Self.spotlightIdentifier(for:)))).sorted()
        if spotlightIndex.isIndexingAvailable {
            do {
                try await spotlightIndex.deleteSearchableItems(withIdentifiers: identifiers)
                EnsembleLogger.debug("[SystemMedia] Spotlight deleted \(identifiers.count) unavailable media items")
            } catch {
                EnsembleLogger.debug("[SystemMedia] Spotlight item deletion failed: \(error.localizedDescription)")
            }
        }

        #if !os(macOS)
        let donationIdentifiers = Array(Set(references.flatMap(Self.donationIdentifiers(for:)))).sorted()
        do {
            try await intentDonor.deleteInteractions(withIdentifiers: donationIdentifiers)
            EnsembleLogger.debug("[SystemMedia] Deleted \(donationIdentifiers.count) unavailable Siri media donations")
        } catch {
            EnsembleLogger.debug("[SystemMedia] Siri media donation deletion failed: \(error.localizedDescription)")
        }
        #endif
    }

    public func updateMediaUserContext() async {
        await mediaUserContextManager.updateMediaUserContext()
    }

    private func refreshSiriVocabulary(from index: SiriMediaIndex) {
        #if os(iOS)
        let playlistTitles = Self.siriVocabularyStrings(
            from: index.items,
            kind: .playlist,
            limit: Self.siriVocabularyLimit
        )
        vocabularyRegistrar.setVocabularyStrings(
            NSOrderedSet(array: playlistTitles),
            of: .mediaPlaylistTitle
        )

        let artistNames = Self.siriVocabularyStrings(
            from: index.items,
            kind: .artist,
            limit: Self.siriVocabularyLimit
        )
        vocabularyRegistrar.setVocabularyStrings(
            NSOrderedSet(array: artistNames),
            of: .mediaMusicArtistName
        )

        EnsembleLogger.debug("[SystemMedia] Registered Siri vocabulary playlists=\(playlistTitles.count) artists=\(artistNames.count)")
        #endif
    }

    static func makeSpotlightItems(from indexItems: [SiriMediaIndexItem]) -> [CSSearchableItem] {
        let artworkFilenames = cachedArtworkFilenames()
        return indexItems.map { item in
            let reference = item.reference
            let attributeSet = makeSpotlightAttributeSet(
                for: item,
                availableArtworkFilenames: artworkFilenames
            )
            let searchableItem = CSSearchableItem(
                uniqueIdentifier: spotlightIdentifier(for: reference),
                domainIdentifier: spotlightDomainIdentifier(for: reference),
                attributeSet: attributeSet
            )
            searchableItem.expirationDate = Date.distantFuture
            return searchableItem
        }
    }

    static func makeSpotlightAttributeSet(
        for item: SiriMediaIndexItem,
        availableArtworkFilenames: Set<String>? = nil
    ) -> CSSearchableItemAttributeSet {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .audio)
        attributeSet.title = item.displayName
        attributeSet.displayName = item.displayName
        attributeSet.contentDescription = item.secondaryText
        attributeSet.artist = item.artistName ?? item.secondaryText
        attributeSet.album = item.albumTitle
        attributeSet.duration = item.duration.map(NSNumber.init(value:))
        attributeSet.keywords = spotlightKeywords(for: item)
        attributeSet.domainIdentifier = spotlightDomainIdentifier(for: item.reference)
        attributeSet.thumbnailURL = localArtworkURL(
            for: item,
            availableArtworkFilenames: availableArtworkFilenames
        )
        return attributeSet
    }

    static func spotlightIdentifier(for reference: SystemMediaReference) -> String {
        SystemMediaSpotlightIdentity.spotlightIdentifier(for: reference)
    }

    static func spotlightDomainIdentifier(for reference: SystemMediaReference) -> String {
        let source = sanitizeDomainComponent(reference.sourceCompositeKey ?? "local")
        return "ensemble.\(source).\(reference.kind.rawValue)"
    }

    static func donationIdentifier(reference: SystemMediaReference, shuffle: Bool) -> String {
        "ensemble.play.\(reference.sourceScopedIdentifier).shuffle.\(shuffle ? "1" : "0")"
    }

    static func donationIdentifiers(for reference: SystemMediaReference) -> [String] {
        [
            donationIdentifier(reference: reference, shuffle: false),
            donationIdentifier(reference: reference, shuffle: true)
        ]
    }

    static func donationGroupIdentifier(for reference: SystemMediaReference) -> String {
        "ensemble.play.\(reference.kind.rawValue)"
    }

    static func staleSystemMediaReferences(previous: SiriMediaIndex?, current: SiriMediaIndex) -> [SystemMediaReference] {
        guard let previous else { return [] }
        let currentIdentifiers = Set(current.items.map { spotlightIdentifier(for: $0.reference) })

        return previous.items.compactMap { item in
            let reference = item.reference
            guard !currentIdentifiers.contains(spotlightIdentifier(for: reference)) else {
                return nil
            }
            return reference
        }
    }

    #if !os(macOS)
    static func makePlayMediaIntent(
        reference: SystemMediaReference,
        shuffle: Bool,
        artworkData: Data? = nil
    ) -> INPlayMediaIntent {
        let item = makeMediaItem(reference: reference, artworkData: artworkData)
        let mediaItems = reference.kind == .track ? [item] : nil
        let mediaContainer = reference.kind == .track ? nil : item

        return INPlayMediaIntent(
            mediaItems: mediaItems,
            mediaContainer: mediaContainer,
            playShuffled: shuffle,
            playbackRepeatMode: .unknown,
            resumePlayback: nil,
            playbackQueueLocation: .unknown,
            playbackSpeed: nil,
            mediaSearch: makeMediaSearch(reference: reference)
        )
    }

    private static func makeMediaSearch(reference: SystemMediaReference) -> INMediaSearch {
        let mediaName: String?
        let artistName: String?
        switch reference.kind {
        case .artist:
            mediaName = nil
            artistName = reference.displayName
        case .track:
            mediaName = reference.displayName
            artistName = reference.artistName ?? reference.secondaryText
        case .album, .playlist:
            mediaName = reference.displayName
            artistName = reference.artistName
        }

        return INMediaSearch(
            mediaType: mediaSearchType(for: reference.kind),
            sortOrder: .unknown,
            mediaName: mediaName,
            artistName: artistName,
            albumName: reference.kind == .album ? reference.displayName : nil,
            genreNames: nil,
            moodNames: nil,
            releaseDate: nil,
            reference: .unknown,
            mediaIdentifier: reference.sourceScopedIdentifier
        )
    }

    private static func makeMediaItem(
        reference: SystemMediaReference,
        artworkData: Data?
    ) -> INMediaItem {
        let artwork: INImage?
        if let artworkData {
            artwork = INImage(imageData: artworkData)
        } else if let artworkURL = localArtworkURL(for: reference) {
            artwork = INImage(url: artworkURL)
        } else {
            artwork = nil
        }

        return INMediaItem(
            identifier: reference.sourceScopedIdentifier,
            title: reference.displayName,
            type: mediaItemType(for: reference.kind),
            artwork: artwork,
            artist: reference.artistName ?? reference.secondaryText
        )
    }

    private static func mediaItemType(for kind: SiriMediaKind) -> INMediaItemType {
        switch kind {
        case .track:
            return .song
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        }
    }

    private static func mediaSearchType(for kind: SiriMediaKind) -> INMediaItemType {
        switch kind {
        case .track:
            return .song
        case .album:
            return .album
        case .artist:
            return .music
        case .playlist:
            return .playlist
        }
    }
    #endif

    static func siriVocabularyStrings(
        from indexItems: [SiriMediaIndexItem],
        kind: SiriMediaKind,
        limit: Int
    ) -> [String] {
        guard limit > 0 else { return [] }

        let rankedItems = indexItems
            .filter { $0.kind == kind }
            .sorted(by: vocabularyPrioritySort)

        var seen = Set<String>()
        var strings: [String] = []
        strings.reserveCapacity(Swift.min(limit, rankedItems.count))

        let variantGroups = rankedItems.map {
            siriVocabularyVariants(for: $0.displayName, kind: kind)
        }

        for variants in variantGroups {
            guard let primary = variants.first else { continue }
            appendVocabularyString(primary, seen: &seen, strings: &strings)
            if strings.count >= limit {
                return strings
            }
        }

        for variants in variantGroups {
            for variant in variants.dropFirst() {
                appendVocabularyString(variant, seen: &seen, strings: &strings)
                if strings.count >= limit {
                    return strings
                }
            }
        }

        return strings
    }

    private static func appendVocabularyString(
        _ variant: String,
        seen: inout Set<String>,
        strings: inout [String]
    ) {
        let key = SiriPhraseNormalizer.basic(variant)
        guard !key.isEmpty, seen.insert(key).inserted else { return }
        strings.append(variant)
    }

    static func siriVocabularyVariants(
        for displayName: String,
        kind: SiriMediaKind? = nil
    ) -> [String] {
        let trimmed = displayName
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !trimmed.isEmpty else { return [] }

        var variants = [trimmed]

        if trimmed.range(of: "\\bvideo\\b", options: [.regularExpression, .caseInsensitive]) != nil {
            variants.append(replacingWord("video", with: "videos", in: trimmed))
        }

        let words = trimmed.split(separator: " ").map(String.init)
        if let first = words.first,
           first.caseInsensitiveCompare("music") == .orderedSame,
           words.count > 1 {
            let withoutLeadingMusic = words.dropFirst().joined(separator: " ")
            variants.append(withoutLeadingMusic)
            if withoutLeadingMusic.range(of: "\\bvideo\\b", options: [.regularExpression, .caseInsensitive]) != nil {
                variants.append(replacingWord("video", with: "videos", in: withoutLeadingMusic))
            }
        }

        if kind == .playlist {
            let baseVariants = variants
            for variant in baseVariants {
                variants.append("\(variant) playlist")
                variants.append("playlist \(variant)")
                variants.append("the playlist \(variant)")
            }
        }

        var seen = Set<String>()
        return variants.filter { variant in
            let key = SiriPhraseNormalizer.basic(variant)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    private static func spotlightKeywords(for item: SiriMediaIndexItem) -> [String] {
        [
            item.kind.rawValue,
            item.displayName,
            item.secondaryText,
            item.albumTitle,
            item.artistName,
            item.genre
        ]
        .compactMap { $0 }
        .flatMap { value in
            value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    nonisolated static func localArtworkURL(
        for item: SiriMediaIndexItem,
        artworkDirectory: URL = ArtworkDownloadManager.artworkDirectory,
        fileManager: FileManager = .default,
        availableArtworkFilenames: Set<String>? = nil
    ) -> URL? {
        localArtworkURL(
            cacheKey: item.artworkCacheKey,
            cacheType: item.artworkCacheType,
            artworkPath: item.artworkPath,
            fallbackKey: item.id,
            fallbackType: defaultArtworkCacheType(for: item.kind),
            artworkDirectory: artworkDirectory,
            fileManager: fileManager,
            availableArtworkFilenames: availableArtworkFilenames
        )
    }

    nonisolated static func localArtworkURL(
        for reference: SystemMediaReference,
        artworkDirectory: URL = ArtworkDownloadManager.artworkDirectory,
        fileManager: FileManager = .default,
        availableArtworkFilenames: Set<String>? = nil
    ) -> URL? {
        localArtworkURL(
            cacheKey: reference.artworkCacheKey,
            cacheType: reference.artworkCacheType,
            artworkPath: reference.artworkPath,
            fallbackKey: reference.id,
            fallbackType: defaultArtworkCacheType(for: reference.kind),
            artworkDirectory: artworkDirectory,
            fileManager: fileManager,
            availableArtworkFilenames: availableArtworkFilenames
        )
    }

    nonisolated static func localArtworkData(
        for reference: SystemMediaReference,
        artworkDirectory: URL = ArtworkDownloadManager.artworkDirectory,
        fileManager: FileManager = .default,
        availableArtworkFilenames: Set<String>? = nil
    ) -> Data? {
        guard let url = localArtworkURL(
            for: reference,
            artworkDirectory: artworkDirectory,
            fileManager: fileManager,
            availableArtworkFilenames: availableArtworkFilenames
        ) else {
            return nil
        }
        return artworkData(at: url, fileManager: fileManager)
    }

    nonisolated static func artworkData(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Data? {
        if url.isFileURL,
           let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let fileSize = attributes[.size] as? NSNumber,
           fileSize.intValue > maximumSystemArtworkBytes {
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              isValidSystemArtworkData(data) else {
            return nil
        }
        return data
    }

    nonisolated static func isValidSystemArtworkData(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maximumSystemArtworkBytes
    }

    nonisolated private static func localArtworkURL(
        cacheKey: String?,
        cacheType: SiriMediaArtworkCacheType?,
        artworkPath: String?,
        fallbackKey: String,
        fallbackType: SiriMediaArtworkCacheType?,
        artworkDirectory: URL,
        fileManager: FileManager,
        availableArtworkFilenames: Set<String>?
    ) -> URL? {
        var candidates: [(String, SiriMediaArtworkCacheType)] = []
        if let cacheKey, let cacheType {
            candidates.append((cacheKey, cacheType))
        }

        if let pathKey = ratingKey(fromArtworkPath: artworkPath) {
            let pathType = cacheType ?? fallbackType ?? .album
            candidates.append((pathKey, pathType))
        }

        if let fallbackType {
            candidates.append((fallbackKey, fallbackType))
        }

        if let cacheKey {
            candidates.append(contentsOf: artworkFallbackTypes.map { (cacheKey, $0) })
        }

        if let pathKey = ratingKey(fromArtworkPath: artworkPath) {
            candidates.append(contentsOf: artworkFallbackTypes.map { (pathKey, $0) })
        }

        candidates.append(contentsOf: artworkFallbackTypes.map { (fallbackKey, $0) })

        var seen = Set<String>()
        for (key, type) in candidates {
            let filename = "\(key)_\(type.rawValue).jpg"
            guard seen.insert(filename).inserted else { continue }
            let url = artworkDirectory.appendingPathComponent(filename)
            if availableArtworkFilenames?.contains(filename) == true
                || (availableArtworkFilenames == nil && fileManager.fileExists(atPath: url.path)) {
                return url
            }
        }

        return nil
    }

    nonisolated private static let artworkFallbackTypes: [SiriMediaArtworkCacheType] = [
        .album,
        .artist,
        .playlist,
        .track
    ]

    nonisolated private static func defaultArtworkCacheType(for kind: SiriMediaKind) -> SiriMediaArtworkCacheType? {
        switch kind {
        case .track:
            return .album
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        }
    }

    nonisolated private static func ratingKey(fromArtworkPath path: String?) -> String? {
        guard let path else { return nil }
        let components = path.split(separator: "/")
        guard components.count >= 3,
              components[0] == "library",
              components[1] == "metadata" else {
            return nil
        }
        return String(components[2])
    }

    nonisolated private static func cachedArtworkFilenames(
        artworkDirectory: URL = ArtworkDownloadManager.artworkDirectory,
        fileManager: FileManager = .default
    ) -> Set<String> {
        guard let filenames = try? fileManager.contentsOfDirectory(atPath: artworkDirectory.path) else {
            return []
        }
        return Set(filenames)
    }

    private static func sanitizeDomainComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let sanitized = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return sanitized.isEmpty ? "local" : sanitized
    }

    private static func vocabularyPrioritySort(lhs: SiriMediaIndexItem, rhs: SiriMediaIndexItem) -> Bool {
        switch (lhs.lastPlayed, rhs.lastPlayed) {
        case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
            return lhsDate > rhsDate
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        let lhsPlayCount = lhs.playCount ?? 0
        let rhsPlayCount = rhs.playCount ?? 0
        if lhsPlayCount != rhsPlayCount {
            return lhsPlayCount > rhsPlayCount
        }

        let lhsTrackCount = lhs.trackCount ?? 0
        let rhsTrackCount = rhs.trackCount ?? 0
        if lhsTrackCount != rhsTrackCount {
            return lhsTrackCount > rhsTrackCount
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func replacingWord(_ target: String, with replacement: String, in value: String) -> String {
        value.split(separator: " ").map { word in
            guard word.caseInsensitiveCompare(target) == .orderedSame else {
                return String(word)
            }
            return word.first?.isUppercase == true ? replacement.capitalized : replacement
        }
        .joined(separator: " ")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
