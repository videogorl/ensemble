# Browse container simplification

## Scope and changes

Baseline: clean `6abef3b3` on `t3code/bug-bash-investigation`. This implements
the three approved simplifications without changing split ownership, navigation
engines, root geometry, or package boundaries.

- Deleted `MacBrowsePickerKey` and its environment write/read plumbing. Artists,
  Genres, and Playlists derive Mac picker behavior from `.selectionColumn`.
- `ArtistBrowseControls` and `PlaylistBrowseControls` now own their native sheets
  and local presentation state. Deleted parent sheet state, optional public
  presentation parameters, external bindings, fallback bindings, and leaf sheet
  presenters. Both compact and split toolbars use the same controls.
- Moved existing playlist server-option redaction and pending-toast code into
  `PlaylistBrowseControls`; the existing ViewModel mutation remains the only
  creation path. Offline disabling and aggregate success/failure behavior remain.
- Replaced four search switches with one tuple selecting binding, prompt, and
  visibility together. Existing per-section query and visibility rules remain.

Five production files: 100 lines added, 158 removed, **58 fewer lines**. No new
types, services, dependencies, observers, timing workarounds, or tests. Existing
coverage protects the navigation and mutation contracts; presentation is checked
at runtime. Updated the UI mechanics reference to describe the final ownership.

Kept the permanent AppKit panes, explicit environment forwarding, sizing guards,
coalesced geometry publication, and guarded sidebar coordinator publication.
Removing those previously caused layout or navigation failures. No failed code
experiment remains in this change.

## Artifact proof

Artifacts and logs: `/tmp/ensemble-browse-cleanup-20261002`; `provenance.json`
records source hashes, exact app paths, versions, and process IDs.

The frozen baseline is `/tmp/ensemble-filter-toolbar-20261001/Final.app`,
build `202610011516.6362`, debug-library SHA256
`2fe3586844e553041d37d9e7ea79a3b5a03e12396161566be2c5456954f9243a`.
It was explicitly launched and inspected again, including baseline sheets and
layout failures. Baseline Mac PIDs: 4376 and 23548.

The new frozen Mac app is `Final.app` in this pass's artifact directory, build
`202610020650.6331`, debug-library SHA256
`8430b02ebe041c1c1c7ed95d301913891b35ae6ed609de2403fd86a33a812979`.
Fresh explicit launches and executable paths verified PIDs 12161 (Songs), 18707
(Artists), and 26830 (Home). Settings also displayed the new build version.

Simulator installed-library hashes matched the built artifacts, with exact
installed executable paths verified for the running processes:

- iPad (A16), iPadOS 26.5: `08CA3DD8-D174-40E9-A361-62B95671B969`, PID 13206,
  build `202610020651.6331`.
- iPhone 17 Pro, iOS 26.5: `8C415280-3613-483E-88E4-869FA53C6063`, PID 16714,
  build `202610020652.6331`.

## Verification on final production code

| Check | Result |
| --- | --- |
| Navigation/platform/native helper tests | 31 passed, zero failures; `ui-tests.log` |
| Existing creation source, partial-success, placeholder/rollback tests | 3 passed, zero failures; `creation-tests.log` |
| macOS Debug workspace build | Passed; `macos-build.log` |
| iPad and iPhone simulator Debug workspace builds | Both passed, separate DerivedData; `ipad-build.log`, `iphone-build.log` |
| Cold Songs/Artists navigation | Fresh Songs → first Artists → Songs; separate fresh Artists → first Songs; correct panes/search. User reported no flashing on the cold round trip. |
| Warm Songs/Artists navigation | Repeated toggles preserve the sidebar and restore each section's search and panes. Snapshots cannot exclude every brief frame-level flash. |
| Songs Shuffle | Neutral styling visually confirmed on fresh Songs. |
| Artists Filter | Repeated Downloaded Only on/off, dismiss/reopen preserves state, empty results restore to rows. |
| Artists search/sort/Back | ABBA search and selection, album push/Back, Date Added selection and Name restore passed. |
| Genres/Playlists search | Independent Rock/Ambient queries survive section switches; queries restored to empty. Selected genre/playlist retains picker and shows detail search. |
| Mac New Playlist | Name input retains focus; empty name/no sources disables Create; Cancel/reopen resets input and source selection. |
| Home cold/warm | Separate cold Home launch and warm Songs → Artists → Home return; heading safe area, native toolbar material while scrolling, return to top, Edit open/dismiss passed. Edit clipping remains below. |
| Sidebar/player | Hide/restore passed; player remains usable but placement fails below. |
| Downloads/Settings | Downloads → Manage Downloads → Back/close; Profile → Merging → Back/close passed, no preference changes. |
| iPad sheets | Artists Filter narrows cached downloads to AJR, Gungor, twenty one pilots; reopen retains toggle, then restore off. New Playlist typing/focus, enabled Create, Cancel passed. |
| Compact phone sheets | Artists Filter open/dismiss; New Playlist typing, enabled Create, Cancel passed. |

No server playlist was submitted. Some automation taps returned success without
changing the UI; screenshot-derived coordinates delivered the intended input.
The initial iPad session lease was stale and was closed before opening this
thread's pinned session. These are tool limitations, not counted as app passes.

## Instruments and warnings

Matching fresh-Artists Time Profiler captures included first navigation to Songs
and three warm transitions, with the same AX inspection sequence at 1100×883.
No app builds ran during these captures. Both exports succeeded:

| Capture | Potential-hang intervals | Intervals classified Hang | Longest |
| --- | --- | --- | --- |
| Baseline, PID 23548 | 13 | 6 | 843.59 ms |
| Cleanup, PID 18707 | 14 | 6 | 873.89 ms |

Around 70–71% of main-thread samples within the six longer intervals in both
captures include accessibility traversal. `stall-summary.json` contains interval
durations and sample proportions. This is one automation-driven capture per
build, with active accessibility inspection and Instruments compatibility
warnings. It proves neither a speedup nor the absence of a small performance
regression. Human navigation without concurrent AX traversal is still needed
to isolate ordinary click latency. These remaining stalls are not fixed here.

The SwiftUI-template capture reached its time limit but hung finalizing with a
large graph dump. Its recorder was stopped; that incomplete trace is excluded.

Baseline and cleanup both emit the NSTableView reentrancy and ambiguous
SwiftUI toolbar-item sizing warning classes. No state-during-update or cycle
warning was observed in the final session logs. The fresh build reports existing
WatchCore implicit-self and PlaybackService unnecessary-await warnings, absent
from the prior incremental Mac build log; their source is unchanged from
baseline. No compiler warning points into the five changed files. Existing
AppIntents metadata warnings remain. System network text logs were redacted
before being retained for the report.

## Remaining failures and untested cases

- At 1100×883, hiding the 220-point sidebar leaves the mini-player about 110
  points to the right of full-window center, in both baseline and cleanup.
- Home Edit partly clips at the right edge after scrolling, in both builds;
  it remains clickable. This is separate from title readability and safe area.
- The profiling stalls above remain; automated traces do not certify smooth
  human navigation or zero regressions.
- Actual provider playlist submission, physical-device runtime, older supported
  OS runtimes, Watch runtime, and divider dragging were not revalidated here.
  The native divider implementation was not changed.

All final builds/tests used the final production source; subsequent edits only
document results. The completed logical change is committed locally; no push or
merge is part of this pass.
