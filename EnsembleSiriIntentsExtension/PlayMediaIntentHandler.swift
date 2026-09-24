import EnsembleSiriShared
import Foundation
import Intents
import OSLog

public final class PlayMediaIntentHandler: NSObject, INPlayMediaIntentHandling {
    private static let pendingFilename = "siri-pending-playback.json"
    private static let darwinNotificationName = "com.videogorl.ensemble.siri.pendingPlayback"
    private static let disambiguationThreshold = 0.1
    private static let payloadResolutionThreshold = 0.66
    private let logger = Logger(
        subsystem: "com.videogorl.ensemble.siri-intents",
        category: "PlayMediaIntentHandler"
    )

    public override init() {
        super.init()
        SiriExtensionLogger.info("SIRI_EXT: PlayMediaIntentHandler.init() called")
    }

    public func resolveMediaItems(
        for intent: INPlayMediaIntent,
        with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void
    ) {
        SiriExtensionLogger.info("SIRI_EXT: resolveMediaItems ENTRY")
        logger.info("resolveMediaItems: ENTRY - received intent")

        // Siri may re-enter resolution after the user taps a disambiguation option.
        // If we already have a valid payload identifier, keep it stable and avoid loops.
        if let selected = intent.mediaItems?.first,
           let identifier = selected.identifier,
           let payload = decodePayloadIdentifier(identifier),
           payload.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion {
            logger.debug("resolveMediaItems: using preselected media item to avoid re-disambiguation")
            if let playShuffled = intent.playShuffled, payload.shuffle != playShuffled {
                completion([.success(with: makeMediaItem(from: payload.updatingShuffle(playShuffled), fallback: selected))])
            } else {
                completion([.success(with: selected)])
            }
            return
        }

        let fields = intent.ensembleSiriPlaybackFields
        guard let query = fields.queryText else {
            logger.info(
                "resolveMediaItems: missing query; requesting value from Siri mediaType=\((intent.mediaSearch?.mediaType ?? .unknown).rawValue, privacy: .public) shuffle=\((intent.playShuffled ?? false), privacy: .public)"
            )
            if intent.playShuffled == true {
                SiriPendingPlayMediaContextStore.recordShuffleRequest(
                    mediaType: mediaType(from: intent),
                    logger: logger
                )
            }
            completion([.needsValue()])
            return
        }
        let normalizedQuery = bestQueryVariant(from: query) ?? query

        let requestedMediaType = resolvedMediaType(from: intent, query: query)
        let requestedShuffle = effectivePlayShuffled(from: intent, mediaType: requestedMediaType)
        logger.info(
            "resolveMediaItems: queryLength=\(normalizedQuery.count, privacy: .public), mediaType=\(requestedMediaType.rawValue, privacy: .public) shuffle=\((requestedShuffle ?? false), privacy: .public)"
        )

        let artistHint = fields.artistHint

        guard let index = loadIndex(), !index.items.isEmpty else {
            logger.debug("resolveMediaItems: index unavailable or empty; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: normalizedQuery,
                mediaType: requestedMediaType,
                artistHint: artistHint,
                shuffle: requestedShuffle
            )
            completion([.success(with: fallback)])
            return
        }

        let ranked = rankCandidates(
            for: normalizedQuery,
            mediaType: requestedMediaType,
            index: index,
            artistHint: artistHint
        )
        guard let top = ranked.first else {
            logger.debug("resolveMediaItems: no ranked match; returning fallback media item")
            let fallback = makeFallbackMediaItem(
                query: normalizedQuery,
                mediaType: requestedMediaType,
                artistHint: artistHint,
                shuffle: requestedShuffle
            )
            completion([.success(with: fallback)])
            return
        }

        let allowDisambiguation = requestedMediaType == .unknown
        if allowDisambiguation && ranked.count > 1 {
            let second = ranked[1]
            if abs(top.score - second.score) <= Self.disambiguationThreshold {
                logger.debug("resolveMediaItems: returning disambiguation with \(ranked.count, privacy: .public) options")
                let options = Array(ranked.prefix(6)).map {
                    makeMediaItem(from: $0, artistHint: artistHint, shuffle: requestedShuffle)
                }
                completion([.disambiguation(with: options)])
                return
            }
        }

        logger.debug("resolveMediaItems: selected top candidate kind=\(top.item.kind.rawValue, privacy: .public)")
        completion([.success(with: makeMediaItem(from: top, artistHint: artistHint, shuffle: requestedShuffle))])
    }

    public func resolvePlayShuffled(
        for intent: INPlayMediaIntent,
        with completion: @escaping (INBooleanResolutionResult) -> Void
    ) {
        if let playShuffled = intent.playShuffled {
            completion(.success(with: playShuffled))
        } else {
            completion(.notRequired())
        }
    }

    // confirm is intentionally NOT implemented. Apple recommends skipping
    // confirm for media intents (WWDC23 session 10238). Implementing it with
    // .ready prevented handle() from being called on HomePod requests, which
    // blocked the system from establishing an AirPlay route back to the
    // requesting device. Without confirm, the flow goes directly to handle()
    // which returns .handleInApp — the signal iOS needs to set up AirPlay.

    public func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let requestedMediaType = resolvedMediaType(
            from: intent,
            query: intent.ensembleSiriPlaybackFields.queryText ?? ""
        )

        guard let payload = payloadIdentifier(from: intent, mediaType: requestedMediaType) else {
            logger.error("handle: missing identifier and query; returning failureUnknownMediaType")
            SiriExtensionLogger.info("SIRI_EXT: handle returning failureUnknownMediaType")
            completion(INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil))
            return
        }

        let shuffleRequested = payload.shuffle
            ?? effectivePlayShuffled(from: intent, mediaType: requestedMediaType)
            ?? false
        SiriExtensionLogger.info(
            "SIRI_EXT: handle ENTRY mediaType=\(requestedMediaType.rawValue) shuffle=\(shuffleRequested)"
        )
        logger.debug("handle: mediaType=\(requestedMediaType.rawValue, privacy: .public) shuffle=\(shuffleRequested, privacy: .public)")

        let playbackPayload: SiriPayloadIdentifier
        if shuffleRequested {
            playbackPayload = payload.updatingShuffle(true)
        } else {
            playbackPayload = payload
        }

        // Do not fail in the extension based on index trackCount metadata.
        // Index data can be stale or partial, so playback viability must be
        // validated in-app by SiriPlaybackCoordinator against live CoreData.

        guard let activity = playbackUserActivity(for: playbackPayload) else {
            logger.error("handle: failed to construct playback user activity")
            SiriExtensionLogger.info("SIRI_EXT: handle returning failure (no activity)")
            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            return
        }

        // Write payload to App Group as fallback in case user activity delivery fails.
        // The app's Darwin notification handler will pick this up if onContinueUserActivity
        // doesn't fire within a few seconds.
        _ = SiriPendingIntentBridge.writePayload(
            playbackPayload,
            filename: Self.pendingFilename,
            logger: logger,
            context: "playback"
        )
        SiriPendingIntentBridge.postDarwinNotification(
            named: Self.darwinNotificationName,
            logger: logger,
            context: "playback"
        )

        // Return .handleInApp — this is the signal iOS needs to establish AirPlay
        // routing from the requesting HomePod before delivering the user activity.
        logger.debug("handle: returning handleInApp for payload kind=\(playbackPayload.kind.rawValue, privacy: .public)")
        SiriExtensionLogger.info("SIRI_EXT: handle returning handleInApp kind=\(playbackPayload.kind.rawValue)")
        completion(INPlayMediaIntentResponse(code: .handleInApp, userActivity: activity))
    }

    private func payloadIdentifier(
        from intent: INPlayMediaIntent,
        mediaType: INMediaItemType
    ) -> SiriPayloadIdentifier? {
        let fields = intent.ensembleSiriPlaybackFields
        let rawIdentifier = fields.normalizedIdentifier

        if let identifier = rawIdentifier,
           let decodedPayload = decodePayloadIdentifier(identifier),
           decodedPayload.schemaVersion == SiriPlaybackRequestPayload.currentSchemaVersion {
            logger.debug("payloadIdentifier: using decoded payload identifier")
            return decodedPayload
        }

        let requestedShuffle = effectivePlayShuffled(from: intent, mediaType: mediaType)

        if let query = fields.queryText {
            let fallbackQuery = bestQueryVariant(from: query) ?? query

            let artistHintForPayload = fields.artistHint
            if let index = loadIndex(),
               let top = rankCandidates(
                    for: fallbackQuery,
                    mediaType: mediaType,
                    index: index,
                    artistHint: artistHintForPayload
               ).first,
               top.score >= Self.payloadResolutionThreshold {
                logger.debug("payloadIdentifier: resolved fallback payload from index top candidate")
                return SiriPayloadIdentifier(
                    kind: top.item.kind,
                    entityID: top.item.id,
                    sourceCompositeKey: top.item.sourceCompositeKey,
                    displayName: top.item.displayName,
                    artistHint: artistHintForPayload,
                    shuffle: requestedShuffle
                )
            }

            logger.debug("payloadIdentifier: building fallback payload from queryLength=\(fallbackQuery.count, privacy: .public)")
            return SiriPayloadIdentifier(
                kind: primaryKindFor(mediaType: mediaType, query: fallbackQuery),
                entityID: fallbackQuery,
                sourceCompositeKey: nil,
                displayName: fallbackQuery,
                artistHint: artistHintForPayload,
                shuffle: requestedShuffle
            )
        }

        if let rawIdentifier {
            logger.debug("payloadIdentifier: falling back to raw media identifier")
            let fallbackKind = primaryKindFor(mediaType: mediaType)
            let fallbackDisplayName = intent.mediaItems?.first?.title
                ?? intent.mediaContainer?.title
                ?? rawIdentifier
            return SiriPayloadIdentifier(
                kind: fallbackKind,
                entityID: rawIdentifier,
                sourceCompositeKey: nil,
                displayName: fallbackDisplayName,
                artistHint: fields.artistHint,
                shuffle: requestedShuffle
            )
        }

        return nil
    }

    private func playbackUserActivity(for payload: SiriPayloadIdentifier) -> NSUserActivity? {
        guard let userInfo = try? SiriPlaybackActivityCodec.makeUserInfo(payload) else {
            return nil
        }

        let activity = NSUserActivity(activityType: SiriPlaybackActivityCodec.activityType)
        activity.title = "Play in Ensemble"
        activity.userInfo = userInfo
        // HomePod requests may need cross-device handoff semantics to wake the iPhone host app.
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPrediction = false
        return activity
    }

    private func rankCandidates(
        for query: String,
        mediaType: INMediaItemType,
        index: SiriMediaIndex,
        artistHint: String? = nil
    ) -> [RankedItem] {
        SiriMediaIndexResolver.rankCandidates(
            for: query,
            requestedKinds: mediaType == .unknown ? nil : kindsFor(mediaType: mediaType),
            index: index,
            artistHint: artistHint
        )
    }

    private func kindsFor(mediaType: INMediaItemType) -> Set<SiriMediaKind> {
        switch mediaType {
        case .song:
            return [.track]
        case .album:
            return [.album]
        case .artist:
            return [.artist]
        case .playlist:
            return [.playlist]
        default:
            return [.track, .album, .artist, .playlist]
        }
    }

    private func makeMediaItem(
        from ranked: RankedItem,
        artistHint: String? = nil,
        shuffle: Bool? = nil
    ) -> INMediaItem {
        let payload = SiriPayloadIdentifier(
            kind: ranked.item.kind,
            entityID: ranked.item.id,
            sourceCompositeKey: ranked.item.sourceCompositeKey,
            displayName: ranked.item.displayName,
            artistHint: artistHint,
            shuffle: shuffle
        )

        let identifier: String
        if let data = try? SiriPlaybackActivityCodec.encode(payload) {
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

    private func makeMediaItem(from payload: SiriPayloadIdentifier, fallback: INMediaItem) -> INMediaItem {
        let identifier: String
        if let data = try? SiriPlaybackActivityCodec.encode(payload) {
            identifier = data.base64EncodedString()
        } else {
            identifier = fallback.identifier ?? ""
        }

        return INMediaItem(
            identifier: identifier,
            title: fallback.title,
            type: fallback.type,
            artwork: fallback.artwork,
            artist: fallback.artist
        )
    }

    private func makeFallbackMediaItem(
        query: String,
        mediaType: INMediaItemType,
        artistHint: String? = nil,
        shuffle: Bool? = nil
    ) -> INMediaItem {
        let fallbackKind = primaryKindFor(mediaType: mediaType, query: query)
        let payload = SiriPayloadIdentifier(
            kind: fallbackKind,
            entityID: query,
            sourceCompositeKey: nil,
            displayName: query,
            artistHint: artistHint,
            shuffle: shuffle
        )

        let identifier: String
        if let data = try? SiriPlaybackActivityCodec.encode(payload) {
            identifier = data.base64EncodedString()
        } else {
            identifier = ""
        }

        return INMediaItem(
            identifier: identifier,
            title: query,
            type: mediaType == .unknown ? mediaTypeFor(kind: fallbackKind) : mediaType,
            artwork: nil
        )
    }

    private func decodePayloadIdentifier(_ identifier: String) -> SiriPayloadIdentifier? {
        guard let data = Data(base64Encoded: identifier) else { return nil }
        return try? SiriPlaybackActivityCodec.decode(from: data)
    }

    private func mediaTypeFor(kind: SiriMediaKind) -> INMediaItemType {
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

    private func primaryKindFor(mediaType: INMediaItemType, query: String? = nil) -> SiriMediaKind {
        switch mediaType {
        case .song:
            return .track
        case .album:
            return .album
        case .artist:
            return .artist
        case .playlist:
            return .playlist
        default:
            if let query, let inferred = SiriMediaIndexResolver.kindInferred(from: query) {
                return inferred
            }
            return .track
        }
    }

    private func effectivePlayShuffled(
        from intent: INPlayMediaIntent,
        mediaType: INMediaItemType
    ) -> Bool? {
        if intent.playShuffled == true {
            return true
        }

        guard SiriPendingPlayMediaContextStore.consumeShuffleIfAvailable(
            mediaType: mediaType,
            logger: logger
        ) else {
            return intent.playShuffled
        }

        return true
    }

    private func mediaType(from intent: INPlayMediaIntent) -> INMediaItemType {
        let searchedType = intent.mediaSearch?.mediaType ?? .unknown
        if searchedType != .unknown {
            return searchedType
        }

        let containerType = intent.mediaContainer?.type ?? .unknown
        if containerType != .unknown {
            return containerType
        }

        let firstMediaItemType = intent.mediaItems?.first?.type ?? .unknown
        if firstMediaItemType != .unknown {
            return firstMediaItemType
        }

        if let mediaSearch = intent.mediaSearch {
            let hasMediaName = mediaSearch.mediaName.map { !$0.isEmpty } ?? false

            // When both mediaName and artistName are present (e.g., "Play Orange County
            // by Gorillaz"), the user wants a specific song/album — not the artist.
            // Return .unknown so rankCandidates searches across all kinds.
            if let artistName = mediaSearch.artistName, !artistName.isEmpty, !hasMediaName {
                return .artist
            }
            if let albumName = mediaSearch.albumName, !albumName.isEmpty, !hasMediaName {
                return .album
            }
        }

        // Return unknown if no specific type can be determined.
        // This allows rankCandidates to search across all kinds.
        return .unknown
    }

    private func resolvedMediaType(from intent: INPlayMediaIntent, query: String) -> INMediaItemType {
        let explicitType = mediaType(from: intent)
        if explicitType != .unknown {
            return explicitType
        }
        return inferMediaType(from: query)
    }

    private func inferMediaType(from query: String) -> INMediaItemType {
        switch SiriMediaIndexResolver.kindInferred(from: query) {
        case .playlist:
            return .playlist
        case .album:
            return .album
        case .artist:
            return .artist
        case .track:
            return .song
        case nil:
            return .unknown
        }
    }

    private func loadIndex() -> SiriMediaIndex? {
        SiriMatchingHelpers.loadIndex()
    }

    private func bestQueryVariant(from raw: String) -> String? {
        SiriPhraseNormalizer.bestQueryVariant(for: raw)
    }
}

// Shared helper types are defined in SiriMatchingHelpers.swift.
