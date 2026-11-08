# SE Songs XCUITest snapshot termination — 2026-11-08

## Result and target

`PhoneBrowseAcceptanceUITests.testSongs` is no longer skipped. All five browse
tests passed twice consecutively, with zero skips/failures, on Guest's iPhone SE,
UDID `00008030-00090C493C13402E`, iOS 27.0.1. Core/UI package suites and the
standalone iOS Debug build passed after the change.

Source was local develop `a8b943ad` plus this task's changes. The runner rebuilt
and installed the worktree artifact before the checks. Installed Ensemble was
0.4.0 `202611081007.8943`, matching the produced app's bundle version.

## Cause

Targeted firstMatch existence/frame queries resolve quickly. Ordinary event
synthesis requires broader accessibility snapshot/interruption processing; the
target app is killed before input, producing misleading invalid-element errors.

`JetsamEvent-2026-11-08-091549.ips` reports Ensemble PID 5025 killed at
09:15:48.97 for `per-process-limit`, as the largest process, with 134272 resident
16 KiB pages: 2098 MiB. The timestamp matches the first toolbar tap's interruption
failure. Native table traversal/materialization is the suspected allocation
source; no allocation profile was captured to identify individual allocations.
Manual Device Hub toolbar taps remained responsive.

Narrow queries, a control identifier, coordinate taps and keyboard-event probes
did not avoid broad snapshot processing. Those experiments were reverted. No
private XCTest APIs or SpringBoard-coordinate workaround remains.

## Change and boundary

The user approved an automation-only accessibility hook after the test-only
probes failed. `DeferredLayoutTableView` now supplies a bounded accessibility
container only in DEBUG, when the existing automation launch options are enabled
and the start surface is Songs. Its elements are the table header, current
`visibleCells`, and footer. Array and indexed accessibility-container APIs use
the same derived collection. Overriding the element-array getter alone did not
prevent the snapshot failure; the indexed container methods were also required.
No visible-row array is retained between queries, so scrolling exposes new rows.

Outside that launch configuration the methods forward to UIKit; release builds
contain none of the hook. Library data, rendered rows, scrolling, sort/filter
behavior and playback are unchanged. This fixes automation snapshots, not the
normal full-tree accessibility memory behavior.

Two previously unreachable test assumptions were corrected: the nested Songs
sort menu exposes its direction chevron as a child image rather than as the
button identifier; the table retains Play/count cells when search has zero
tracks. The test now identifies track rows by their Track Actions control and
verifies those disappear. It also scrolls away and back, checking that the
accessible track titles change and restore, before exercising sort/filter/search.

## Evidence

All paths below are under `/tmp/ensemble-songs-20261108/`; temporary files may expire.

- `browse1.xcresult`, `browse2.xcresult`, corresponding `.log` and `-summary.json`:
  two consecutive runs, each five passes and zero skips/failures.
- `browse1-attachments/673CFE06-A074-4F83-9705-23FE942FE772.txt`:
  accessible first title changes from `01 - Introduction` to `06 - Time to Dance`
  after scrolling. The same test restores the initial row before control checks.
- `core-final.log`: Core package passed (XCTest and Swift Testing).
- `ui-final.log`: UI package passed.
- `ios-build-final.log`: standalone iOS Debug build succeeded through the shared wrapper.
- `installed-final.txt`, `final-launch.log`: final device artifact/launch evidence.
- `crash-list-before-acceptance.txt`, `crash-list-after-acceptance.txt`:
  identical device crash-log listings across both passing acceptance runs.
- `JetsamEvent-2026-11-08-091549.ips`: original device termination evidence.
- `songs1`–`songs8` `.log`/`.xcresult`: unsuccessful test-only diagnosis probes.
- `hook1`–`hook4` `.log`/`.xcresult`: hook iteration and focused Songs verification.
- `final-sort.jpg`, `final-filters.jpg`, `final-paused.jpg`: final manual state.

## Cleanup and remaining coverage

After refreshing Device Hub's input connection, final manual readback confirmed
Date Added descending, Downloaded Only off, no selected genres, empty search and
Play shown for Cybertronics. Playback remained paused. Library/playlist/settings
data were not edited. The phone was locked through Device Hub, its display went
dark, and the GUI lock was released. Home wakes this phone without a passcode.

No simulator was used. Mac, iPad and Watch behavior was not exercised by this
task; the hook is confined to the specified DEBUG automation launch.
