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
| `.claude/skills/` | Project-specific agent skills, including `app-policies` for canonical app behavior policy. |
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
| `EnsembleUITests/` | App UI smoke and regression tests launched by the `Ensemble` scheme. |
| `EnsembleSiriIntentsExtension/` | SiriKit Media Intents extension. Keep extension logic thin. |
| `EnsembleWatch/` | Independent watchOS app target and watch SwiftUI. |
| `EnsembleWatch/EnsembleWatch.entitlements` | Watch access to the iPhone app's synchronizable Plex credential Keychain group. |
| `EnsembleWatch/Shared/` | Codable iOS/watch payload contracts compiled into both targets. |

## Packages

| Package | Owns | Do not do |
|---|---|---|
| `Packages/EnsembleSupport` | Low-level shared Foundation utilities used across packages and app targets, including privacy-safe log redaction and audio payload validation. | Do not put app behavior, UI, persistence, network clients, or platform service orchestration here. |
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
- New playback source/transport/streaming decoder contract: `Packages/EnsembleCore/Sources/Services/`
- New playback planner/analysis service: `Packages/EnsembleCore/Sources/Services/`
- Shared artwork wash renderer/cache: `Packages/EnsembleCore/Sources/Services/ArtworkBlurRenderer.swift`
- Shared Foundation-only utility: `Packages/EnsembleSupport/Sources/`
- New shared Siri/system media identity or resolver logic: `Packages/EnsembleSiriShared/Sources/`
- Portable-link recipient matching: `Packages/EnsembleCore/Sources/Services/EnsemblePermalinkResolver.swift`; song-to-album navigation loading: `Packages/EnsembleUI/Sources/Screens/Details/SongPermalinkLoader.swift`.
- New SiriKit intent definition resource: `Ensemble/Resources/*.intentdefinition`, then add it to the app and relevant extension target resources in `Ensemble.xcodeproj`.
- New UI screen/component: `Packages/EnsembleUI/Sources/Screens/`, `.../Components/`, `.../NowPlaying/`, or an existing feature folder.
- Root scene layering, chrome geometry registration, and mini-player overlay helpers live in `Packages/EnsembleUI/Sources/Screens/Root/`.
- Library item Get Info UI lives in `Packages/EnsembleUI/Sources/Screens/Library/`; its request model lives in `Packages/EnsembleCore/Sources/Models/` and its ViewModel in `Packages/EnsembleCore/Sources/ViewModels/`.
- New CoreData entity: `Packages/EnsemblePersistence/Sources/CoreData/`
- New CoreData repository: `Packages/EnsemblePersistence/Sources/Repositories/`
- New API endpoint logic: the matching `PlexAPIClient+*.swift` file in `Packages/EnsembleAPI/Sources/Client/`.
- New test: the owning package's `Tests/` directory.
- New app UI test: `EnsembleUITests/`.
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
| `ci_scripts/test_ci_post_xcodebuild.sh` | Verify repeated Xcode Cloud tag creation remains idempotent. |

## Current Certified Build Surface

Verified May 13, 2026:
- `Ensemble.xcworkspace` exists.
- Workspace schemes include `Ensemble`, all package schemes, `EnsembleSiriIntentsExtension`, and `EnsembleWatch`.
- `iPhone 17 Pro` is an available simulator destination.
