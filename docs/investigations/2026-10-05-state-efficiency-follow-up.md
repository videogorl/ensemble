# State efficiency follow-up

The initial read-only investigation below compares `e9eeb8cc` with baseline
`73e87f94`. The approved implementation and runtime evidence are recorded at the
end of this report. No unit/integration suites were added or run. Raw device/library
data, traces, logs, endpoint responses, and debugger scripts remain private under
`/tmp/ensemble-state-followup.S7UEvm` and
`/tmp/ensemble-efficiency-implementation.Mpq0cH`.

## Findings and next changes

### Artist and album invalidation: reproduced unnecessary work

`LibraryViewModel` combines the entire track array into artist and album pipelines
and removes duplicates only after computing the browse output
(`LibraryViewModel.swift:354–392`). Track inputs are needed for source-scoped
Downloaded Only membership, but otherwise these computations do not use them.

On the exact macOS Debug build, an isolated repository-backed view model loaded
16,980 tracks, 778 artists, and 1,473 albums. With both Downloaded Only filters off,
changing one track's rating hit both `computeArtists` and `computeAlbums` once.
Restoring that track hit both again; artist and album output snapshots were equal.
No persisted rating changed.

The focused correction is a shared conditional projection of downloaded artist
and album identities. Return empty memberships without scanning tracks when both
filters are off; otherwise scan once for the active filters. Deduplicate that
input before expensive browse computation. Keep album dependencies for artist
genres/favorites and merging preferences for grouping. An always-on track index
or new service is unnecessary. Source-scoped identities and hidden-source behavior
are the main regression risks.

### Playlist filter edits: stable genre work repeats

Single and merged detail models call `PlaylistDetailTrackDerivation.make` for
each filter edit. It filters tracks, extracts all available genres, and sums the
filtered duration on the main actor. Genres depend on the visible track input,
not the filter text; duration must still change with the filtered result.

A debugger micro-probe used an actual cached 3,460-track detail and five successive
search strings. Full derivation took 127.4 ms combined; repeating genre extraction
alone took 27.0 ms. These are Debug main-actor helper measurements, not Release UI
latency, frame times, or an energy benchmark.

Rebuild genres when tracks or hidden-media visibility change, and reuse them on
filter-only changes. Continue recomputing filtered tracks and their duration.
This can stay in the existing Core detail models with no new cache service.

### Plex playlist count discrepancy: upstream cause confirmed

[Issue #98](https://github.com/videogorl/ensemble/issues/98) describes a smart
playlist with metadata count 1,595 and cached body count 3,460. Authenticated live
requests to the same source returned a complete 38-playlist inventory whose
`leafCount` was 1,595, and a complete `/items` body with 3,460 distinct track keys.
Both inspected platform caches held that same ordered body. No pagination,
duplicate rows, missing linked tracks, or cross-library contamination explained
the difference. Plex itself supplies the conflicting counts.

`shouldRepairPlaylistTracks` treats membership count greater than metadata count
as needing repair, so every full playlist sync refetches this unchanged body.
The normal five-minute downloaded-playlist route is different: with an existing
cursor it uses incremental sync plus complete inventory/orphan reconciliation,
fetching bodies only for changed metadata timestamps. It disables full fallback.
The first call without a cursor can still enter full sync.

Do not trim the body or simply compare current and cached metadata counts.
Metadata is persisted before the body request/snapshot save; a failed body refresh
could then look up to date and lose its retry. A safe optimization would checkpoint
each playlist's remote fingerprint only after a complete body snapshot commits,
with an explicit refresh/expiry for dynamic contents that change without metadata.
The server inventory cursor cannot be that checkpoint because it advances without
fetching every body. Given the full-sync-only repeat, measure its material cost
before adding persistence machinery. The displayed-count policy also remains a
product decision.

## Physical-device profile

Both baseline and current Release workspace builds succeeded and were installed
on the physical iPhone 16 Pro, actual iOS 27.0. Installed versions matched the
built apps: baseline `0.4.0 / 202610050903.7387`, current
`0.4.0 / 202610050902.9815`. Launch/process evidence and trace process paths were
checked against those installed artifacts.

Matching 45-second Time Profiler launches opened Playlists. The 20–40 second
window still contained startup maintenance, so it is not a steady-state benchmark.
Application symbols were resolved using each build's dSYMs. Running samples had
1 ms weights:

| 20-second window | Baseline | Current |
| --- | ---: | ---: |
| Weighted running samples, all threads | 2.258 s | 2.642 s |
| Weighted running samples, main thread | 0.354 s | 0.400 s |

This single pair does not establish an improvement or regression. The current
capture has more sampled work, and variable launch maintenance prevents attributing
that difference to the refactor. Most work was in background Core Data callbacks;
application stacks included track mapping, downloaded-track artwork checks,
lyrics artifact-state checks, and Siri/Spotlight indexing. Rendering was a smaller
part of these windows. These inclusive stacks overlap and must not be added.

Power Profiler crashed while saving; its output was not exportable (missing
template). Battery, energy, thermal, and frame-time improvements remain unmeasured.

### Startup maintenance is the next profiling target

Source tracing matches the profile window: `OfflineDownloadService` schedules
deferred healing eight seconds after launch, waits for foreground idle, repairs
records, scans completed audio for truncation, removes orphan memberships, and
reconciles every completed download's artifacts. The artifact pass maps downloads
to `Track`, then serially checks artwork and lyrics on the main actor. Lyrics
checks read/parse persisted artifact state even before deciding no provider work
is needed (`OfflineDownloadService.swift:1384,1766,2283`; `LyricsService.swift:926`).

The root loads the whole library even when initially displaying Playlists, and
startup sync completion can request another full fetch/map. That reload repairs
browse metadata, including a documented sparse-genre case. Siri/Spotlight rebuilds
are event-triggered; unchanged index contents suppress the final write but still
require rebuilding/comparing the candidate index. None of this proves a defect.

Before restructuring, measure unchanged launches by stage: library load/map count,
sync material-change result, healing duration/candidate count, artwork hits/misses
and network requests, lyrics state/provider calls, and indexing reason/item count.
If repeated resolved-artifact validation dominates, narrow invalidation in these
existing owners. Preserve recovery for missing/truncated files, stale lyrics,
orphan memberships, and repaired metadata. Avoid a new global state framework.
This candidate and measurement plan are tracked in
[issue #99](https://github.com/videogorl/ensemble/issues/99).

## Runtime gaps checked

- **Slow network cancellation:** the actual macOS coordinator/controller/provider
  ran against a delayed local inventory endpoint with isolated in-memory repositories.
  The periodic task was in flight; `stopPeriodicSync()` cancelled it after three
  seconds. Full/no-cursor and seeded incremental cases both finished cancellation,
  stopped the timer, and left cursor timestamps unchanged. Incremental cancellation
  emitted no playlist refresh notification. This proves that delayed-network path,
  not cancellation immediately before a repository commit.
- **Physical iOS background:** logs show scene background, stopped foreground sync
  timer, stopped network/WebSocket monitoring, and suspended derived download
  artifacts. No slow real-phone request was held across this transition; that
  combined timing remains unverified.
- **Apple Music detail:** the current Release phone build opened a cached
  source-specific playlist through the supported media route. Logs reported 4,129
  memberships/items/tracks; the detail displayed that count, duration, and rows.
  All nonempty inspected Apple Music playlist bodies were cached, so the uncached
  catalog fallback remains unverified. No cache was deleted to force it.
- **iOS native queue drag:** reordered the first two future items on the owned
  iOS 26.5 simulator, verified the displayed order, then restored it. Playback was
  paused. This does not establish macOS drag behavior.
- **Same-ID metadata:** a transient title replacement passed through the actual
  playback service into the visible iOS queue row. UIKit label inspection showed
  the probe title, then the original title after restoring the saved queue. Count,
  index, and queue-item identity were retained. A second debugger-stepped attempt
  was interrupted by simulator shutdown during Device Hub reconnection; its
  persisted queue was checked and contained the restored order with no probe title.
  An isolated macOS projection also accepted same-ID rating/source changes.

The physical phone ended with playback paused and `devicectl` independently
reporting `passcodeRequired: true`. The owned simulator ended shut down. The local
delayed server was stopped. Device Hub reconnection also stopped three previously
running simulators; their exact UUIDs were rebooted and their Booted states
verified. Their prior app processes/UI sessions were interrupted and were not
reconstructed. No raw device/library artifacts are committed.

## Recommended order

1. Narrow artist/album dependencies and reuse playlist genres on filter-only edits.
   These are small changes in existing owners with demonstrated avoided work.
2. Profile unchanged physical launches with stage counts, then decide whether
   artifact recovery/indexing needs narrower invalidation.
3. Keep #98 tracked; measure full-sync cost before designing a successful-body
   checkpoint or changing the count presented to users.
4. Repeat energy profiling with a working capture and stable scenarios; finish
   uncached Apple Music fallback, physical slow-request/background timing, and
   macOS drag verification. No battery benefit is claimed yet.


## Approved follow-up implementation

Artist and album browse computations now consume deduplicated source-scoped
Downloaded Only membership instead of the whole track array. A single shared
Combine projection scans downloaded tracks only for enabled filters; with both
filters off it returns empty memberships without scanning. The two membership
sets are deduplicated independently. Existing artist album dependencies, merging,
visibility, initial snapshot preparation, and the browse debounce are retained.
The native multicast connection is retained with the existing subscriptions.

Single and merged playlist details rebuild their available genres on track-input
changes. Single details also rebuild on hidden-media visibility changes when
hidden items are excluded. Filter-only edits reuse the published catalogue and
continue deriving filtered tracks and duration. No new cache service, stored copy
of visible tracks, or view-level derivation was introduced.

Aggregate monotonic elapsed-time logs were added to library fetch/map, download
healing stages, truncation scan, artifact enqueue/drain, and Siri index rebuild.
They contain counts and durations, with no media identities. They use the existing
logger/session sink and local variables, with no global diagnostic service,
persistent counters, polling, or per-item log calls. Artwork/lyrics hit and provider
counters and sync material-change attribution remain future measurement work.
The logs do not change recovery, indexing, persistence, or sync policy.

### Verification

Workspace builds passed for macOS Debug, iOS 26.5 Simulator Debug, and physical
iPhone Release. All used version `0.4.0 / 202610051303.1714`. The installed simulator
executable and debug dylib matched the built files; the macOS PID executable path
and physical installed-version/launch-process evidence matched the exact artifacts.

Debugger probes ran the actual macOS model pipelines using isolated view models:

- A rating change and restoration in a cached 17,008-track library caused zero
  `computeArtists` and zero `computeAlbums` calls, with equal browse snapshots.
- A fixture with colliding artist/album keys across two sources selected only the
  downloaded source. An artist-membership-only change computed artists once and
  albums zero times; an album-membership-only change computed albums once and
  artists zero times. Unaffected snapshots remained equal.
- Twelve single/merged search, genre, and reset edits invoked filtered-track and
  duration derivation twelve times and genre derivation zero times. Duplicate
  occurrences, expected counts, and filtered duration were retained.
- Hidden/unhidden and track-input changes rebuilt genres. A settled repeat checked
  hidden catalogue contents, duplicate rows, duration, and full restoration.
  Short initial debugger waits were insufficient while the shared compute queue
  was busy; positive controls and queue-drain waits replaced those observations.

A debugger-only report export used `try!` and stopped the first process when the
app sandbox denied writing to `/tmp`. The exact app was relaunched, the final
visibility check passed, and the debugger detached/resumed. Temporary model
fixtures and preferences were restored; no media mutations were persisted.

On the owned iOS simulator, an actual 3,460-track detail was opened. Downloaded
Only hid all rows and displayed zero filtered duration; disabling it restored rows
and the original 221 hr 44 min duration. Playback remained paused. XCTest
accessibility capture timed out on this large screen; Device Hub native controls
and screenshots supplied the direct behavior evidence. This is not a frame-time
measurement. Separate single/merged filtering semantics were checked in the
macOS model probes above.

### Physical repeated-launch stage measurements

Two foreground Release launches opened Playlists on the physical iPhone 16 Pro,
actual iOS 27.0, with playback paused and no intentional library edits between
launches. The first 60 seconds of each persistent session log were inspected.
Background sync was active, so these are repeated-launch observations rather than
proof that every persisted input was unchanged.

| Stage | Launch 1 | Launch 2 |
| --- | --- | --- |
| Full library fetch/map count | 4 | 2 |
| Mapped tracks per call | 21,218 | 21,218 |
| Fetch/map elapsed per call | 1,294 / 1,007 / 1,085 / 1,080 ms | 1,134 / 1,013 ms |
| Download healing elapsed | 1,157 ms | 934 ms |
| Repair / truncation / cleanup / enqueue | 199 / 865 / 9 / 82 ms | 77 / 789 / 7 / 59 ms |
| Completed downloads / truncation candidates / truncated | 322 / 322 / 0 | 322 / 322 / 0 |
| Artifact batch processed / pending | 322 / 0 | 322 / 0 |
| Artifact batch elapsed | 771 ms | 8,748 ms |
| Siri rebuild elapsed / saved | 140 ms / yes; 157 ms / yes | 118 ms / no; 121 ms / yes |

Siri inputs per rebuild were 1,500 artists, 1,500 albums, 1,000 tracks, and 198
playlists. Launch 1's artist count changed between maps; Launch 2's aggregate
library counts stayed equal while the second Siri index still detected a material
change. Equal counts cannot establish equal metadata or an unnecessary rebuild.

These elapsed intervals include scheduling, repository, and async/network waits;
they are not CPU time and overlapping stages must not be added. The artifact batch
variation cannot yet be attributed to cache misses or provider requests. The next
work in [issue #99](https://github.com/videogorl/ensemble/issues/99) is to attribute
library reload triggers/material changes and artwork/lyrics cache/provider work,
then propose a focused correction in those existing owners. No startup redesign
or energy/battery improvement is established by these two runs.

The physical phone ended paused, screen sharing stopped, and `devicectl` reported
`passcodeRequired: true`. No global Device Hub restart was used in this follow-up.
The Plex body checkpoint/count policy in #98 and the earlier remaining runtime and
energy checks are still outside this implementation.

### Pending changelog publication

The exact `{{future}}` Notion changelog page was found and read. These delivered
entries are prepared for its Changes heading:

- Artist and album browsing avoids unnecessary recalculation when track metadata changes.
- Playlist filtering reuses genre information while keeping filtered tracks and duration current.

Their required GitHub commit links are pending publication of the local commit.
Push/merge authorization is separate; no unpublished commit link was added to the
user-facing changelog.
