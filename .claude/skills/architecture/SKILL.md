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
Shared: EnsembleSiriShared
Watch: EnsembleDomain + EnsemblePlex + EnsembleWatchCore
```

Dependency flow is one-way:

- UI depends on Core.
- Core depends on API, Persistence, SiriShared, and Nuke.
- API and Persistence do not depend on Core or UI.
- Watch packages stay portable and do not import full `EnsembleCore` or `EnsembleUI`.

## Package Ownership

| Package | Canonical ownership |
|---|---|
| `EnsembleAPI` | Plex auth, request building, API models, transport, connection policy, WebSocket transport, endpoint grouping. |
| `EnsemblePersistence` | CoreData model/stack, repositories, download/artwork persistence, SwiftPM compiled model bundle. |
| `EnsembleSiriShared` | Pure Siri phrase normalization/scoring, query variants, App Group constants. |
| `EnsembleDomain` | Watch-portable account, media, category, and playback-status models. |
| `EnsemblePlex` | Watch-portable Plex discovery/catalog/detail/stream facade using `EnsembleAPI`. |
| `EnsembleWatchCore` | Watch bootstrap, Plex Link fallback, credential restore, KVS hints, catalog cache, local playback, local/remote Now Playing target state. |
| `EnsembleCore` | ViewModels, services, DI, domain models, sync, playback, offline downloads, metadata mutations, profile/cloud, navigation state. |
| `EnsembleUI` | SwiftUI views/components, platform UI adapters, native table/menu/share/AirPlay/Metal/toast bridges. |

## Core Ownership Rules

- `DependencyContainer` wires services and ViewModel factories. Keep construction grouped by subsystem bootstrap helpers and cross-subsystem callback wiring in explicit post-construction helpers.
- `SyncCoordinator` is the sync facade. Keep provider lookup, refresh orchestration, playlist refresh, network lifecycle, and endpoint synchronization in focused collaborators instead of growing the facade.
- `PlaybackService` is the playback facade. Queue mutation and transport side effects stay there; audio session, queue persistence, launch/recovery policy, file cache, prefetch, now-playing metadata, reporting, settings observation, and transport resolution belong in focused collaborators.
- `OfflineDownloadService` remains the target/queue source of truth. Platform events route through the offline background coordinator, not directly from app delegates into queue workers.
- `NavigationCoordinator` is scene/window-scoped for user navigation. Do not route user-driven navigation through a shared singleton coordinator that would mirror iPad/macOS windows.
- Shared workflows own cross-screen business rules: playlist mutation, metadata mutation, pin mutation, download mutation, drag/drop playlist resolution, track actions, media filtering, and Siri playback execution.

## UI Ownership Rules

- Root shells own platform navigation: tab shell on iPhone, split/sidebar shell on iPad/macOS where supported.
- Persistent list/detail surfaces should observe focused projections or local state snapshots, not broad high-frequency singleton objects.
- Keep native platform owners for behavior SwiftUI does not expose: UIKit/AppKit track tables, AirPlay picker, Metal aurora, global toast window, native share/menu hosts, iOS 15 tab/mini-player bridges.
- Treat new safe-area compensation, delayed layout tasks, custom scroll detectors, and root-chrome mutation as suspect until a current simulator/macOS repro proves native behavior is broken.
- Now Playing panel additions must update the shared iPhone carousel and wide detail panel. External display stays a shell around the shared wide layout.

## Data And Sync Rules

- Domain model separation matters:
  - `Plex*` API models live in `EnsembleAPI`.
  - `CD*` models live in `EnsemblePersistence`.
  - UI-facing domain models live in `EnsembleCore`.
- Source identity must include account/server/library scope where applicable. Plex library section keys are per-server integers and are not globally unique.
- Feed and library surfaces should use stale-while-revalidate behavior: show cached/last-good data first, then refresh in background.
- Empty or failed network results must not overwrite last-good Feed snapshots.
- Destructive source cleanup belongs in `SourceCacheCleanupService` or the relevant persistence/offline owner, not in UI ViewModels.

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
