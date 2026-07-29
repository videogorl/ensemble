---
name: architecture
description: "Load before designing features, adding services, or touching multiple packages. Compact ownership, dependency, and subsystem rules for Ensemble."
---

# Ensemble Architecture

This is the canonical operating map. A long historical inventory was archived to `docs/reference/architecture-inventory.md`; load it only when a detailed subsystem inventory is useful.

## Layers

```
Layer 3: EnsembleUI
Layer 2: EnsembleCore
Layer 1: EnsembleAPI + EnsemblePersistence
Layer 0: EnsembleSupport
Shared: EnsembleSiriShared
Watch: EnsembleDomain + EnsemblePlex + EnsembleWatchCore
```

Dependency flow is one-way:

- UI depends on Core.
- Core depends on API, Persistence, SiriShared, and Nuke.
- API and Persistence do not depend on Core or UI.
- API, Persistence, Core, UI, SiriShared, app targets, and watch packages may depend on EnsembleSupport for pure Foundation utilities.
- Watch packages stay portable and do not import full `EnsembleCore` or `EnsembleUI`.

## Package Ownership

| Package | Canonical ownership |
|---|---|
| `EnsembleSupport` | Pure Foundation shared utilities with no app behavior ownership, currently including privacy-safe log redaction and audio payload validation. |
| `EnsembleAPI` | Plex auth, request building, API models, transport, connection policy, WebSocket transport, endpoint grouping. |
| `EnsemblePersistence` | CoreData model/stack, repositories, download/artwork persistence, SwiftPM compiled model bundle. |
| `EnsembleSiriShared` | Pure Siri/system-media identity, index models, payload codecs, phrase normalization/scoring, query variants, resolver logic, App Group constants. |
| `EnsembleDomain` | Watch-portable account, media, category, and playback-status models. |
| `EnsemblePlex` | Watch-portable Plex discovery/catalog/detail/stream facade using `EnsembleAPI`. |
| `EnsembleWatchCore` | Watch bootstrap, Plex Link fallback, credential restore, KVS hints, catalog cache, local playback, local/remote Now Playing target state. |
| `EnsembleCore` | ViewModels, services, DI, domain models, sync, playback, offline downloads, metadata mutations, profile/cloud, navigation state. |
| `EnsembleUI` | SwiftUI views/components, platform UI adapters, native table/menu/share/AirPlay/Metal/toast bridges. |

## Core Ownership Rules

- `DependencyContainer` wires services and ViewModel factories. Keep construction grouped by subsystem bootstrap helpers and cross-subsystem callback wiring in explicit post-construction helpers.
- `AppReadinessCoordinator` owns UI-safe launch/source/cache readiness snapshots. Browse ViewModels consume those snapshots instead of independently deriving add-source or empty states from transient account arrays, and library browse screens consume committed `LibraryBrowseSnapshot` values instead of raw arrays that may be empty mid-refresh.
- Plex credentials remain Keychain-owned, but macOS startup hydration must use `AccountManager.loadAccountsAsync()` so Keychain Services cannot block SwiftUI scene construction. The non-secret Plex client identifier is `PlexAuthService`-owned and persisted in `UserDefaults`, not Keychain.
- iOS 18 Apple Music integration stays inside `EnsembleCore`: `AppleMusicSourceProvider` owns MusicKit API sync/mutations, `AppleMusicCatalogSearch` owns live catalog mapping, and `AppleMusicPlaybackController` adapts `ApplicationMusicPlayer` beneath the existing `PlaybackService` queue facade. `MusicSourceCapabilities` is the provider-normalized UI/action contract, while `AccountManager.sourcePresentation(for:)` resolves configured server, library, and account names; shared UI must consume those values instead of branching on Apple Music. The source enablement is device-local and never joins Plex credential/iCloud sync.
- UI-owned Core Data contexts must not be reset during refresh or sync. Background saves merge automatically; repository refresh hooks may drain pending changes, while fetches map managed objects to value types before crossing context boundaries.
- `ForegroundWorkScheduler` owns foreground interaction budgeting for nonessential CPU/file work. Services route SmartMix analysis, sidecar analysis, offline healing, system media indexing, artwork retries, log export preparation, and expensive progress recomputation through it without making it an app-state singleton.
- `SyncCoordinator` is the sync facade. Keep provider lookup, refresh orchestration, playlist refresh, network lifecycle, and endpoint synchronization in focused collaborators instead of growing the facade.
- `MusicSourceSyncProvider` owns library/playlist synchronization and Feed/artwork loading. Playback resolution/reporting, ratings, online playlist mutations, collection details, file metadata, lyrics, and radio are opt-in `MusicSource*` capability protocols; shared controllers require the exact source provider and never substitute a different provider when a capability is unavailable.
- Legacy media without a source key may be repaired only when an exact source-scoped cache lookup yields one unique owner. Never infer ownership from the sole configured provider or selected playlist target.
- `PlaybackService` is the playback facade and holds the single live queue state. Queue commands and transport side effects enter through it; `PlaybackQueueController` receives queue values for focused transformations and persistence coordination but must not retain or publish a second live queue. Audio session, queue storage, launch/recovery policy, file cache, prefetch, now-playing metadata, reporting, settings observation, system-media donations, and transport resolution belong in focused collaborators.
- `OfflineDownloadService` remains the target/queue source of truth. Platform events route through the offline background coordinator, not directly from app delegates into queue workers.
- `NavigationCoordinator` is scene/window-scoped for user navigation. Do not route user-driven navigation through a shared singleton coordinator that would mirror iPad/macOS windows.
- Shared workflows own cross-screen business rules: playlist mutation, metadata mutation, pin mutation, download mutation, drag/drop playlist resolution, track actions, media filtering, and Siri playback execution.

## System Media Integration Rules

- `PlaybackNowPlayingBridge` owns app writes to `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`. Keep MediaPlayer singleton mutation out of `PlaybackService`, engines, ViewModels, and UI.
- `SystemMediaIntegrationService` owns user-initiated playback donations, Core Spotlight indexing/deletion, and media user context refresh. Playback callers pass `PlaybackStartContext`; Siri, App Shortcuts, remote commands, autoplay, restoration, and background recovery must not donate starts.
- `EnsembleSiriShared.SiriMediaIndexResolver` is the shared resolver for SiriKit, App Shortcuts, and Spotlight-backed media identity. Do not duplicate query normalization, kind inference, source matching, ranking, or playlist lookup in the app target or Siri extension.
- `EnsembleSiriShared.EnsemblePermalink` owns the versioned library-independent URL payload. `EnsemblePermalinkResolver` resolves it against enabled local repositories and returns typed `NavigationCoordinator` destinations; permalink opening must not enter playback services.
- App Group Siri index schema must remain backward compatible. Add optional fields for new system surfaces, and allow old files to decode until the next rebuild overwrites them.
- Core Spotlight deletion must stay source/domain scoped. Do not call global Spotlight delete APIs for Ensemble media.

## UI Ownership Rules

- Root shells own platform navigation: tab shell on iPhone, split/sidebar shell on iPad/macOS where supported.
- Persistent list/detail surfaces should observe focused projections or local state snapshots, not broad high-frequency singleton objects.
- Keep native platform owners for behavior SwiftUI does not expose: UIKit/AppKit track tables, AirPlay picker, Metal aurora, global toast window, native share/menu hosts, iOS 15 tab/mini-player bridges.
- Treat new safe-area compensation, delayed layout tasks, custom scroll detectors, leaf-level navigation-bar hiding, and root-chrome mutation as suspect until a current simulator/macOS repro proves native behavior is broken.
- Now Playing panel additions must update the shared iPhone carousel and wide detail panel. External display stays a shell around the shared wide layout.

## Data And Sync Rules

- Domain model separation matters:
  - `Plex*` API models live in `EnsembleAPI`.
  - `CD*` models live in `EnsemblePersistence`.
  - UI-facing domain models live in `EnsembleCore`.
- `EnsembleCore.MediaSourceIdentity` owns strict provider/account/server/library source-key parsing and scope comparison for the app. Provider item and hub IDs are not source keys and must not be truncated through this parser.
- `EnsembleAPI.PlexPlaylistMergeRules` owns playlist merge identity, stable grouping, and round-robin interleaving for both app clients; platform models and loading remain client-owned.
- Source identity must include account/server/library scope where applicable. Plex library section keys are per-server integers and are not globally unique.
- Feed and library surfaces should use stale-while-revalidate behavior: show cached/last-good committed snapshots first, then refresh in background.
- Every `MusicSourceSyncProvider` maps its service's history/library data into normalized `Hub` values through `getHomeHubs(limit:)`, including explicit `HubSemanticKind`, `HubSourceScope`, and ranking metadata. `HomeHubLoader` collects all configured providers and owns combined Feed hub identity, cross-provider merging, global order application, failed-provider last-good retention, and persistence without parsing provider hub IDs or titles for merge semantics. Hub persistence stores the explicit kind, scope, and ranking fields so opaque future-provider semantics and global ordering survive cache reload; only legacy rows with no normalized fields use compatibility inference. `HubOrderManager` persists the resulting snapshot order. Search consumes the saved combined snapshot instead of fetching or persisting hubs itself.
- Empty or failed network results must not overwrite last-good Feed snapshots.
- Durable server-playlist sync state belongs in `SyncCursorRepository`/`CDSyncCursor`. Playlist sync triggers should ask or update this scoped state instead of adding new independent timestamp flags.
- Destructive source cleanup belongs in `SourceCacheCleanupService` or the relevant persistence/offline owner, not in UI ViewModels. It removes source-owned Feed items as well as library/offline rows and that source's durable artwork. Shared bounded rendering caches are disposable and may be cleared globally, but persistent artwork identity and deletion stay source-scoped.

## Playback And Plex Rules

- Stream routing uses endpoint-independent decisions followed by endpoint-specific assembly.
- Direct file streams and universal transcode can both be valid. Test live PMS endpoints before changing transport policy.
- Universal transcode decision must be called before `start.mp3`.
- Transcode endpoints override Plex platform metadata to `iOS` where required by PMS behavior; general headers may still report the real platform.
- Keep timeline/scrobble reporting source-exact; do not fall back across Plex source boundaries.

## Watch Rules

- The watch target is an independent lightweight Plex client plus optional iPhone remote.
- Watch SwiftUI lives under `EnsembleWatch/Views/`.
- Watch runtime logic belongs in `EnsembleWatchCore`, portable Plex access in `EnsemblePlex`, and portable models in `EnsembleDomain`.
- Downloads are not part of the first standalone watch pass; add them later with watch-specific storage/execution.

## When To Update This Skill

Update this skill only for new architecture rules, package ownership changes, service boundaries, or major patterns. Do not turn it back into a full file/type inventory; use `project-structure`, `rg`, source reads, and `docs/reference/architecture-inventory.md` for details.
