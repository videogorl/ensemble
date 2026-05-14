import CoreSpotlight
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

    private let siriMediaIndexStore: SiriMediaIndexStore
    private let mediaUserContextManager: SiriMediaUserContextManagerProtocol
    private let spotlightIndex: SystemSpotlightIndexing

    #if !os(macOS)
    private let intentDonor: SystemMediaIntentDonating
    private let vocabularyRegistrar: SystemMediaVocabularyRegistering
    #endif

    public convenience init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol
    ) {
        #if os(macOS)
        self.init(
            siriMediaIndexStore: siriMediaIndexStore,
            mediaUserContextManager: mediaUserContextManager,
            spotlightIndex: CoreSpotlightSystemIndex()
        )
        #else
        self.init(
            siriMediaIndexStore: siriMediaIndexStore,
            mediaUserContextManager: mediaUserContextManager,
            spotlightIndex: CoreSpotlightSystemIndex(),
            intentDonor: LiveSystemMediaIntentDonor(),
            vocabularyRegistrar: LiveSystemMediaVocabularyRegistrar()
        )
        #endif
    }

    #if os(macOS)
    init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol,
        spotlightIndex: SystemSpotlightIndexing
    ) {
        self.siriMediaIndexStore = siriMediaIndexStore
        self.mediaUserContextManager = mediaUserContextManager
        self.spotlightIndex = spotlightIndex
    }
    #else
    init(
        siriMediaIndexStore: SiriMediaIndexStore,
        mediaUserContextManager: SiriMediaUserContextManagerProtocol,
        spotlightIndex: SystemSpotlightIndexing,
        intentDonor: SystemMediaIntentDonating,
        vocabularyRegistrar: SystemMediaVocabularyRegistering
    ) {
        self.siriMediaIndexStore = siriMediaIndexStore
        self.mediaUserContextManager = mediaUserContextManager
        self.spotlightIndex = spotlightIndex
        self.intentDonor = intentDonor
        self.vocabularyRegistrar = vocabularyRegistrar
    }
    #endif

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
        let intent = Self.makePlayMediaIntent(reference: reference, shuffle: shuffle)
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
        let index: SiriMediaIndex?
        if let existingIndex = siriMediaIndexStore.loadIndexUnbounded() {
            index = existingIndex
        } else {
            index = await siriMediaIndexStore.rebuildIndex()
        }
        guard let index else {
            EnsembleLogger.debug("[SystemMedia] Spotlight refresh skipped; no media index")
            return
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
        guard !references.isEmpty, spotlightIndex.isIndexingAvailable else { return }
        let identifiers = references.map(Self.spotlightIdentifier(for:))
        do {
            try await spotlightIndex.deleteSearchableItems(withIdentifiers: identifiers)
            EnsembleLogger.debug("[SystemMedia] Spotlight deleted \(identifiers.count) unavailable media items")
        } catch {
            EnsembleLogger.debug("[SystemMedia] Spotlight item deletion failed: \(error.localizedDescription)")
        }
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
        indexItems.map { item in
            let reference = item.reference
            let attributeSet = makeSpotlightAttributeSet(for: item)
            let searchableItem = CSSearchableItem(
                uniqueIdentifier: spotlightIdentifier(for: reference),
                domainIdentifier: spotlightDomainIdentifier(for: reference),
                attributeSet: attributeSet
            )
            searchableItem.expirationDate = Date.distantFuture
            return searchableItem
        }
    }

    static func makeSpotlightAttributeSet(for item: SiriMediaIndexItem) -> CSSearchableItemAttributeSet {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .audio)
        attributeSet.title = item.displayName
        attributeSet.displayName = item.displayName
        attributeSet.contentDescription = item.secondaryText
        attributeSet.artist = item.artistName ?? item.secondaryText
        attributeSet.album = item.albumTitle
        attributeSet.duration = item.duration.map(NSNumber.init(value:))
        attributeSet.keywords = spotlightKeywords(for: item)
        attributeSet.domainIdentifier = spotlightDomainIdentifier(for: item.reference)
        return attributeSet
    }

    static func spotlightIdentifier(for reference: SystemMediaReference) -> String {
        "ensemble.systemMedia.\(reference.sourceScopedIdentifier)"
    }

    static func spotlightDomainIdentifier(for reference: SystemMediaReference) -> String {
        let source = sanitizeDomainComponent(reference.sourceCompositeKey ?? "local")
        return "ensemble.\(source).\(reference.kind.rawValue)"
    }

    static func donationIdentifier(reference: SystemMediaReference, shuffle: Bool) -> String {
        "ensemble.play.\(reference.sourceScopedIdentifier).shuffle.\(shuffle ? "1" : "0")"
    }

    static func donationGroupIdentifier(for reference: SystemMediaReference) -> String {
        "ensemble.play.\(reference.kind.rawValue)"
    }

    #if !os(macOS)
    static func makePlayMediaIntent(reference: SystemMediaReference, shuffle: Bool) -> INPlayMediaIntent {
        let item = makeMediaItem(reference: reference)
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
            mediaSearch: nil
        )
    }

    private static func makeMediaItem(reference: SystemMediaReference) -> INMediaItem {
        INMediaItem(
            identifier: reference.sourceScopedIdentifier,
            title: reference.displayName,
            type: mediaItemType(for: reference.kind),
            artwork: nil,
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
