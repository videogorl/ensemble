# Cross-Platform Policy, Mutation, Drag, Performance, And Scaffold Audit

Date: 2026-05-04

## Baseline

This audit follows the same evidence-matrix pattern as `2026-05-04-function-ownership-context-menu-audit.md`.

The implementation rule is: same feature, same rules, platform-native rendering. Platform branches are allowed only when they change presentation technology, not feature ownership, source compatibility, error policy, or fallback semantics.

## Platform Parity Matrix

| Feature | Current owner | Platform variants | Policy risk | Before gate | After gate |
|---|---|---|---|---|---|
| Root navigation shell | `RootView` chooses `MainTabView` or `SidebarView`; `SidebarView` owns large-screen selection/detail state | iPhone tab shell; iPad/macOS sidebar + detail shell; iOS 15 fallback navigation | Navigation behavior can drift when rules live in root branches instead of a shared policy | Root routing documented from `RootView.swift`, `MainTabView.swift`, and `SidebarSelection.swift` | Shared platform policy documents shell choice, compact fallback, and auxiliary presentation route |
| Commands | `EnsembleApp` owns app-level settings, refresh, playback, and macOS sidebar command suppression | iOS refresh command; macOS refresh/playback/menu command set | Command availability can diverge from focused-screen feature availability | Command matrix documents command, platform, owner, and focused-screen behavior | Commands route through the same action owner as toolbar/menu actions |
| Mini-player menus | `MiniPlayer` uses SwiftUI popover on iPadOS and AppKit `NSMenu` on macOS | Compact controls, large controls, iPad popover, macOS native menu | Same menu item can gain different order/availability if renderers drift | Menu rows cross-checked against `MediaMenuCatalog` | Renderers consume one menu catalog/action policy |
| Native track tables | `SongsView`, `MediaTrackList`, `MacNativeTrackTableView`, and `QueueTableView` each provide row interaction hooks | iPhone compact rows; iPad UIKit tables; macOS AppKit tables; queue local reorder | Row menu, drag, favorite, and playback affordances can diverge by backend | Native table backend matrix covers row actions, drag type, share, context menu, and fallback | Table backends receive the same action/drag policy inputs |
| Popovers and sheets | Filter, profile, downloads, playlist/create/edit, account detail, and settings screens use separate presenters | iOS grouped forms/sheets; iPad/macOS popovers/windows/card sections | Similar workflows use different chrome, validation, and keyboard behavior | Presenter matrix documents compact, regular, and macOS behavior | Utility/editing screens use shared adaptive scaffold/presenter helpers unless explicitly exempted |

## Mutation Ownership Matrix

| Mutation | Current owner | Toast/error owner | Source compatibility | Remaining gap | Target policy |
|---|---|---|---|---|---|
| Playlist add/create | `NowPlayingViewModel` calls `MutationCoordinator` and emits add/create toasts | Inline in `NowPlayingViewModel` | `PlaylistActionService` for pre-filtering; `MutationCoordinator` for add/create transport | Toast policy still lives beside playback state | Add/create toast policy moves into playlist action workflow; NPV only shows returned payloads |
| Playlist rename/delete | `PlaylistMutationWorkflow` + `MutationCoordinator` | `PlaylistMutationWorkflow` | Target playlist source key | Mostly consolidated | Keep as current reference pattern |
| Metadata edit/delete | `MetadataMutationWorkflow` + `MetadataMutationService` | `MetadataMutationWorkflow` | Server ownership checks inside service | Mostly consolidated | Keep as current reference pattern |
| Favorites/rating | `NowPlayingViewModel` owns optimistic rating, persistence, mutation call, and toast policy | Inline in `NowPlayingViewModel` | Track source key via `MutationCoordinator.rateTrack` | Broad NPV owns mutation policy and in-flight guards | Add `TrackRatingMutationWorkflow`; NPV owns state application, workflow owns mutation/toast result policy |
| Pins | `PinManager` persists pins; views call `pin`, `unpin`, `pinAll`, `unpinAll` directly | No central toast/error policy | Source key stored on pin payload | Pin action behavior spread across context menus, details, sidebar, pinned VMs | Add `PinMutationWorkflow`; views call toggle/pin-all/unpin-all helpers |
| Downloads | `OfflineDownloadService` owns targets and queue; view models call service methods directly | Queue-completion toast in notification bridge; user action feedback is inconsistent | Source key / target key per target kind | User-initiated target actions have no shared result policy | Add `DownloadMutationWorkflow` or result payload helpers for remove/toggle/pause/resume actions |
| Queue | Playback/queue services own transport and queue mutation | Usually no toast; local UI state | Not source-filtered except media availability | Queue reorder vs external drag rules need explicit matrix | Keep local queue mutations local; document copy-vs-move and external export behavior |

## Drag, Drop, And Export Policy Matrix

| Source item | In-app payload | External file promise | Destination rule | Copy/move | Fallback/error |
|---|---|---|---|---|---|
| Track row/card/native table | `MediaDragPayload.Kind.track` with stable id/source/title | Supported through `ShareService.prepareTrackFileURL` | Playlist/sidebar targets accept if source-compatible; Finder/file destinations receive audio file when available | Playlist add is copy; queue reorder is local move only | File export falls back to provider failure; playlist drop uses shared resolver errors |
| Album card/detail | `MediaDragPayload.Kind.album` | Unsupported in this PR | Playlist target expands to album tracks through `PlaylistDropResolver` | Copy-add only | Empty/unresolved album returns shared unresolved-item error |
| Playlist card/sidebar | `MediaDragPayload.Kind.playlist` | Unsupported in this PR | Playlist target expands non-smart source playlist tracks | Copy-add only | Smart source, merged target, unresolved target, and cross-source failures use resolver errors |
| Queue row | Track payload plus local queue item id where backend supports it | Track file export allowed only for the track payload | Queue table accepts local queue item ids for reorder; external destinations use track file | Queue reorder is move; all playlist/file destinations are copy | If local id is absent, fall back to normal track drag behavior |
| Artist | No payload in current implementation | Unsupported | Not accepted by playlist drops | Not applicable | Remain unsupported until an explicit artist-export policy is designed |

## SwiftUI Observation And Performance Gate

| Surface | Current risk | Required measurement | Target change |
|---|---|---|---|
| Root and detail shells | Root owns scene `NowPlayingViewModel`; children may observe broad model state | Instruments trace and OS log baseline before refactor | Shells observe only visibility/navigation/settings state; Now Playing data is read by focused subviews |
| Now Playing viewport/sheet | Cards still take the full view model, although high-frequency values use subjects | Body invalidation counts and Time Profiler before/after | Split playback, queue, lyrics, artwork, and rating projections where broad invalidations remain visible |
| MiniPlayer | Parent avoids observation, but subviews still observe full NPV slices | Trace mini-player during playback, rating, queue, lyrics updates | Replace full-model observation with local `@State` subscriptions for track/control/waveform/menu slices where measurable |
| Artists/Playlists/Songs | Browse views pass NPV for row actions while trying to avoid broad observation | Scroll + playback-change trace on large libraries | Preserve row correctness while avoiding persistent list-wide NPV observation |

## Utility Scaffold Matrix

| Screen family | Current rendering | Gap | Target scaffold |
|---|---|---|---|
| Profile/Downloads | iOS `List`; macOS `EnsembleUtilityScreenScaffold` + card sections | Reference implementation | Keep as canonical examples |
| Filters | Custom macOS scroll body plus iOS `Form` | Similar utility menu but separate scaffold/presenter logic | Migrate to adaptive utility form/list scaffold |
| Logs/Settings subviews | Raw `List` with partial section header helpers | macOS menu-like screens keep list chrome | Migrate to adaptive utility list scaffold |
| Account detail | Raw `List` on all platforms | Profile-adjacent workflow does not share utility card rhythm | Migrate macOS/regular presentation to utility scaffold while preserving iOS grouped list |
| Create/edit playlist and text input | Local `Form`/navigation containers | Short editor rules are repeated | Keep plain sheet behavior, but use shared editor scaffold and validation row pattern |

## Before/After Verification Gates

1. Automated tests: `swift test --package-path Packages/EnsembleCore` and `swift test --package-path Packages/EnsembleUI`.
2. Warning budget: `scripts/check_core_warning_budget.sh` after Core service additions.
3. App builds: iPhone and iPad simulator build through `Ensemble.xcworkspace`; macOS build if available in the environment.
4. Simulator verification: iPhone tab flow, iPad sidebar flow, profile/downloads/settings/filter scaffolds, favorite/pin/download actions, playlist add/create/rename/delete, drag track/album/playlist into playlist targets.
5. Performance evidence: capture a before/after runtime baseline with `scripts/capture_runtime_baseline.sh`; attach Instruments trace notes for Root, Detail, Now Playing, Artists, Playlists, and MiniPlayer. If A9 hardware is unavailable, document simulator-only trace limitation.

## Implementation Order

1. Add this audit doc and update `.claude/skills/project-structure/SKILL.md`.
2. Add small workflow/policy types without changing visible behavior.
3. Migrate callers to the new workflows one mutation family at a time.
4. Add drag/export policy tests before changing drag behavior.
5. Add observation projections only after baseline trace capture identifies the highest invalidation sources.
6. Add the adaptive utility scaffold and migrate menu-like screens in small, visually verifiable batches.

## 2026-05-04 Implementation Pass

| Area | Completed in this pass | Remaining gate |
|---|---|---|
| Platform parity | Added `EnsemblePlatformFeaturePolicy` for root shell, mini-player menu renderer, native track-list backend, and utility scaffold rules. `RootView` now routes through this policy while preserving platform-native `MainTabView`/`SidebarView` renderers and OS availability fallbacks. | Commands still need to consume the same policy/action matrix in a follow-up. iPad portrait simulator presents the split shell collapsed to the detail column; full-width sidebar interaction still needs landscape/macOS visual capture. |
| Mutation workflows | Expanded `PlaylistMutationWorkflow` to own add/create toast policy. Added `TrackRatingMutationWorkflow`, `PinMutationWorkflow`, and `DownloadMutationWorkflow`; routed Now Playing favorites/rating, playlist add/create, pin actions, and user download actions through those workflows. | Download workflow currently centralizes action ownership but preserves the existing mostly-silent user feedback policy. Add explicit user-action toasts only after product copy is agreed. |
| Drag/drop/export | Added `MediaDragExportPolicy` and UI tests for track copy export, album/playlist in-app-only support, queue move-only behavior, and unsupported file promises. Existing `PlaylistDropResolverTests` cover expansion, dedupe, smart/merged/unresolved/cross-source rejection. | The policy is documented/tested but only partially wired into existing drag providers because current behavior already matches the matrix. Any future drag surface should consume this policy directly. |
| SwiftUI performance | Captured a simulator startup runtime baseline with `scripts/capture_runtime_baseline.sh`; startup health checks completed in 1.13s and startup sync completed in the captured log. | No Instruments before/after traces were captured in this pass. Observation projections for Root, Detail, Now Playing, Artists, Playlists, and MiniPlayer remain gated on Time Profiler/SwiftUI invalidation evidence. |
| Utility scaffolds | Added `EnsembleAdaptiveUtilityScaffold` for grouped iOS lists and macOS utility card sections. Migrated Audio Quality, Connection Security, and Storage settings subviews as the first scaffold consumers. | Filters, Logs, account detail, playlist create/edit, and text input still need separate visual migration passes. |

## 2026-05-04 Verification Results

| Gate | Result |
|---|---|
| Core tests | Passed: `swift test --package-path Packages/EnsembleCore` (490 XCTest cases + 4 Swift Testing cases). |
| UI tests | Passed: `swift test --package-path Packages/EnsembleUI` (42 XCTest cases). |
| Core warning budget | Passed: `scripts/check_core_warning_budget.sh` reported 0 Core warnings against budget 0. |
| iPhone workspace build | Passed: `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'id=64431A29-844A-4897-961B-562E7529138F' build -quiet`. |
| iPad workspace build | Passed on iOS 15.5 simulator: `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'id=309C07A5-D6FF-4C11-8C59-620DE8DF07BF' build -quiet`. |
| macOS workspace build | Passed: `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -destination 'platform=macOS,arch=arm64' build -quiet`. |
| Simulator smoke | iPhone 17 Pro simulator launched, navigated More -> Downloads, verified utility content, and toggled mini-player Play/Pause. iPad simulator launched to the Feed detail column under the split-shell policy. Screenshots: `/tmp/ensemble-iphone-downloads-smoke.png`, `/tmp/ensemble-ipad-feed-smoke.png`. |
| Runtime baseline | Captured to `/tmp/ensemble-runtime-baseline-2026-05-04`; persistent session log and OS log were copied there. |
