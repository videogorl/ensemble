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

The later [count-freshness investigation](2026-10-05-plex-smart-playlist-counts.md)
isolated stale list-level statistics: individual metadata/filter/body agreed,
and subsequent inventory counts refreshed to match. The findings below record
the earlier stale response and its then-observed repair consequence.

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

## Final state-efficiency continuation

Private evidence for this continuation is under
`/tmp/ensemble-state-final.NV63M2`. No unit/integration suite was added or run.

### Remove an unconditional startup library reload

`LibraryViewModel` no longer subscribes to startup-sync completion. That signal
was delivered after both material and no-op syncs and unconditionally fetched and
mapped the complete library again. The existing retained `lastContentChange`
publisher already delivers material library changes, including repaired genre
metadata, to current and late subscribers. Initial loading, cloud/source readiness,
user refreshes, download changes, and material sync changes retain their paths.
`lastStartupSyncCompletion` itself remains available for readiness/diagnostics.

In an isolated model on the exact macOS Debug process, publishing a completion
left its load generation at 2. Publishing a material genre change advanced it to
3; a model created after that change loaded once from the retained publication.
Temporary coordinator publications were restored. These controls establish
notification behavior; physical repeated-launch measurements are separate.

### Preserve failed playlist-body retries

Full and incremental Plex playlist sync now retain the previous modification date
while updating other header fields before a required body request. Only after a
complete body snapshot saves do they commit the new remote modification date.
A new header retains a nil date until that body succeeds. Metadata-only updates
that skip the body still update their normal header fields. No schema, displayed
count, deletion policy, or full-sync repair predicate changed.

Previously the new metadata date could save before an unsuccessful body request.
The next incremental pass could consider that playlist current, skip its body,
and advance the server cursor, losing the retry. This is a correctness correction
at the existing provider owner; it does not introduce a successful-body fingerprint
or settle the separate count discrepancy in issue #98.

A private localhost GET fixture exercised the production API client, sync provider,
and in-memory playlist/cursor repositories in four attempts. An incomplete full
body and an incremental HTTP 503 both preserved the old body/date and held the
cursor and orphan cleanup. A full retry committed the complete existing body but
left a new header's date nil after its HTTP failure. An incremental retry then
committed the new body's duplicate ordered memberships, advanced the cursor, and
removed the synthetic orphan. An unchanged-date title update made zero body
requests. All state assertions passed; host counters recorded the expected 12 GETs,
three existing-body requests, two new-body requests, one incomplete response,
two HTTP failures, two complete bodies, and zero unknown/non-GET requests.
Temporary fixture preferences were restored.

### Attribute downloaded-artifact work

The existing aggregate artifact-batch log now reports scheduler admission wait,
artwork checks/hits/misses/recovery attempts/deferrals and elapsed time, and lyrics
artifact-state checks/hits plus actual metadata/content provider calls and elapsed
time. Counters exist only for each prefetch and drain; no persistent state, polling,
per-item logs, or additional provider requests were introduced. Queue gating,
suspension, deduplication, durable missing-assets outcomes, and recovery behavior
retain their existing paths. Artwork recovery attempts include URL resolution;
they are not confirmed HTTP download counts.

### Repeated full-body cost and the remaining design boundary

Two read-only passes through the configured macOS API client fetched the same
complete conflicting Plex playlist. The inventory contained 38 playlists and took
561 ms / 17 ms. The body contained 3,460 distinct tracks, was 5,553,911 bytes each
pass, and took 1,664 ms / 1,113 ms to fetch and decode. These elapsed measurements
include network/decode work and are not CPU time or an energy benchmark.

Avoiding the repeated healthy body on full sync still needs a successful-body
checkpoint plus an explicit freshness/refresh policy for dynamic contents whose
metadata does not change. The focused retry correction makes existing retries
reliable but deliberately leaves that larger design and the displayed-count
policy for a decision. Never truncate the complete body to the conflicting
metadata count. The normal downloaded-playlist incremental route already skips
unchanged bodies when its cursor exists.

### Working physical power capture

The bundled Power Profiler template failed with all-process targeting and crashed
in its network statistics model while saving an app launch. A minimal Blank
template containing only the Power Profiler instrument successfully recorded,
saved, and exported a ten-second launch on the physical iPhone 16 Pro, actual
iOS 27.0. Its app process/version matched the installed Release build. This proves
that the narrower capture works; the short canary does not establish battery
savings, and it is not a matched before/after comparison.

### Tool blockers and completed follow-up checks

Xcode workspace approval was granted and its RunProject request launched a fresh
combined Debug build on the physical phone despite the tool timeout. Installed
version `0.4.0 / 202610051443.6973`, container, debugger PID, and build source path
matched. The initial Core module lookup failure used a stale default DerivedData
directory. Correcting it to the directory from Xcode's actual build log resolved
that lookup. The catalog-search expression then failed to link the MusicKit
`MusicItemCollection` nominal type descriptor; its task was not initialized.
The phone disconnected during background-probe setup: Device Hub could no longer
display it, devicectl could not acquire device connectivity, and LLDB could not
write the probe dictionary into the target. Neither remaining phone probe ran
during that attempt. Xcode stopped its debug session, and the delayed fixture
was stopped with no requests. No cache was deleted or production diagnostic hook
added. The phone was subsequently reconnected and both checks completed below.

On the reconnected physical phone, Xcode launched the combined Debug build with
verified installation, executable path, PID, and build source path. Bypassing the
debugger-only MusicKit search expression, a known public catalog playlist was
passed directly to the production `PlaylistDetailViewModel` with an isolated
in-memory repository and the real configured sync/provider owners. It loaded
50 tracks, 50 catalog-identity items, and 50 filtered tracks, with nonzero duration,
matching source identities, completed loading, and no error. The isolated cache
was absent before and after. This proves the model/provider uncached fallback;
it is not a rendered catalog-detail UI check or a pagination-completeness claim.

A production coordinator/API/provider with isolated in-memory repositories then
started periodic sync against a delayed synthetic inventory endpoint. Host
counters confirmed one request in flight before Device Hub's native Home action.
The actual iOS background notification invoked the coordinator's stop path:
cancellation completed while the application was backgrounded, the timer stopped,
the task cleared, the full seeded cursor record remained equal, and zero scoped
playlist refresh notifications were emitted. Cursor seed/read checks succeeded.
The host later confirmed the connection closed before its delayed response.
The shared app also logged the native scene-background transition and stopped
network monitoring. The coordinator probe uses a synthetic source, not a request
against the user's configured server. Temporary observers/preferences were
restored; the debugger and fixture server were stopped.

The macOS native drag gap is closed. On the explicitly launched combined build,
native Play Next / Play Last added two temporary future queue items and displayed
confirmation toasts. Dragging the native handles swapped their displayed order;
the owned app's session log recorded the matching queue move. A reverse drag
restored it. Subsequent cleanup input caused an additional move, so removal used
the native row context menus and final owner state was checked independently.
Both temporary items were removed; the original 13 items, current index 12,
paused playback, and original edit-protection flag were restored and saved.
The existing iOS simulator and macOS cancellation evidence above retains its
narrower scope.

Current develop was merged into this branch without conflicts. Both combined
workspace builds passed: macOS Debug and physical iPhone Release. The explicit
macOS executable path and debug binary UUID identified the combined running build.
After the phone probes, the exact combined Release artifact was installed and
launched: version `0.4.0 / 202610051437.6973`. The installed version and running
executable's new container matched. Playlists rendered with paused playback.
Its session log recorded one library map of 21,218 tracks in 1,246 ms and completed
startup sync. This is an additional combined-build smoke check, not a new matched
benchmark. Device Hub locked the phone and stopped only its screen sharing;
devicectl independently confirmed `passcodeRequired: true` afterward.

Pending user decisions remain the Plex successful-body checkpoint/freshness and
displayed-count policy, plus publication/integration. The branch contains local
commits only; no push or merge into develop is authorized by this continuation.

### Final physical Release launch measurements

The final source was built for macOS Debug and physical iPhone Release. The phone
install used the exact Release `.app`; installed version was
`0.4.0 / 202610051405.4899`, and the launched process and trace used its new
installation container. The emitted `artworkRecoveryAttempts` field additionally
identifies the final diagnostic binary. Playback was paused in the observed UI.
No debugger was attached during these measurements.

Two repeated launches opened Playlists without intentional library edits. Startup
sync remained enabled, so unchanged counts do not prove identical persisted
metadata. Both completed startup sync without a material library reload:

| Stage | Launch 1 | Launch 2 |
| --- | ---: | ---: |
| Full library fetch/map count | 1 | 1 |
| Mapped tracks | 21,218 | 21,218 |
| Library fetch/map elapsed | 1,315 ms | 1,172 ms |
| Download healing elapsed | 1,007 ms | 1,037 ms |
| Truncation candidates / truncated | 322 / 0 | 322 / 0 |
| Artifact batch processed / pending | 322 / 0 | 322 / 0 |
| Scheduler admission wait / deferrals | 0 ms / 0 | 0 ms / 0 |
| Artwork checks / hits / recovery attempts | 321 / 321 / 0 | 321 / 321 / 0 |
| Artwork checks elapsed | 214 ms | 192 ms |
| Lyrics state checks / hits | 322 / 320 | 322 / 320 |
| Lyrics metadata / content provider calls | 2 / 4 | 2 / 4 |
| Lyrics state checks elapsed | 212 ms | 241 ms |
| Lyrics resolution elapsed | 1,998 ms | 232 ms |
| Artifact batch elapsed | 2,430 ms | 670 ms |

The earlier comparable no-material-change launch mapped the library twice. The
owner probe and these two final runs support elimination of that extra map. They
do not establish a whole-app energy improvement. In this final pair, all artwork
checks hit cache and the same two lyrics state misses caused provider work; the
largest elapsed difference was lyrics resolution, not scheduler admission. These
are elapsed async stages, not CPU time; overlapping stages must not be added.
They do not retrospectively prove the cause of the earlier 8,748 ms batch.

The recurring lyrics misses received successful metadata responses and nonempty
content responses in both launches. There was no observed 404, nil metadata,
transient failure, deferred retry, or chord-parse failure. These logs do not prove
why the durable artifact marker was absent: an unreported normal-lyrics parse
failure, revision mismatch, or persistence issue remains possible. Do not change
recovery/cache policy on this evidence. The next focused measurement would count
durable-marker outcomes and revision mismatch at the existing owner, without
per-item identities.

The final minimal Power Profiler recording ran for 45 seconds (48.8 seconds total
trace duration), saved, and exported actual per-process power-impact rows for the
same verified Release process. The phone was charging over USB. This is a working
measurement artifact, not a matched battery-savings comparison.

Additional prepared changelog entries, pending published GitHub commit links:

- Library startup avoids a redundant reload when sync leaves the library unchanged.
- Playlist sync retains retries after incomplete or failed track responses.
