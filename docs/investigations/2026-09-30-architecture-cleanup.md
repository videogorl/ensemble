# Architecture cleanup verification — September 30, 2026

## Delivered scope

The baseline is commit `5d63b605`. This change implements the six approved
cleanup areas without replacing playback engines, cloud transports, or queue
ownership.

| Area | Change | Preserved boundary |
| --- | --- | --- |
| Now Playing artwork | Inject the existing artwork loader and foreground scheduler, including the blur path. | Cache, asynchronous resolution, cancellation, and stale-track protection remain in the existing artwork projection. |
| Playback construction | Delegate the public initializer to the existing designated initializer. | Production and tests now share the same service setup. |
| Playback handoffs | Remove duplicate interruption/route booleans and their state-copy actions. | The handoff coordinator owns suppression and skip availability; a system-managed pause remains authoritative until explicit resume. |
| Source sync | Share completion, error, and cancellation handling between full and incremental sync. | Recheck source revision/persistence lease after awaited connection resolution; publish committed library changes when a later playlist phase fails or is cancelled. |
| Playlist creation | Reuse the batch mutation workflow while retaining the ViewModel's optimistic creation/materialization path. | Roll back only failed placeholders; retain successful copies and aggregate source results consistently. Each UI task dismisses its own pending toast. |
| Cloud runtime | Move cloud callbacks, reconciliation, and bounded retries into `CloudSyncCoordinator`; share five KVS bootstrap boundaries. | Wire callbacks before deferred startup gating, pull before seeding, preserve unavailable versus successfully empty remote data, and retry only unsettled features. |

`DependencyContainer` is reduced from 2,034 to 1,002 lines. The extracted cloud
owner is 1,005 lines; this is an ownership improvement, not a claim that the
whole moved subsystem disappeared. Existing cloud bootstrap tests follow the
new owner rather than a forwarding compatibility layer.

## Runtime and external evidence

Artifacts are retained locally under
`/tmp/ensemble-architecture-cleanup.cI9EQF`. Raw traces and database snapshots
are private diagnostic artifacts; the numbers below are sanitized summaries.

All builds used `Ensemble.xcworkspace` with separate DerivedData directories.
The final iOS device, iOS simulator, and macOS builds succeeded. Installed
versions and process paths were checked against the produced artifacts before
accepting runtime evidence.

### Instruments

Time Profiler plus Activity Monitor attached to exact PIDs on the same Mac
(`E3A3882D-C3B6-5B96-805E-B89E87E9E955`, macOS 27.0.1, Instruments 27.0).
Baseline and final steady-state runs used the Songs surface, paused playback,
and about 50 seconds of settling before capture.

| Steady-state measurement | Baseline | Final |
| --- | ---: | ---: |
| PID | 43884 | 46573 |
| Build | 202609301002.5636 | 202609301017.5636 |
| Capture duration | 30.990 s | 30.950 s |
| Average process CPU, from CPU-time delta | 0.055% | 0.041% |
| Peak physical footprint | 234.407 MiB | 236.642 MiB |
| Potential hangs | 0 | 0 |
| Thermal state | Nominal | Nominal |

The result is neutral: a single short pair does not establish a performance
improvement, and peak footprint is about 1% higher. This measures settled
desktop resource use, not launch cost, mobile memory pressure, or a leak trend.

Additional accepted captures exercised Now Playing, Play/Pause, return to the
library, profile navigation, and manual cloud sync. Actual final playback
position advanced from 0:00 to 0:16, artwork and blurred background rendered,
and manual sync updated profile and all seven enabled feature statuses to
“Pulled from iCloud.”

The active final trace flagged five main-thread intervals (0.410–1.118 s).
The baseline player trace also flagged stalls (0.296–0.813 s). The first large
stall in each build was dominated by accessibility-tree generation: 639/658
final and 734/772 baseline main-thread samples contained accessibility frames.
Another player interval showed SwiftUI rendering in both builds. The broader
final navigation capture included additional accessibility/rendering work;
different capture lengths and action timing prevent comparing stall counts as
a regression metric. These observations warrant a separate UI-performance
investigation without repeated full accessibility snapshots. They are not
evidence of a new cloud or source-sync blocking operation.

The final isolated manual-sync capture had no potential-hang rows over 30.909 s;
the baseline sync capture had one 0.296 s microhang over 31.210 s. Both remained
thermally nominal. Recordings launched by Instruments were rejected after they
resolved to the installed `/Applications/Ensemble.app`; only captures attached
to processes with verified build paths were accepted.

Physical iPhone Instruments attempts disconnected after about two seconds and
were rejected. No phone CPU/memory comparison is claimed.

### Physical iPhone 16 Pro

Device `00008140-00023030117B001C`, actual iOS 27.0. The final build was
`0.4.0 (202609301017.5636)`; installed executable/debug-library and running
process evidence was retained. The main baseline and final UI scenarios passed:
Play/Pause, advancing playback position, Next, Now Playing artwork,
background/foreground, Albums, and iCloud Sync Now. The playback tracks were
Plex local-file sources; this does not prove Apple Music DRM or audible output.

A live two-source creation of `Ensemble Physical Cleanup 20260930` succeeded on
Minibar and Hiigel-Server. Plex returned matching empty audio playlists with
IDs `17091` and `27578`; the local database held both corresponding source
identities. The merged row survived app relaunch and opened correctly.
Both test copies were subsequently removed; provider absence and an empty local
query for the test title were verified after normal startup sync.

Device Hub input repeatedly timed out, so verification used a temporary
external UI-test workspace, exact-device `devicectl` evidence, provider API
readback, and screenshots. Helper/locator failures were retained separately
from successful app scenarios. Locked-device pause input became inaccessible,
so the exact Ensemble process was terminated to stop its Plex playback. A final
normal startup (PID 97299) completed real source sync and restored playback
paused (`NowPlaying` rate 0); the app was then terminated for a coherent cleanup
database snapshot. The final process list and `passcodeRequired=true` confirmed
no Ensemble process remained and the phone was locked. This is not a claim of
successful lock-screen Pause input. The final source statuses and pause restore
are in `physical/final-convergence-runtime-session.log`; final lock evidence is
in `physical/post-device-hub-close-lock.json`.

### iPad simulator: partial-success creation

Device `08CA3DD8-D174-40E9-A361-62B95671B969`, actual iOS 26.5. Freshly
installed build `0.4.0 (202609301016.5636)` had matching built/installed
executable and debug-library hashes and initially ran as PID 43677.

Native New Playlist input created `Architecture Audit 1030` on three selected
Plex servers. Hiigel returned HTTP 400, while Minibar (`17090`) and MattPlex
(`21717`) succeeded. The app replaced the pending toast with the correct
2/3 partial-success result, showed one merged row, and persisted exactly the
two successful real copies. Independent provider reads confirmed both copies
and no matching Hiigel copy. Cleanup targeted only those exact IDs after
checking title and empty contents. After relaunch (PID 64603), no test copies
remained locally; 40 other playlist records remained.

## Supporting code checks

Final focused selection:

```sh
swift test -q --package-path Packages/EnsembleCore --filter 'NowPlayingViewModelFavoriteTests|PlaybackServiceTests|PlaybackHandoffCoordinatorTests|CloudSyncCoordinatorBootstrapStateTests|SyncSettingsManagerTests|KVSSyncServiceTests|SyncExecutionController|PlaylistDetailViewModelTests|PlaylistMutationWorkflowTests'
```

249 tests passed. Four focused regressions cover injected cached/async artwork,
system-pause suppression until explicit resume, partial optimistic creation
and later materialization, and cancellation after committed library changes
for both full/incremental sync. Two existing sync tests now assert the phase
boundary and all cache operations without imposing ordering on concurrent
cache tasks.

The full affected package was checked before changes and again after them:

| Run | XCTest tests | Failed assertions | Failing tests | Swift Testing |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 1,191 | 15 | 3 | 8 passed |
| Final quiet run | 1,195 | 15 | same 3 | 8 passed |

The three unchanged failures are
`EnsemblePermalinkResolverTests.testCaseInsensitiveSameNamedPlaylistsUseMergedDestination`
and the two `LibraryViewModelCacheCleanupTests` remote-library-disable tests.
The latter receive an empty change-set from `AccountManager.applyLibraryFlags`
before cleanup; their behavior and source owner are unchanged by this work.
An earlier final run during concurrent workspace builds additionally hit fixed
wait/projection timing failures in lyrics and playlist visibility tests. Both
passed in isolation and in the quiet full run; their waits were not changed.
The full suite is therefore not green, but this change adds no repeatable
failure to the baseline result. `git diff --check` passed.

## Limits and follow-up observations

Real phone-call interruption, AirPlay route replacement, Apple Music DRM, first
device iCloud provisioning, transport loss/recovery, and sustained low-memory
behavior were not directly exercised. Coordinator/source-lease/bootstrap
coverage supplies supporting evidence for those boundaries, not equivalent
physical proof.

The physical empty-playlist detail placed “No tracks” behind the floating mini
player. No matched baseline screenshot establishes whether that is a regression;
the detail layout was not changed in this work. Detail deletion correctly
targeted the selected Minibar source, as its confirmation described; the other
Hiigel test copy was removed by exact-ID API cleanup.

The temporary external UI-test runner
`com.videogorl.ensemble.ExternalProbe.xctrunner` may remain installed. Removal
failed twice with CoreDevice error 4016 because the phone no longer supplied
the required awake/connectivity assertions. Cleanup did not reactivate or
unlock the phone. When the phone is available again, the remaining cleanup is:

```sh
xcrun devicectl device uninstall app --device 00008140-00023030117B001C com.videogorl.ensemble.ExternalProbe.xctrunner
```
