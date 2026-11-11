#if os(iOS)
import AppIntents
import CoreSpotlight
import EnsembleCore
import EnsembleSiriShared
import Foundation

// Core Spotlight and iOS 27 relevant-entity publishing. Mac gets these in the Mac phase.

@available(iOS 18.0, *)
extension EnsembleMediaEntity: IndexedEntity {}

@available(iOS 27.0, *)
extension EnsembleMediaEntityQuery: IndexedEntityQuery {
    func reindexEntities(
        for identifiers: [EnsembleMediaEntity.ID],
        indexDescription _: CSSearchableIndexDescription
    ) async throws {
        guard !identifiers.isEmpty else { return }
        await AppRoot.container.systemMediaIntegrationService.refreshSpotlightIndex()
    }

    func reindexAllEntities(indexDescription _: CSSearchableIndexDescription) async throws {
        await AppRoot.container.systemMediaIntegrationService.refreshSpotlightIndex()
    }
}

/// Publishes the playing song as a relevant entity so the system can offer actions on it.
@available(iOS 27.0, *)
@MainActor
final class EnsembleRelevantEntitiesPublisher {
    static let shared = EnsembleRelevantEntitiesPublisher()

    private var observationTask: Task<Void, Never>?
    private var publishedTrackID: String?

    private init() {}

    func start() {
        guard observationTask == nil else { return }

        observationTask = Task { @MainActor in
            for await track in AppRoot.container.playbackService.snapshots(\.currentTrack) {
                guard !Task.isCancelled else { return }
                await publish(track)
            }
        }
    }

    private func publish(_ track: Track?) async {
        let nextID = track?.sourceScopedID
        guard nextID != publishedTrackID else { return }

        do {
            if let track {
                try await RelevantEntities.shared.updateEntities(
                    [EnsembleMediaEntity(item: SiriMediaIndexItem(track: track))],
                    for: .audio(.nowPlaying)
                )
            } else {
                try await RelevantEntities.shared.removeAllEntities(for: .audio(.nowPlaying))
            }
            publishedTrackID = nextID
            AppIntentsLog.logger.debug(
                "SIRI_SHORTCUT: updated now-playing relevant entity present=\(track != nil, privacy: .public)"
            )
        } catch {
            AppIntentsLog.logger.error(
                "SIRI_SHORTCUT: now-playing relevant entity update failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
#endif
