# Plex membership reconciliation

## Problem and approved approach

The earlier [Background Refresh investigation](2026-10-07-background-refresh-recovery.md#confirmed-parent-album-metadata-gap)
found a new track correctly cached and downloaded while its persisted parent
album and Siri catalog retained the old track count. Plex can omit the parent's
`updatedAt`, and some album listings also omit `leafCount`. An incremental track
batch cannot establish the album's complete count.

The approved repair reuses the existing complete, paginated cleanup inventory
rather than adding per-album requests or a separate persistent reconciliation
queue. Track inventory includes parent IDs. A validated complete inventory
repairs missing or moved track relationships and calculates counts for every
surviving album, including zero. Metadata is fetched only for missing albums
and missing or moved tracks. Count-only persistence updates change only the
source-scoped count and local update time; unchanged counts do not save.

Album/track delta writes invalidate the existing durable inventory cursor before
committing. If refresh is cancelled after a delta saves, a subsequent pass still
reconciles membership even when timestamp comparison skips that saved delta.
The cursor advances only after validation, repair, confirmed orphan cleanup,
and count updates succeed. Material count changes are included in the existing
sync result, so awaited background Siri publication and foreground indexing
use the repaired values. WebSocket reconciliation shares the existing source
sync owner so its invalidation cannot race an inventory completion.

Missing parents, unexpected IDs, duplicate IDs, incomplete pagination, failed
metadata requests, and invalid counts fail the reconciliation without inferring
removals from that response. Targeted album child responses remain discrepancy
hints; they are not persisted as complete counts.

## Build provenance

Both iOS and macOS workspace builds succeeded; no unit or integration suites
were run. The initial six-file membership implementation was installed as
`0.4.0 / 202610071355.3552`, debug UUID
`3829D56C-DBDC-3587-9DDB-59B3F733CED7`. Natural background addition and cold
recovery evidence below belongs to that build.

The final seven-file implementation, including the approved notification
cancellation fix, is `0.4.0 / 202610080652.3552`, debug UUID
`43E7A98E-CA21-3CAB-A437-79D792D867FF`. Installed-version and process-path
receipts identify installation `6A947D7C-5C6A-4020-AC96-C36A5A74ED90`, PID 2155.
The SHA-256 source manifest matches every changed production file. Cancellation
recovery and ordinary notification removal were verified on this final build.

Physical artifacts are under
`/Users/felicity/Documents/Codex/2026-10-07/ensemble-membership-reconciliation`.
The device is iPhone 16 Pro `00008140-00023030117B001C`, iOS 27.0.1. Times below
are October 8, Pacific daylight time. CoreDevice independently confirmed wired
transport for the final checks.

## Physical verification

A fresh prelaunch snapshot contained six original offline targets, 409
memberships, and 324 completed downloads. This supersedes the previous day's
baseline, which changed naturally overnight. Ordinary startup skipped the
inventory sweep on all four unchanged Plex sources.

The isolated owned fixture is artist 17301, albums A 17302 and B 17304, and
baseline tracks 17303 and 17305, on Minibar Music section 3. Ordinary UI download
selection completed both tracks, yielding eight targets, 411 memberships, and
326 completed downloads. Existing selections and preferences were preserved.

### Natural background addition

Ensemble visibly reached Home at 06:20:31. A new six-second file was created
only in the owned album A directory and indexed as track 17306 at 06:21:19.
Complete PMS children confirmed A2/B1; the phone still contained A1/B1 and no
new track. The server response omitted `leafCount`.

With no debugger or profiler attached, iOS entered the registered Background
Refresh handler at 06:29:26.246. Minibar's album delta was empty; its track delta
contained one new track. The complete inventory repaired one album count at
06:29:38.877: 3,487 tracks, 458 albums, 1,282 ms for the inventory, repair,
cleanup, and count phase. The source library phase completed in 1.74 seconds.

Before reopening, the database contained A2/B1, track 17306 attached to A, and
its pending offline download. The changed Siri index was saved at 06:29:40.516.
The raw index count was not accessible through native App Group transfer.
Apple Music timed out during later work; Plex completed. The handler returned
at 06:29:50.494, about 24.25 seconds after entry, retaining only Apple Music's
source recovery marker. This establishes natural delivery and completed Plex
work for this run, not a scheduling-frequency guarantee.

Ordinary warm foreground re-entry at 06:37:17.862 automatically resumed the
new download. Its 100,818-byte body was installed at 06:37:20.313. The copied
installed MP3 fully decoded for six seconds with no errors. A later cold icon
launch, PID 1990 at 06:38, occurred after that transfer had already completed.
The artifact phase named `addition-cold-reopen` contains both events; it must
not be used to attribute this transfer to the later cold launch.

### Move and cold recovery

The owned added file was moved from A to B with its album tag updated. PMS
replaced rating key 17306 with 17307, so this exercises removal plus addition,
not a stable-ID reparent. Exact children confirmed A1/B2. The old app session
had already cancelled a notification callback and then repeatedly skipped
later notifications as “already in flight.” Its inventory cursor remained
invalidated and its cached counts stayed A2/B1.

An ordinary cold icon launch at 06:50, PID 2110, recovered A1/B2, removed the
old track, attached 17307 to B, and automatically completed its offline download.
No manual sync or private application function was invoked. This verifies
recovery of a persisted dirty cursor; interruption precisely after the new
track delta saved but before count persistence was not reproduced.

A larger existing source reconciled 9,399 tracks and 717 albums, repairing eight
tracks in 2,845 ms. Another source reconciled 3,756 tracks and 238 albums in
2,348 ms. These are elapsed runtime observations, not CPU, memory, or energy
measurements. Sweeps remain change-triggered or due after the existing 24-hour
interval; unchanged counts do not save.

### Approved notification cancellation repair

The pre-existing callback deferred busy-marker cleanup only when it was not
cancelled. Debouncing a newer event could cancel an active callback, permanently
leaving its section in the active set. The focused repair records an operation
UUID per section and always releases a matching owner. A cancelled operation
does not start the completion cooldown; an older owner cannot clear a newer
operation after stop/restart.

On the final build, two guarded scans of the owned artist tree were accepted
3.6 seconds apart. The first callback started at 07:05:00.255 and was cancelled
at 07:05:00.745. The next notification started at 07:05:03.805, completed the
3,487-track inventory at 07:05:09.149, and returned at 07:05:09.462. Same PID
2155; no reopening or manual sync. `ws-cancellation-live.log` preserves this
sequence. An earlier scan following UI full sync missed the overlap and is not
cancellation evidence.

The owned 17307 file was then removed and its directory scanned at 07:05:42.
PMS confirmed A1/B1 and HTTP 404 for 17307. The ordinary notification healed B's
visible count by 07:06 in the same session. The database confirms A1/B1, only
the two baseline fixture tracks, and 326 completed downloads. All original
324 download rows, six targets, and 409 memberships were preserved exactly,
excluding Core Data version fields and target refresh timestamps.

## Verification limits

CLI debugger attachment failed on both Wi-Fi and USB following the device OS
update. No live breakpoint or Swift expression was established. Native App
Group file transfer denied the root-level Siri index. Consequently, publication
is proven by the repaired persisted count and successful changed-index save,
but the raw saved Siri album count and a spoken Siri request remain unverified.

Time Profiler/Activity Monitor could not resolve a CoreDevice-confirmed live
PID and produced no trace. CPU, peak memory, and energy remain unmeasured.
Malformed/partial inventory rejection, zero-track album handling, stable-ID
reparenting, and the precise interrupted-after-delta retry barrier were inspected
and built but not independently exercised on the phone. These gaps do not
establish a defect and should not be presented as passed runtime checks.

## Cleanup

The two owned album downloads were removed through ordinary UI. The final
snapshot matches all original six targets, 409 memberships, and 324 completed
downloads, with no missing, modified, or extra rows (excluding Core Data version
fields and target refresh timestamps). Normal server notifications removed the
fixture albums and tracks from the device cache.

Guarded server cleanup removed only owned files/directories. An independent
connection verified all seven recorded IDs 17301–17307 returned HTTP 404, the
exact artist query was empty, and all owned current/historical paths were absent.
No recovery fixture was created. See `server-fixture/cleanup-independent-receipt.json`
and `final-cleanup/baseline-comparison.json` in the artifact directory.

A separate suspected full-sync intent-coalescing limitation found during static
review is recorded in the [known-issues watchlist](../../.claude/skills/known-issues/SKILL.md#full-sync-joining-narrower-source-work).
It was not reproduced or repaired in this task.

Playback remained paused. Device Hub locked the phone; CoreDevice independently
reported `passcodeRequired=true` for the exact physical device in
`device-preflight/final-lock-receipt.json`. No owned debugger/profiler process
remained and no temporary app exports were created. No simulator was used.
