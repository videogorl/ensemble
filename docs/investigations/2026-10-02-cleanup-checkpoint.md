# Cleanup checkpoint for physical-device testing

This records the pre-install checkpoint. The later approved installation and real iPhone results are recorded in [the physical-device report](2026-10-02-physical-device-checkpoint.md); that report supersedes the installation/authorization status and physical verification gaps below.

The discussed cleanup is committed in seven coherent code milestones, ending at `44e02456`. One editor owned each slice; independent read-only tracks reviewed ownership, concurrency, replay safety, native behavior and meaningful regressions. No push, merge, deployment, physical installation or substantive Now Playing redesign occurred.

## Scope and code reduction

Baseline is `c82a349c`, the already-delivered scoped connection-ownership milestone. The earlier `f7f8f09a` browse work was already committed before this request and is excluded from the following counts. The worktree was clean at the start and after the final browse commit; no unrelated edits were discarded.

| Local commit | Change | Production LOC | Test LOC |
| --- | --- | ---: | ---: |
| ddc7ceaf | Four HTTP execution/failover bodies become one server-request path | -117 | +33 |
| 77bdd6db | Pin, download and metadata commands return to their existing owners | -324 | -259 |
| 46db12ad | Playlist, rating and collection commands return to MutationCoordinator | -229 | -326 |
| 5c92dd1d | Playlist sync commands execute directly in SyncCoordinator | -218 | -68 |
| ce4287ec | Source sync callbacks execute directly in SyncCoordinator | -156 | -202 |
| 71aa67b4 | Network policy, active-use timers and exact-source reporting return to SyncCoordinator | -313 | -162 |
| 44e02456 | Four canonical browse snapshots replace mirrored outputs/view copies; unused playlist projections removed | -176 | +33 |
| **Total** | | **-1,533** | **-951** |

Counts are physical Swift lines including comments/blank lines, separated by shipping source/test roots, excluding Package.swift, documentation, scripts, generated/build/dependency trees. Inventory: production 148,700→147,167; tests 51,629→50,678. Evidence: /tmp/ensemble-cleanup-checkpoint-20261002/loc-summary.json and baseline/final-source-inventory.json. Each milestone records its gross additions/removals separately; documentation does not disguise code reduction. Final source-to-source diff, with renamed paths counted as removal/addition: production 2,012 added/3,545 removed; tests 1,730 added/2,681 removed. This endpoint count can differ from summing intermediate slices; the final inventory/net agrees.

Conceptually, callers now invoke commands on existing concrete owners rather than command facades and one-off result types. Sync no longer reconstructs controller callback bundles for state it already owns. HTTP attempt/replay/failure handling has one path. Browse has one committed value per section, while necessary native-row/StageFlow caches remain for presentation and scene state. There is no new recovery framework, compatibility layer or synchronized state owner.

## Behavior and safety

Preserved exact account/server/library identity, same server under different accounts, captured configuration revisions and source persistence leases, attempted endpoint/generation/auth/incarnation fences, atomic connection observation, cancellation and independent WebSocket lifecycles. Authorized requests/handed-off transfers retain their existing lifecycle. Unsafe playlist mutations retain their replay restrictions; bulk-clear replay guard and truthful replacement/seed outcomes, including visibility-fetch cancellation, remain.

Command review exposed and fixed source-feedback key collisions across accounts. Native sync regressions exposed and fixed duplicate replacement occurrence loss and a stale accepted-add cleanup-lease leak; the narrow fixes preserve ordered source-compatible occurrences and reject stale revisions before acquiring current leases. No additional reconciliation framework was added.

Storage/error outcomes, exact-source actions, saved independent filter scopes, last-good/provisional snapshots, authoritative empty, hidden/downloaded filtering, validated download payloads, duplicate playback-command protection, global sync ownership, timer cadence/stop behavior and reporting errors remain meaningful verification targets. Tests were moved to native owners where the old controller/facade assertions disappeared; mocked failure tests were retained when they protect actual failures.

## Passed checks

- Each code milestone passed its focused native checks, relevant signed workspace macOS/iOS builds, final-artifact independent review and direct changed-flow runtime inspection. Per-milestone evidence and limits live under /tmp/ensemble-cleanup-checkpoint-20261002/{http,commands-local,commands-playlist,sync-playlist,sync-execution,sync-lifecycle,browse}.
- Final whole EnsembleCore: 1,160 XCTest cases and 8 Swift Testing cases, zero failures. This is fresh final-code proof rather than the old baseline.
- Final browse selection: 93 Core cases and 21 UI cases, zero failures. Existing meaningful source, loading, filter, concurrency and playlist-occurrence cases remain; focused late-subscription/isolation and native flat-order cases cover plausible regressions.
- HTTP milestone EnsembleAPI: 85 cases passed after consolidation, including unsafe mutation replay/failover. API production has not changed since that tested artifact.
- Exact-build macOS and iPad A16/iOS26.5 runtime proof uses explicit built paths, dedicated DerivedData, pinned UUID 08CA3DD8-D174-40E9-A361-62B95671B969, fresh processes and matching installed binary hashes. Final incremental app version 0.4.0/202610021802.4287 remained the same; fresh binary/provenance evidence establishes the changed artifact.
- Changed Mac browse flow: independent Songs/Artists/Albums queries, cold saved queries, artist/genre detail panes, downloaded-only/reset, duration-order reversal updating native rows, title-sort restoration, populated playlist display and actual manual refresh completion. Queries/filters restored; playback paused. iPad: all four populated sections, independent search round trip, query reset and paused playback.
- Earlier exact-build checks exercised native pin/unpin, title editor cancellation, completed validated local download/removal, playlist creation/source chooser/editor cancellation, cached and uncached Plex streaming. Direct PMS checks proved identity/sections/direct 206/universal-transcode 200. The final lifecycle slice exercised app offline simulation/reconnect/artwork-before-health/WebSocket recovery and one user resume/pause with exact-source timeline reports.

## Unverified and existing limits

No physical-device result is claimed. Generic signing does not prove this phone's profile eligibility, installation or runtime behavior. Real Wi-Fi/cellular recovery, locked/background playback, system Now Playing/remote commands, AirPlay, MusicKit/DRM, Watch runtime and handed-off/interrupted background downloads require the phone/appropriate hardware.

WebSocket connections/recovery and native scoped-event/timer tests passed; live externally changed playlist/library→stored data→visible UI convergence was not deliberately exercised. Likewise live downloaded-playlist membership convergence and real simultaneous second-account configuration remain unverified; native exact-account/sibling/concurrency fixtures protect those paths.

Automation disabled animations. Compact landscape StageFlow, animation timing, native scroll restoration and multiwindow behavior have not received final device runtime proof; their owning algorithms/scene state were preserved. No live provider write/source removal was performed during these final checks.

Existing optimistic download-removal storage feedback, title-feedback normalization, raw-count browse readiness guards, the existing initial timeline publication pair and preexisting nil playlist links were not expanded into new redesigns. No lower-value test was used to recreate an obsolete layer. An earlier timing-sensitive WebSocket test failed once, then isolated and whole-Core repeat passed without changing or relaxing it; the final whole-Core run passed first time.

## Device checkpoint

Signed generic iOS Debug build passed from clean committed source `44e02456`. App, Siri extension and embedded Watch app are version `0.4.0` / build `202610021830.4402`. Deep/strict code-sign verification passed for all three bundles; existing development profiles expire June/July 2027. Artifact: `/tmp/ensemble-cleanup-checkpoint-20261002/device-DD/Build/Products/Debug-iphoneos/Ensemble.app`. Executable/debug-library hashes and profile summaries are recorded in device-artifact-proof.json. This report is the only later repository change; the device artifact contains the final production code.

This is build/signing proof only. The physical phone was not discovered, installed or driven, and its inclusion in every required development profile remains to be checked when available.

When Felicity makes the physical iPhone 16 Pro available and authorizes installation, identify the exact current device/OS/trust state with devicectl. Verify development-profile eligibility; rebuild for that destination if necessary. Install the fresh app without uninstalling or clearing data, then prove installed version and running process. Root alone drives Device Hub; credentials/passcode remain private.

Focused checklist:

1. Cold/warm four browse sections, saved filters and account/source switching; compact Songs/StageFlow and native list interaction.
2. Plex direct/transcode playback: resume/pause/seek/skip and one command per action; real Wi-Fi/cellular and reconnect.
3. Validated download, interruption/background handoff, foreground recovery and offline playback; restore local test downloads.
4. Agree a disposable external change, then verify exact-scope WebSocket event, debounce, persistence and UI freshness.
5. Locked/background playback, system remote commands/Now Playing, AirPlay and MusicKit as current-behavior validation. Stop at a reproduced defect before any new redesign.
6. Pause playback and lock the phone before finishing.

No device installation has been performed or authorized yet. The complete plan and provenance are in /tmp/ensemble-cleanup-checkpoint-20261002/physical-device-plan.md and device-artifact-proof.json.
