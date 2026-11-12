import AppIntents
import CoreSpotlight
import EnsembleCore
import EnsembleSiriShared
import Foundation
import MediaPlayer
import _MediaPlayer_AppIntents

// Spotlight entity indexing and the iOS and macOS 27 now-playing relevant entity, shared by iPhone, iPad and Mac.

/// Refreshes what the system reads about the library once the app is up: App Shortcut parameter suggestions, the
/// Siri media context and the shared index Shortcuts pickers read, and Core Spotlight. Runs on every launch on
/// iPhone, iPad and Mac, since a library that has not changed since the last launch never signals a refresh.
/// Returns whether it ran: false when foreground work was unavailable, so the launch gate can retry it.
@MainActor
@discardableResult
func refreshSystemMediaSurfaces() async -> Bool {
    let container = AppRoot.container
    guard await container.foregroundWorkScheduler.waitUntilAllowed(.systemMediaIndexing, policy: .idleOnly) else {
        AppLogger.debug("SIRI_SHORTCUT: system media refresh skipped because foreground work is unavailable")
        container.systemMediaIntegrationService.deferSpotlightRefresh()
        return false
    }
    AppLogger.info("LAUNCH_WORK: Siri/Spotlight refresh starting")
    EnsembleAppShortcutsProvider.updateAppShortcutParameters()
    AppLogger.debug("SIRI_SHORTCUT: refreshed App Shortcuts parameter metadata")
    await container.systemMediaIntegrationService.updateMediaUserContext()
    await container.systemMediaIntegrationService.refreshSpotlightIndex()
    return true
}

@available(iOS 18.0, *)
extension EnsembleMediaEntity: IndexedEntity {}

@available(iOS 27.0, macOS 27.0, *)
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

/// Siri resolves "this song" from the identifiers in the now-playing info, which must name the schema song entity so
/// `entities(for:)` hydrates it. Installed by every launch that can play (a scene, or an intent or Siri hand-off with
/// none), and only once.
@MainActor
func installNowPlayingEntityIdentifiers() {
    guard #available(iOS 27.0, macOS 27.0, *), !didInstallNowPlayingEntityIdentifiers else { return }
    didInstallNowPlayingEntityIdentifiers = true
    AppRoot.container.playbackService.setNowPlayingAppEntityIdentifiers { track in
        guard #available(iOS 27.0, macOS 27.0, *) else { return [] }
        let entity = EnsembleSongAudioEntity(item: SiriMediaIndexItem(track: track))
        return MPAppEntityIdentifier(entityIdentifier: EntityIdentifier(for: entity)).map { [$0] } ?? []
    }
}

@MainActor private var didInstallNowPlayingEntityIdentifiers = false

/// Publishes the playing song as a relevant entity so the system can offer actions on it.
@available(iOS 27.0, macOS 27.0, *)
@MainActor
final class EnsembleRelevantEntitiesPublisher {
    static let shared = EnsembleRelevantEntitiesPublisher()

    private var observationTask: Task<Void, Never>?
    private var publishedTrackID: String?

    private init() {}

    func start() {
        guard observationTask == nil else { return }

        installNowPlayingEntityIdentifiers()

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
