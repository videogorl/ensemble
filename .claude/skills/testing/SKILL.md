---
name: testing
description: "Load before writing tests, after non-trivial code changes, or when deciding verification scope. Canonical definition of done for Ensemble."
---

# Ensemble Testing Guide

This is the canonical verification policy. Other skills may add task-specific details, but they should not redefine done.

## Verification Matrix

| Change | Required verification |
|---|---|
| Docs or agent-guidance only | Syntax/link sanity checks relevant to the edited files. No Swift tests required unless commands/scripts changed. |
| Shell/script/tooling change | `bash -n` or equivalent static check, plus a safe dry run or targeted execution. |
| Package business logic | Affected package tests with `swift test --package-path Packages/<Package>`. |
| CoreData model/repository | `scripts/compile_coredata_model.sh`, `swift test --package-path Packages/EnsemblePersistence`, and dependent package tests as needed. |
| UI, navigation, playback, sync workflow, or user-visible bug fix | Affected package tests plus visual runtime validation of the changed flow on each touched platform when feasible. Navigate to the changed surface and exercise the changed behavior; launching the app, landing on the default tab, or checking an unrelated screen is not sufficient. Capture screenshots or equivalent UI inspection evidence; if visual validation is blocked, document the blocker and residual risk. |
| Performance-sensitive SwiftUI/playback/download change | Targeted tests plus simulator/device evidence. Use `scripts/capture_performance_gate.sh` when changing observation, root chrome, Feed launch/refresh, or Downloads queue behavior. |
| Multi-source/provider integration | Affected package and persistence tests, simulator proof for normalized cached UI, and a physical iPhone/iPad for authorization, DRM playback, system-player state, AirPlay, or live provider mutations. Exercise each provider alone and at least one merged result or mixed-source entry path. |
| Broad architectural refactor | Tests for new services/repositories, affected package tests, app build, and simulator verification for user-facing paths. |

Every completed turn with code, UI, behavior, script, or policy changes needs targeted verification before handoff. Select the smallest verification that proves the changed contract, but make it specific to the changed area. For example, after fixing Albums on iOS, build/run the iOS app and navigate to Albums to verify the Albums behavior itself; a Feed launch screenshot does not verify an Albums change.

If runtime verification is blocked by credentials, third-party service availability, simulator state, or an external dependency, report the blocker precisely and do not present the task as fully verified.

Provider work is not complete when only the new provider succeeds. Re-run a representative existing-provider path, then test the normalized or merged path. When playback engines differ, verify queue construction, mutation, restoration, autoplay, background transition, and Now Playing state with both possible starting engines. When source lifecycle changes, verify add, usable-while-syncing behavior, refresh, disable/remove, cached-data cleanup, and re-add.

## Plex Mutation Convergence

For Plex sync, downloaded-playlist, or deletion cleanup changes, automated coverage and live PMS proof have different jobs. Keep the automated suite focused on the contracts below; use the explicitly authorized live extension in [physical-download-sweep.md](../surface-sweep/references/physical-download-sweep.md) for end-to-end server mutation timing and file evidence.

Automated regression ownership:

| Contract | Primary tests |
|---|---|
| Exact WebSocket changes, metadata comparison, and parent/child refresh selection | `PlexWebSocketCoordinatorTests`, `PlexMusicSourceSyncProviderTests` |
| Cold-start and missed-event authoritative reconciliation | `SyncCoordinatorStartupRepairTests`, `BackgroundRefreshCoordinatorTests` |
| Complete paged inventory before deletion; failed, malformed, or premature-empty inventory preserves last-good data | `PlexAPIClientTests`, `PlexMusicSourceSyncProviderTests` |
| Downloaded-playlist cadence survives WebSocket relaxation, polls only distinct Plex target servers, and does not force playlist orphan inventory | `PeriodicSyncControllerTests`, `PlaylistRefreshControllerTests`, `OfflineDownloadServicePolicyTests` |
| Playlist membership add/remove reconciliation, shared-reference preservation, and final-reference eviction | `DownloadTargetReconcilerTests`, `OfflineDownloadCleanupCoordinatorTests` |
| Authoritative track removal clears only exact source-scoped audio, frequency, lyric, and chord artifacts | `OfflineDownloadServicePolicyTests` |
| Background expiration keeps one queue owner, one completion, and the requested quality | `DownloadQueueCoordinatorTests`, `OfflineDownloadServicePolicyTests`, `DownloadTransferExecutorTests` |
| Missing lyrics do not retry-storm; durable outcomes remain signature-scoped | `LyricsServiceTests`, `DownloadTransferExecutorTests` |

Live acceptance matrix, using a uniquely named disposable Plex fixture and exact installed-build proof:

- Foreground add: new artist, album, and tracks appear without duplicates.
- Foreground metadata edits: track and album names converge on browse, detail, search, playlist, and denormalized child rows without relaunch.
- Cold start: changes made while Ensemble is terminated converge after launch without a manual refresh.
- Downloaded playlist: externally add, remove, and re-add a track while Ensemble stays foreground. Within one target-poll interval plus transfer time, membership, target counts, download rows, audio, frequency, lyrics, and chords must match Plex.
- Track removal: deleting a downloaded fixture track from Plex removes its database row and exact offline artifacts while retaining an unaffected track and any still-referenced artifacts.
- Failure safety: unavailable, failed, malformed, partial, or inconsistent inventory must preserve last-good rows and files. Test this with stubs; do not destabilize the live server to manufacture the failure.
- Efficiency: an unchanged downloaded-playlist poll is server-targeted, does not run full library inventory, recache artwork, or reconcile targets, and does not suppress the ordinary low-frequency library timer.
- Lifecycle: around background expiration and relaunch, correlate track ID and queue item ID to prove exactly one durable completion and unchanged requested quality; a final empty queue is insufficient evidence.
- Diagnostics: missing-lyrics requests do not repeat for the same signature, logs redact tokens and server filesystem paths, thermal state is recorded, and work returns to idle.

Record Plex response state, wall-clock mutation/convergence times, source composite keys/rating keys, app database rows, local artifact paths, narrow logs, visible UI, and cleanup. Remove only fixtures created for the run and verify both Plex and Ensemble return to baseline.

## When To Write Tests

Required for:
- New services, repositories, sync flows, playback policies, or mutation workflows.
- CoreData model changes and persistence round-trips.
- Playlist mutations, download reconciliation, source cleanup, and complex domain transformations.
- Bug fixes where a small unit test can preserve the regression.

Usually not required for:
- Pure UI layout-only changes.
- Simple pass-through ViewModels.
- Trivial one-liners with low regression risk.

For a major architectural feature, test each public service/repository behavior that future refactors could silently break.

## Commands

```bash
# Affected package examples
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleSupport
swift test --package-path Packages/EnsembleDomain
swift test --package-path Packages/EnsemblePlex
swift test --package-path Packages/EnsembleWatchCore
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
swift test --package-path Packages/EnsembleSiriShared

# Core warning budget for Core refactors
scripts/check_core_warning_budget.sh

# Full app tests
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Do not pass `-sdk iphonesimulator` when building the full app scheme. The scheme embeds a watchOS target, and a global SDK override can make Xcode link iOS Simulator Swift-package objects into the Watch app. The iPhone destination selects iOS while preserving `watchsimulator` for the embedded target.

## Simulator Verification

Load `simulator-test` when runtime proof is required. Use the iOS Simulator MCP server to install, launch, inspect accessibility output, drive taps/typing/swipes, and capture screenshots/logs.

Typical expectations:
- Bug fix: reproduce the old path when feasible, then verify the corrected path visually.
- New UI or UI fix: navigate to the affected surface, exercise the specific changed interaction/state, including representative row swipe actions when the surface exposes swipeable rows, and confirm visible labels/state with screenshots or accessibility/UI hierarchy evidence.
- Playback/networking: combine UI interaction with focused log capture.

For macOS-visible UI changes, use the built app with Computer Use, Xcode UI tooling, screenshots, or another direct UI inspection path. A build-only check is not sufficient unless the changed surface cannot be reached because of a documented environment blocker such as missing credentials, unavailable data, or a locked desktop.

The simulator cannot prove Apple Music subscription authorization, DRM playback, system Now Playing behavior, live Apple library mutations, or AirPlay. Use it for cached-data layout and navigation, then load the physical-device section of `simulator-test` for those contracts.

## Test Locations

Each package owns tests beside its sources:

```text
Packages/EnsembleAPI/Tests/
Packages/EnsembleSupport/Tests/
Packages/EnsembleDomain/Tests/
Packages/EnsemblePlex/Tests/
Packages/EnsembleWatchCore/Tests/
Packages/EnsembleCore/Tests/
Packages/EnsemblePersistence/Tests/
Packages/EnsembleUI/Tests/
Packages/EnsembleSiriShared/Tests/
EnsembleUITests/
```

Use `@testable import` for internal package behavior. Prefer protocol mocks for service dependencies and in-memory CoreData stacks for persistence tests. Never use `CoreDataStack.shared` in tests.

## High-Value Coverage Areas

- Plex request composition and failure classification.
- Sync timestamp filtering and fallback behavior.
- Playlist mutation and smart-playlist read-only guards.
- CoreData mapper and repository round-trips.
- Offline download target reconciliation and stale `.downloading` recovery.
- Siri matching/scoring and in-app playback payload routing.
- Feed last-good cache preservation.
- Provider-neutral identity, capability, action, and mutation routing across colliding IDs and same-named media.
- Cross-provider playlist grouping and source-specific mutability.
- Metadata-only refresh publication when stable IDs gain artwork, dates, favorites, play counts, or other sortable fields; unknown optional values sort last with deterministic tie-breakers.
- Merged artist and playlist ordering based on the aggregate values displayed by the merged row, in both sort directions.
- Playback-engine queue affinity, removed-item disclosure, background continuity, and provider-matched autoplay.
- Provider artwork lifecycle: catalog-search thumbnails remain transient and bounded, library artwork remains reusable at browse/detail sizes, and source removal clears only that source's durable assets.
- Source removal cleanup for database rows, transient/durable artwork, provider state, and restored queue references.
- Foreground and cold-start Plex mutation convergence for additions, track/album edits, playlist membership, and authoritative removals.
- Downloaded Plex playlist polling: target-server scoping, WebSocket-independent cadence, no-op efficiency, auto-download on add, and final-reference cleanup on removal.
- Bulk-download lifecycle integrity: exactly-once completion, quality preservation, bounded missing-lyrics work, redacted diagnostics, and thermal recovery.

Check existing tests before adding new files so coverage stays focused instead of duplicated.
