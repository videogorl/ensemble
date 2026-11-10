# Crash evidence and the shared library writer

**Date:** 2026-11-10
**Question (Felicity):** "i'm wondering if this will help some of the crashes I've seen."
**Scope:** read-only. Sources: every Ensemble file in iCloud Drive Downloads
(`~/Library/Mobile Documents/com~apple~CloudDocs/Downloads`), the Mac's
`~/Library/Logs/DiagnosticReports`, `known-issues`, `docs/investigations/`,
`ON_DECK.md`, the device backlog, and git history.

## Short answer

Partly. Of the eight crash or kill reports on file, two are freezes on the
iPhone SE 2 while opening a playlist, on a build from the day before the
duplicate-membership fix. The step 3 uniqueness constraint makes that cause
impossible by schema, and the 3a backfill removes duplicates still sitting in
old stores. A third SE 2 freeze (2026-08-16) has no session log, so it may or
may not be the same cause. The writer may also cut the Core Data share of the
SE 2's excessive disk writes. The other crashes are audio-engine aborts and
track-table row mismatches. Step 3 does not touch them, and they are already
fixed or belong to step 6.

## What exists

- **Mac:** no Ensemble reports in `~/Library/Logs/DiagnosticReports`; no local
  Xcode archives or dSYMs for the TestFlight builds, so Ensemble frames in the
  `.ips` files stay unsymbolicated.
- **iCloud Downloads:** 4 crash `.ips`, 1 `.txt` crash report in `.ips`
  format, 2 TestFlight `.crash`, 1 CPU resource and 1 disk-writes resource
  report, and 131 exported session logs (2026-03-19 to 2026-11-01). No
  sysdiagnose, JetsamEvent, spin or hang reports. (`SiriSearchFeedback-…ips`
  is a Siri analytics stub, not Ensemble.)
- **Xcode Organizer:** `GetTopCrashIssues` for `com.videogorl.ensemble` failed
  twice with "Error Downloading Crashes List", so TestFlight field crashes
  were not reviewed.
- **The app records no crash or hang data itself:** no MetricKit, no
  hang detector. A session log just stops at the kill.

## Each report

| # | Date, device, build | Kind | Main thread / evidence | Class |
|---|---|---|---|---|
| 1 | 2026-03-19, iPhone 16 Pro, dev `20260319.1022` | `0x8BADF00D` failed to terminate in 5 s, 10 s after launch | no thread frames in the report | unknown |
| 2 | 2026-03-28, iPhone 16 Pro, `…0665` | `EXC_BREAKPOINT` index out of range | `MediaTrackList.Coordinator.tableView(_:cellForRowAt:)` line 845 | track-table row mismatch |
| 3 | 2026-07-17, iPhone 13 mini, `…0696` | `SIGABRT` invalid number of rows | `UITableView _performDrop` → `endUpdates` | queue drag-drop row mismatch; fixed by `de9ea9c2` (2026-07-18) |
| 4 | 2026-08-08 16:54, **SE 2**, `…0708` (`b086b5a8`) | `0x8BADF00D` failed to terminate in 5 s, background | UIKit trait processing under SwiftUI `_UIHostingView.layoutSubviews` | **freeze opening a playlist** |
| 5 | 2026-08-08 18:29, **SE 2**, `…0708` | `0x8BADF00D` failed to terminate, foreground, thermal "serious" | SwiftUI release/dealloc under `ViewGraph.updateOutputs` | **freeze opening a playlist** |
| 6 | 2026-08-10, **SE 2**, `…0709` | disk writes, 1,073 MB in 107 min (limit 12 KB/s averaged over a day); no action taken | see below | write volume |
| 7 | 2026-08-16 16:16–16:22, **SE 2**, `…0711`, same PID 31212 | 90 s of CPU in 94 s, then a scene-update watchdog kill (10 s) in the background | SwiftUI `PlatformViewDisplayList.updateValue` / render on main | **main-thread render loop** |
| 8 | 2026-08-27, iPhone 16 Pro, `…0716` | `SIGABRT` | `-[AVAudioEngine connect:to:format:]` | audio graph; fixed by the fixed audio graph ([note](2026-08-28-fixed-audio-graph-stability.md)) |

Also known, but not in iCloud Downloads: the 2026-10-30 `AVAudioCompressedBuffer`
abort (streaming decoder, fixed in `d735bf26`); a 2026-11-08 SE jetsam at the
2,098 MiB per-process limit during an XCUITest accessibility snapshot
([note](2026-11-08-se-songs-xcuitest-snapshot.md)); and JetsamEvents dated
2026-11-03 and 2026-11-09 that are still on the SE and have not been exported
([note](2026-11-10-iphone-se-scripted-playback-checks.md)).

### Reports 4 and 5: the session logs line up

Each exported session log ends seconds before its crash report:

- `session-2026-08-08-080825.log` ends 16:53:54.082. Its last journey event
  is `push depth=0->1 destination=playlist tab=Playlists` at 16:53:54.067,
  during a failed connection failover. Nothing more is logged; the watchdog
  report follows at 16:54:22. The next session starts 52 s later.
- `session-2026-08-08-165446.log` ends 18:28:31.564. Its last journey event
  is `push depth=0->1 destination=playlist` at 18:28:31.242, while an
  incremental sync was mid-write (orphan check, playlist upsert, then the
  next source's timestamp prefetch). The report follows at 18:29:54, about
  80 s later, with the device thermal state "serious". The next session
  starts 98 s later.

Both builds are `b086b5a8`, one day before `d93b33fc` ("Fix duplicate merged
playlist bodies", 2026-08-09 09:33) and `c413c8b0` (serialized hub and
download writes). `known-issues` ("Cross-Source Snapshot Amplification")
records the same incident: an SE 2 froze opening a merged playlist after a
second source became visible, because concurrent delete-and-replace body
saves had written exact duplicate `CDPlaylistTrack` rows and doubled the
rendered list. The SE 2 here had two Plex servers and no Apple Music. The
"failed to terminate" reason means the system asked the app to quit
(hypothesis: Felicity swiped the frozen app away) and the main thread did not
respond.

The logs do not name the playlist, so "merged playlist" is inferred from the
known-issues entry and the fix timing, not read from these logs.

### Report 6: disk writes

The report's microstackshots (66 steps, 31 lost) split two ways:

- 37 of 66 samples: an Ensemble async task into a Foundation file write.
  Ensemble frames are unsymbolicated, so the writer is unknown. Hypothesis:
  the stream cache, offline downloads, or the session log file.
- 15 of 66: a Core Data `perform` block from Ensemble code, into `save` and
  SQLite writes.

Samples count time in a stack, not bytes. This build already contained
`d93b33fc`. No SE 2 session log covers that evening.

### Report 7: the 2026-08-16 render loop

The CPU report and the watchdog kill share PID 31212; the process had been
running since 2026-08-12. Main-thread samples sit in UIKit layout and SwiftUI
display-list updates for about 90 s, with one Core Data sample. The scene
then failed to finish a background transition within 10 s. There is no
session log for that day, so what was on screen is unknown.

## Session logs

Across all 131 logs, `ERROR` lines are WebSocket drops, network timeouts,
Apple Music request failures, CloudKit hidden-media saves, and streaming
underruns. No Core Data save, merge-conflict, or constraint error is logged
anywhere. Looking for a new session starting within 150 s of the previous
one's last line on the same device finds the two 2026-08-08 SE 2 crashes
above. The other quick restarts follow a background transition or a
settings change, which points to an ordinary relaunch, not a crash.

## What step 3 would and would not change

**Plausibly removes (hypothesis, strongest link first):**

1. **Freezes from duplicate playlist membership (reports 4 and 5).** Already
   mitigated in August by one serial membership context and a read-side
   filter. Step 3 makes duplicates impossible in the schema
   (`playlistSourceCompositeKey`, `playlistRatingKey`, `order`), deletes
   them from existing stores in the 3a backfill, and routes every body write
   through one actor that reuses rows by position. Today any new write path
   that skips the serial context could bring them back. After 3a it cannot.
2. **Report 7, only if it is the same amplification.** The SE 2 store may
   still hold legacy duplicates: the simulator store had 2,840 groups. The
   read-side filter covers `playlistItemsArray`, but whether every read path
   uses it is unverified. The 3a backfill would remove them either way.
3. **Part of the write volume (report 6).** Body writes that reuse rows
   instead of deleting and reinserting them, a single writer that skips
   unchanged inputs for both sources, and the end of the issue #98 refetch
   (decision 4) all mean fewer saves. That covers only the Core Data share,
   15 of 66 samples, and it was a warning, not a kill.

**Does not touch:**

- Audio-engine aborts (report 8, and the 2026-10-30 decoder abort). Both are
  fixed in the playback stack.
- Track-table and queue-table row-count crashes (reports 2 and 3). These are
  UIKit data-source consistency bugs and belong to step 6. Report 3 is fixed.
  The step 6d shared row model is the current owner of report 2's class; no
  recurrence is on file.
- Main-thread rendering cost for a large but correct playlist or library.
  The constraint removes doubled rows, not the cost of rendering many rows.
- The 2026-11-08 jetsam, which came from XCUITest accessibility traversal,
  and report 1, which has no frames.

## Evidence that would settle it

1. **From the SE 2 and the iPhone 16 Pro**, exported to iCloud Downloads:
   Settings › Privacy & Security › Analytics & Improvements › Analytics Data,
   every `Ensemble-*.ips`, `Ensemble.cpu_resource-*`,
   `Ensemble.diskwrites_resource-*` and `JetsamEvent-*` since 2026-08-16,
   including the 2026-11-03 and 2026-11-09 SE JetsamEvents. A JetsamEvent
   names Ensemble's resident pages and the reason (`per-process-limit` versus
   `vm-pageshortage`).
2. **dSYMs for builds `202603240708`, `…0709` and `…0711`** (App Store
   Connect › TestFlight › build › Download dSYMs, or Xcode Organizer once its
   crash download works). With them, reports 4, 5 and 7 and the disk-writes
   stacks name Ensemble's functions; for example, whether the file writes are
   the stream cache or Core Data.
3. **The SE 2's store**, copied read-only as decision 6 already plans for the
   iPhone 16 Pro: count duplicate `CDPlaylistTrack` groups per playlist. A
   non-zero count on the SE 2 makes report 7 a likely duplicate case; zero
   rules that out.
4. **After 3a ships**, the backfill should log how many duplicate rows it
   deleted per store (a count only, privacy-safe), so the first launch on
   each phone answers the question for that device.
5. **For future freezes**, export the log of the session that froze, together
   with the `.ips` from the same minute, as was done on 2026-08-08.
   `PersistentLogService` keeps only the last five sessions, so export before
   relaunching the app a few more times.

The design's step 3 section links here; no backlog entry is added because
nothing in this note is a new defect. Report 7's cause stays open until item
1, 2 or 3 above is available.
