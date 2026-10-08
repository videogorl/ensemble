# iOS Background Refresh recovery

## Delivered behavior

`SyncCoordinator` writes the enabled source keys to an atomic app-support file
before a background attempt starts remote work. Each source retains its key until
the library and applicable playlists complete, along with awaited Siri catalog
publication and reconciliation of existing offline targets. Interruption retains
unfinished keys; already committed data and incremental cursors survive.

Cold launch, warm foreground activation, and the existing foreground timer retry
the handoff. Foreground recovery also adds every currently enabled source, since
a source that completed in background may have changed again before opening.
Unavailable configuration preserves outstanding work; authoritative source
disablement can remove its key.

The coordinator initializes its offline flag from the network monitor's restored
state. When a fresh connected path arrives after an early foreground attempt,
pending recovery retries after endpoint checks, using the existing foreground
task owner. Backgrounding cancels that owner. This avoids waiting for the periodic
fallback when opening initially sees an old offline path.

The background coordinator uses a cooperative 25-second deadline, with six-second
source budgets and Plex before Apple Music. Cancellation reaches the owned source
task and providers check cancellation at pagination and persistence boundaries.
These are cooperative deadlines, not a guarantee that a native framework await
returns within a fixed wall-clock interval. The persisted handoff remains the
recovery mechanism if iOS suspends or terminates the process first.

The shared Siri catalog can update in background. Spotlight compares it with a
separate applied snapshot, acknowledged only after deletion and indexing succeed.
Foreground activation retries Spotlight even when no source handoff remains.
Offline reconciliation only refreshes existing selections and uses the existing
persistent download queue and network/pause policies.

## Physical-device evidence

Verification uses the physical iPhone 16 Pro over USB and the signed workspace
Debug build. Installed app receipts, process executable paths, and debugger image
UUIDs distinguish the produced build from previously installed artifacts.

- The registered SwiftUI refresh handler saved five source keys while the app was
  in background. Those keys survived explicit process termination.
- Cold launch resumed the handoff automatically, advanced all five library source
  timestamps, completed the awaited library/playlist follow-ups, cleared the
  marker, and indexed changed Spotlight items.
- A debugger-assisted one-second budget with a three-second cancellable delay
  returned incomplete after approximately 1.04 seconds and retained all five
  source keys. This timer check ran in foreground; it is not natural OS expiration
  evidence. The existing foreground fallback later recovered the handoff.
- A normal-budget invocation in actual background committed all four Plex
  library phases and the three server playlist phases before Apple Music work
  remained pending. The test's UIKit assertion had started before the callback,
  so suspension in that run does not establish a failure of the full deadline.
- On the final installed artifact (debug image UUID
  `37610F40-F192-3D76-9205-22EF57FA8123`), the app entered background at
  09:41:10.460. A host-side fixture append was confirmed at 09:41:17.245;
  the registered handler entered at 09:41:17.522. Before reopening, the cached
  playlist grew from three to four tracks, offline membership included the new
  track with a persisted pending high-quality download, and Siri saved a changed
  catalog. All four Plex library phases and three server playlist phases finished.
  Apple Music cancellation was handled at its six-second source budget; its
  source remained pending. The handler returned incomplete at 09:41:34.191,
  approximately 16.7 seconds after entry, with the last-good Feed also refreshed.
  The UIKit assertion used to assist this check began only after actual
  background transition. This proves background discovery and queueing;
  download transfer completion is checked separately.
- Terminating that final process and cold launching the same artifact retained
  the Apple Music-only marker. Startup resumed at 09:45:27.110, expanded the
  handoff to all five enabled sources, completed every library and playlist
  follow-up, and cleared it at 09:45:38.334. Spotlight indexed three changed
  items at 09:45:40.440. The four-track playlist and offline membership survived
  the relaunch without a manual refresh.
- With no source handoff pending, foreground-only verification restored the
  previous three-track Spotlight applied snapshot while leaving the four-track
  Siri catalog intact. An ordinary Home/reopen cycle indexed the outstanding
  changes and acknowledged the four-track snapshot. No manual sync or indexing
  method was invoked. Spotlight waited for its existing foreground idle gate;
  Siri's shared catalog remained fresh throughout.

Warm user opening automatically started both pending transfers at
09:50:31.472–09:50:31.473. Native immediate-session tasks were scheduled at
09:50:34.696 and 09:50:35.234; each timed out approximately 60 seconds later
with zero received bytes and remained eligible for retry. Further attempts used
the existing 30-, 60-, and 120-second backoff. The uninterrupted foreground
control also timed out, so debugger pauses alone do not explain the stalled
files. Automatic queue startup is verified; successful media delivery remains
unresolved. Previously completed fixture files are positive controls, not
completion evidence for these two tracks. The immediate-session transport and
timeout predate this refresh change. Comparing the same prepared Plex item with
an independent client is the next isolation step, recorded in the project's
known-issues watchlist. Their retained queue state was captured before cleanup.

Before the claim-recovery follow-up, cold launch had a separate confirmed queue handoff gap. Recovery claimed both
pending rows at 09:45:22.290, but workers exited at 09:45:24.908 and the uncancelled
queue owner wound down at 09:45:25.438. Neither queue preparation telemetry nor
native transfer scheduling appeared. The cold-launch database retained both rows
as downloading at zero progress. A later warm activation recovered them. The
suspected path is `OfflineDownloadService.process` returning silently when an
inner error classifies as cancelled; the underlying error was not captured.
Those earlier captures alone did not establish reliable cold-start resumption.
The approved follow-up below addresses the silent cancellation path.

The controlled Plex mutation in these initial checks was adding existing library tracks
to a disposable playlist. It establishes background playlist discovery, offline
membership, and Siri publication. A newly added library media file or changed
album/track metadata had not yet been tested; the follow-up below covers a genuinely
new media file.

## Offline recovery follow-up

The phone was physically disconnected using Airplane Mode with Wi-Fi and cellular
off; no developer offline override was used. Initial checks exposed two related
recovery gaps: the coordinator did not initialize its offline flag from the
monitor's cached state, and an early foreground attempt could fail before the
fresh connected path arrived without retrying until the periodic fallback.

The corrected build is `0.4.0 / 202610071030.3615`, with runtime dylib UUID
`895B578E-1945-35AE-A52B-8032395DC69D`. Both iPhone and macOS builds passed.
The first newly installed launch required Apple developer tooling after an iOS
development-signing verification prompt; subsequent offline cold launch used the
actual Home icon successfully.

- A connected-path event at 10:39:40.389 started recovery at 10:39:40.397,
  completed all five library sources and applicable playlists, and cleared the
  handoff at 10:40:29.067 without a manual refresh.
- Actual Home/background transition occurred at 10:44:49.119. The registered
  handler entered at 10:44:49.192, saved five keys, retained the unchanged
  4,198-item Siri and Spotlight snapshots, and deferred remote work while
  offline. Its return at 10:44:50.953 reported incomplete with recovery needed.
  All library timestamps and sync cursor rows were unchanged.
- After process termination, an ordinary offline icon launch started PID 43026
  at 10:47:45. The five keys survived and recovery deferred at 10:47:49.551,
  without attempting source requests or advancing library timestamps/cursors.
  Cached Feed content and paused playback were visible.
- With the original connectivity settings restored, an ordinary warm icon
  opening activated the app at 10:51:39.663. Its first attempt correctly deferred
  against the cached offline path. The fresh online event at 10:51:40.699 retried
  recovery after endpoint checks at 10:51:42.313. All five libraries and their
  playlist follow-ups completed; the marker cleared at 10:51:50.438 and Spotlight
  indexed two changed items at 10:51:50.777. All five library timestamps advanced.
  The original six targets, 405 memberships, and 322 completed file records were
  unchanged. No manual sync or indexing method was invoked.

An unassisted OS delivery was subsequently observed on PID 43026 while the phone
was locked: the handler entered at 11:07:24.628 and returned at 11:07:49.763,
approximately 25.1 seconds later. No debugger or private invocation was used on
that process. All four Plex library phases committed; the first library still
owed its follow-ups, and Apple Music remained pending. The two-source marker
survived the deadline. This run fetched no changed Plex library items. It proves
one natural delivery and retained partial progress, not scheduling frequency or
a new library-file mutation.

Debugger-assisted handler invocation proves the registered route and observed
work. iOS chooses when to run refresh tasks;
see [Apple's background strategy guidance](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app).

No unit or integration suites were run. Both signed iPhone and macOS workspace
builds passed. Disposable playlist fixtures and their device-local downloads are
cleaned up separately from the user's existing offline selections.

Cleanup verification restored the original six target keys and all 322 completed
download rows (127 high quality, 195 original). The disposable playlist, target,
memberships, and four fixture download links were absent; the remote server
returned its original 38 audio playlists. Existing library tracks were preserved.

## Cold-start download claim recovery

`OfflineDownloadService.process` now returns a claimed download to pending when
an inner preparation request is cancelled while its queue worker remains active.
It preserves the selected quality and uses the existing retry backoff. A cancelled
queue worker or an active expiration handoff retains its existing lifecycle owner;
removed selections are not resurrected.

Physical verification used build `0.4.0 / 202610071110.4505`, runtime UUID
`CC2EFC5A-40C5-3B18-8B97-1FF45F2D9478`, on the same iPhone 16 Pro. The sole fixture
was album 7203, whose cached and remote contents both contained only track 7204.
It had no previous target, membership, or download. The selection was enabled
while genuinely offline, then the app was terminated and connectivity restored
from Home.

An ordinary icon cold launch started PID 43443 at 11:25:04 with no debugger or
manual queue call. Automatic recovery attempted track 7204 at 11:25:06.982;
native transfer scheduling followed at 11:25:08.563. HTTP 200 delivered 1,352,214
bytes, and the high-quality file was installed at 11:25:08.970. The persisted row
was completed with progress 1. A copy of the installed file passed `ffprobe`:
MP3, stereo, 44.1 kHz, and the full 43.52-second source duration. This proves normal
cold-launch startup and completed delivery for this fixture; it does not establish
that the two earlier FLAC prepared-media timeouts are resolved.

The cancellation branch was separately exercised with debugger assistance on
that same process. A one-shot preparation breakpoint stopped `/downloadQueue`
item creation, then the existing network-monitor routing callback advanced the
client revision without changing network settings or preferences. The stale
request raised `Swift.CancellationError` while its queue worker remained active.
At 11:36:05.746 the new log recorded a 30-second retry, and a database capture
confirmed pending/high, zero progress, and no file. Without another opening or
manual queue invocation, the worker retried at 11:36:36.060 and installed the
1,352,214-byte high-quality file at 11:36:38.105. The resulting row was completed
with progress 1; the copied file again had the full MP3 source duration. This is
controlled cancellation evidence, not proof that the earlier unlogged failure had
the same underlying cause.

A final debugger-assisted regression invoked the production expiration callback
and its normal `finishCurrentTask(success: true)` cleanup after the immediate
transfer waiter was registered, before `task.resume()`. At 11:40:00.411 the
immediate waiter was cancelled; at 11:40:00.434 a positive native background task
was scheduled. The worker deferred to its lifecycle owner rather than entering
the new preparation retry branch. Existing foreground recovery then resumed the
native transfer in the immediate session, and the row completed at high quality
with the same byte count. This covers registered-task handoff and recovery; it
does not prove natural OS expiration or expiration during an in-flight media body.

Both signed workspace builds passed. No unit or integration suites were run.
The separate prepared-media timeout watchlist remains open.

Final cleanup removed only the new album selection and its file. A fresh database
capture matched the original six targets, 405 memberships, and 322 completed
download records, including their quality, file paths, sizes, and completion
state (excluding Core Data bookkeeping and target update timestamps). Track
7204 had no remaining download row. No remote library objects were changed.

## Same-item phone transport and new library-file follow-up

The same production code at `6711cfec` was rebuilt and installed as
`0.4.0 / 202610071235.6711`, with running debug image UUID
`C597D778-74EB-31D5-BDE5-20BD98ABC33C`, on the physical iPhone 16 Pro over USB.
The signed workspace build passed. No production changes or test suites were
part of this verification. Evidence is retained in
`/Users/felicity/Documents/Codex/2026-10-07/ensemble-device-followup`.

### Earlier prepared-media timeouts

Both original FLACs fully decoded and matched their embedded PCM MD5s in the
separate source-integrity check. The existing prepared jobs, queue 25/items
31842 and 31843 (tracks 11927 and 11824), were available and returned complete
HTTP 200 bodies to an independent client. No original media was repaired or
replaced.

In the fresh phone process, debugger-created tasks called the production
`PlexAPIClient.fetchDownloadQueueMedia` method with the existing jobs and normal
download policy. The actual `BackgroundDownload` immediate-session path returned
797,052 and 1,444,527 bytes. Each phone body matched the independent prepared
body's SHA-256 and decoded completely, with durations 30.2 and 46.227 seconds.
The second, uninterrupted probe took approximately 1.10 seconds. The first included
a one-shot debugger inspection, so its elapsed time is not transfer latency.

The inspected production request used the HTTPS Plex Direct endpoint, 60-second
request timeout, immediate default session, and the existing Wi-Fi-only policy.
Original connectivity and download preferences were unchanged. These were
isolated transport probes, not persistent offline selections. The earlier
zero-byte stalls did not reproduce in this fresh session; their historical cause
remains unknown. If they recur, capture native task metrics and sanitized PMS job
status during the failed attempt before changing transport or fallback behavior.

### New file while an existing album was offline

Only a uniquely named disposable artist/album directory was added to Minibar's
Music section 3. Its first six-second MP3 was scanned, cached, and selected for
offline use before backgrounding. The baseline target contained one completed
high-quality track. The second MP3 was generated after the phone visibly reached
Home, and only the owned directory was scanned. The new source-scoped track was
absent from the phone's cache and offline membership before the refresh handler.

- Home/background transition: 12:50:39.896 local. New file created at
  12:52:15.902; Plex added the new track at 12:52:17.
- iOS delivered the registered refresh handler at 12:53:44.817, without a private
  scheduling invocation. The debugger was attached and continued, so this proves
  natural delivery and observed work, not debugger-free suspension/budget behavior
  or scheduling frequency.
- The incremental library phase fetched and committed one genuinely new track
  at 12:53:50.982–12:53:51.025. Awaited offline reconciliation recorded the album's
  two memberships and one new pending high-quality download at 12:53:51.744.
- Siri saved a changed shared catalog at 12:54:02.125. All four Plex library
  phases and three playlist phases completed. Apple Music's playlist phase
  exceeded its source budget, retaining its source key. The handler returned
  incomplete at 12:54:02.447, about 17.63 seconds after entry.
- Ordinary icon reopening automatically started the pending transfer at
  13:05:56.696 and installed its 100,818-byte file at 13:05:58.605. No manual sync
  or queue restart occurred. The persisted row was completed/high with progress
  1; the copied installed MP3 fully decoded for six seconds. Foreground catch-up
  cleared the remaining source handoff at 13:06:04.936.

### Confirmed parent-album metadata gap

Background discovery and offline download succeeded, but the cached album and
published Siri album still reported one track after Plex reported `leafCount=2`.
The background Siri snapshot was copied at the first foreground-active branch,
before foreground recovery or indexing could replace it. Ordinary reopening did
not correct the stored count. The new track was unplayed and unfavorited, so it
was not individually eligible for the existing Siri track catalog; the album
count is the meaningful Siri freshness check here.

Plex did not expose an updated parent-album timestamp. The incremental provider
selects albums through their own `addedAt`/`updatedAt`, then persists changed
tracks without refreshing their parents. Persistence retains the previous album
count, and Siri exports it directly. This behavior predates the refresh changes;
daily full metadata reconciliation can heal it. Browse views derive counts from
cached tracks, which can conceal the stored/Siri discrepancy.

The focused proposed fix is to fetch authoritative metadata for the distinct
parents of changed tracks, merge it with the album delta, and reuse existing
comparison/upsert handling before writing tracks. Use the parent's `leafCount`,
preserve existing counts when metadata is missing, retain retry eligibility on
request failure, and include material parent changes in `changedAlbums`.
Do not infer an album's complete count from an incremental track batch. This
repair was not implemented in the authorized verification pass; it is recorded
in the [known-issues watchlist](../../.claude/skills/known-issues/SKILL.md).
The subsequently approved deeper inventory repair and October 8 physical results
are recorded in [the membership follow-up](2026-10-08-plex-membership-reconciliation.md).

### Follow-up cleanup

The owned album selection was disabled through the public offline service before
server removal. The two generated files and their directories were removed, and
all four owned PMS metadata IDs independently returned HTTP 404. Remaining local
fixture metadata was removed through guarded, source-scoped repository APIs;
Siri and Spotlight were refreshed solely for cleanup. Both final snapshots omit
the fixture, and a fresh database capture contains no owned artist, album, or
track. The two unrelated cached tracks sharing rating key 17295 on other sources
are preserved exactly.

Final captures match the original six offline targets, 405 memberships, and 322
completed download rows, including quality, file path, size, and completion state
(excluding `Z_OPT` and target update timestamps). Owned temporary exports were
removed. Original connectivity/download preferences were unchanged, playback was
paused, and the CLI debugger was detached. Independent `devicectl` lock-state
verification confirmed `passcodeRequired=true` after Device Hub lock. No simulator
was used. The visible Feed retained its previously loaded fixture tile after
cache cleanup; this transient view snapshot is not evidence of a remaining
library object, and no extra provider refresh was performed.
