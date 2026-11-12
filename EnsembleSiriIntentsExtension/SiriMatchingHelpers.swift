import EnsembleSiriShared
import Foundation
import Intents
import OSLog

typealias RankedItem = SiriMediaIndexResolver.RankedItem
typealias SiriPayloadIdentifier = SiriPlaybackRequestPayload

struct SiriPendingPlayMediaContext: Codable {
    let shuffle: Bool
    let mediaTypeRawValue: Int
    let expiresAt: Date
}

// MARK: - Shared helpers

enum SiriMatchingHelpers {
    static let appGroupIdentifier = SiriSharedConstants.appGroupIdentifier
    static let indexFilename = SiriSharedConstants.indexFilename

    static func loadIndex() -> SiriMediaIndex? {
        SiriMediaIndexResolver.loadIndex(
            appGroupIdentifier: appGroupIdentifier,
            filename: indexFilename
        )
    }

    static func currentTrackMediaItem() -> INMediaItem {
        INMediaItem(
            identifier: "current-track",
            title: "Current Track",
            type: .song,
            artwork: nil
        )
    }

    /// Within this score gap, a playlist competes with the best candidate.
    static let playlistTieMargin = 0.1

    /// Playlists as the app's playlist screen shows them (merge setting, hidden sources); see
    /// `SiriPlaylistRows.presented(_:index:presentation:tieMargin:)`. Nil means the app has not published a
    /// presentation for this index and a playlist is among the best candidates: the caller defers to the app by name.
    static func presented(_ ranked: [RankedItem], index: SiriMediaIndex) -> [RankedItem]? {
        SiriPlaylistRows.presented(
            ranked, index: index, presentation: SiriPlaylistPresentation.load(), tieMargin: playlistTieMargin
        )
    }

    /// Voice Add's answer for a spoken playlist name against the published presentation, left on the trail the app
    /// logs (codes and counts only).
    static func resolveVoiceAdd(
        named name: String,
        in index: SiriMediaIndex,
        event: String
    ) -> SiriPlaylistRows.VoiceAddResolution {
        let presentation = SiriPlaylistPresentation.load()
        let resolution = SiriPlaylistRows.resolveVoiceAdd(named: name, in: index, presentation: presentation)
        let state = presentation.map { $0.covers(index) ? "covers" : "stale" } ?? "missing"
        let outcome: String
        var counts = [
            "indexPlaylists": SiriMediaIndexResolver.items(in: index, kind: .playlist).count,
            "nameLength": name.count
        ]
        switch resolution {
        case .deferToApp: outcome = "deferToApp"
        case .chosen: outcome = "chosen"
        case let .choices(options): outcome = "choices"; counts["choices"] = options.count
        case .notFound: outcome = "notFound"
        }
        counts["offered"] = SiriPlaylistRows.voiceAddDestinations(in: index, presentation: presentation)?.count
        record(event, "\(outcome) presentation=\(state)", counts)
        return resolution
    }

    static func record(_ event: String, _ outcome: String, _ counts: [String: Int] = [:]) {
        SiriExtensionBreadcrumbs.record(SiriExtensionBreadcrumb(event: event, outcome: outcome, counts: counts))
    }
}

enum SiriPendingPlayMediaContextStore {
    private static let filename = "siri-pending-playmedia-context.json"
    private static let ttl: TimeInterval = 30

    static func recordShuffleRequest(mediaType: INMediaItemType, logger: Logger) {
        let context = SiriPendingPlayMediaContext(
            shuffle: true,
            mediaTypeRawValue: mediaType.rawValue,
            expiresAt: Date().addingTimeInterval(ttl)
        )
        _ = SiriPendingIntentBridge.writePayload(
            context,
            filename: filename,
            logger: logger,
            context: "playmedia-context"
        )
    }

    static func consumeShuffleIfAvailable(mediaType: INMediaItemType, logger: Logger) -> Bool {
        guard let fileURL = contextURL(),
              let data = try? Data(contentsOf: fileURL),
              let context = try? JSONDecoder().decode(SiriPendingPlayMediaContext.self, from: data) else {
            return false
        }

        defer { try? FileManager.default.removeItem(at: fileURL) }

        guard context.expiresAt >= Date(), context.shuffle else {
            logger.debug("playmedia-context: pending shuffle context expired")
            return false
        }

        guard mediaTypesAreCompatible(
            pending: INMediaItemType(rawValue: context.mediaTypeRawValue) ?? .unknown,
            current: mediaType
        ) else {
            logger.debug("playmedia-context: pending shuffle context ignored for mediaType=\(mediaType.rawValue, privacy: .public)")
            return false
        }

        logger.info("playmedia-context: applying pending shuffle to follow-up mediaType=\(mediaType.rawValue, privacy: .public)")
        return true
    }

    private static func contextURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: SiriMatchingHelpers.appGroupIdentifier)?
            .appendingPathComponent(filename)
    }

    private static func mediaTypesAreCompatible(
        pending: INMediaItemType,
        current: INMediaItemType
    ) -> Bool {
        guard current != .song else { return false }
        if pending == .unknown || current == .unknown {
            return true
        }
        return pending == current
    }
}

enum SiriPendingIntentBridge {
    static func writePayload<T: Encodable>(
        _ payload: T,
        filename: String,
        logger: Logger,
        context: String
    ) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SiriMatchingHelpers.appGroupIdentifier
        ) else {
            logger.error("\(context, privacy: .public): App Group container unavailable")
            return false
        }

        let fileURL = containerURL.appendingPathComponent(filename)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            logger.info("\(context, privacy: .public): wrote pending payload file=\(fileURL.lastPathComponent, privacy: .public)")
            return true
        } catch {
            logger.error("\(context, privacy: .public): failed to write pending payload: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func postDarwinNotification(
        named notificationName: String,
        logger: Logger,
        context: String
    ) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
        logger.info("\(context, privacy: .public): posted Darwin notification")
    }
}
