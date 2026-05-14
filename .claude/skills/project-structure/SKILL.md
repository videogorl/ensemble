---
name: project-structure
description: "Load when locating files, adding files, or checking package ownership. Compact map plus discovery commands; use rg for live file lists."
---

# Ensemble Project Structure

This skill is a map, not a full file tree. Use live discovery for exact paths:

```bash
rg --files
rg --files Packages/EnsembleCore
rg --files Packages/EnsembleUI | rg 'NowPlaying|Screens|Components'
```

## Root

| Path | Purpose |
|---|---|
| `Ensemble.xcworkspace` | Main workspace. Use this for Xcode builds. |
| `Ensemble.xcodeproj` | Project file, not the primary entry point. |
| `CLAUDE.md` | Canonical agent operating contract. |
| `AGENTS.md` | Symlink to `CLAUDE.md` for agents that discover AGENTS.md by convention. |
| `.claude/skills/` | Project-specific agent skills. |
| `.claude/hooks/` | Claude hook scripts. |
| `docs/investigations/` | Historical audits, resolved incidents, and closeout notes. |
| `docs/reference/` | Long-form reference material that should not be loaded by default. |
| `scripts/` | Build, test, diagnostics, performance, and Plex probe helpers. |
| `README.md` | User-facing project overview. |
| `VOCABULARY.md` | Canonical UI terminology. |

## App Targets

| Path | Purpose |
|---|---|
| `Ensemble/App/` | App entry point, app delegates, launch pipeline, scene and integration glue. |
| `Ensemble/Resources/` | Assets, app intent vocabulary, SiriKit intent definitions, and app resources. |
| `EnsembleSiriIntentsExtension/` | SiriKit Media Intents extension. Keep extension logic thin. |
| `EnsembleWatch/` | Independent watchOS app target and watch SwiftUI. |
| `EnsembleWatch/Shared/` | Codable iOS/watch payload contracts compiled into both targets. |

## Packages

| Package | Owns | Do not do |
|---|---|---|
| `Packages/EnsembleAPI` | Plex HTTP/auth clients, request builders, API models, connection policy, WebSocket transport. | Do not import UI, CoreData, or app target code. |
| `Packages/EnsemblePersistence` | CoreData stack, managed objects, repositories, downloads/artwork persistence. | Do not put UI or network orchestration here. |
| `Packages/EnsembleSiriShared` | Pure Siri/system-media identity, index models, payload codecs, resolver/ranking logic, phrase normalization/scoring, and App Group constants. | Do not import CoreData, Intents UI, SwiftUI, Spotlight, or playback services. |
| `Packages/EnsembleDomain` | Watch-portable account/media/playback models. | Do not pull in full `EnsembleCore`. |
| `Packages/EnsemblePlex` | Watch-portable Plex facade built on `EnsembleAPI` and `EnsembleDomain`. | Do not duplicate low-level Plex request logic. |
| `Packages/EnsembleWatchCore` | Watch bootstrap, credentials, catalog cache, local playback, local/remote Now Playing state. | Do not link `EnsembleUI` or full iOS playback graph. |
| `Packages/EnsembleCore` | ViewModels, services, domain models, DI, sync/playback/offline/profile logic. | Do not introduce SwiftUI views. |
| `Packages/EnsembleUI` | SwiftUI views, platform UI adapters, reusable components. | Do not place business logic or persistence here. |

## Common Placement

- New ViewModel: `Packages/EnsembleCore/Sources/ViewModels/`
- New Core service: `Packages/EnsembleCore/Sources/Services/`
- New shared Siri/system media identity or resolver logic: `Packages/EnsembleSiriShared/Sources/`
- New SiriKit intent definition resource: `Ensemble/Resources/*.intentdefinition`, then add it to the app and relevant extension target resources in `Ensemble.xcodeproj`.
- New UI screen/component: `Packages/EnsembleUI/Sources/Screens/`, `.../Components/`, `.../NowPlaying/`, or an existing feature folder.
- New CoreData entity: `Packages/EnsemblePersistence/Sources/CoreData/`
- New API endpoint logic: the matching `PlexAPIClient+*.swift` file in `Packages/EnsembleAPI/Sources/Client/`.
- New test: the owning package's `Tests/` directory.
- Long investigation or resolved issue: `docs/investigations/`.
- Long reference inventory: `docs/reference/`.

## Scripts Worth Knowing

| Script | Use |
|---|---|
| `scripts/compile_coredata_model.sh` | Rebuild SwiftPM CoreData model bundle after `.xcdatamodeld` changes. |
| `scripts/verify_package_baseline.sh` | Rebuild model bundle and run package baseline tests. |
| `scripts/check_core_warning_budget.sh` | Keep `EnsembleCore` warnings at or below the current baseline. |
| `scripts/capture_runtime_baseline.sh` | Capture repeatable simulator/runtime log baseline. |
| `scripts/capture_performance_gate.sh` | Capture Instruments performance gates for performance-sensitive changes. |
| `scripts/design_token_audit.sh` | Inventory design-token/raw literal hotspots. |
| `scripts/plex_hls_spike.sh` | Bounded PMS music-HLS viability probe. |
| `scripts/update_build_number.sh` | Deterministic build-number update for app and Siri extension. |

## Current Certified Build Surface

Verified May 13, 2026:
- `Ensemble.xcworkspace` exists.
- Workspace schemes include `Ensemble`, all package schemes, `EnsembleSiriIntentsExtension`, and `EnsembleWatch`.
- `iPhone 17 Pro` is an available simulator destination.
