# Sidebar navigation follow-up

Date: 2026-09-30

## Change and ownership

`SidebarView.nativeExplorerColumns` gave `NativeBrowseSection` an `.id(tab)`.
Every Artists/Genres/All Playlists switch therefore replaced the entire native
three-column split, including its sidebar, even though its column structure was
unchanged. The baseline Time Profiler capture reproduced a flagged main-thread
interval on all 16 transitions in a repeated sidebar journey.

Removed that identity reset. The existing split now survives switches among
those three browse sections. No additional navigation owner, hidden duplicate
root, presentation bridge, dependency, or layout delay was introduced.

Keeping the split alive also keeps its selection observer alive. That observer
previously watched only the selected item's ID and cleared the active tab's
detail path on every change. It now observes the tab and item ID together:
changing the item within a tab clears its old nested detail; switching tabs
preserves the destination tab's available path. The compact-column preference
uses both the selected item and the path. Existing sidebar playlist/pin routing
rules still belong to `SidebarView`.

Selected detail identities remain: their loaders belong to the selected item.
The two/three-column root boundary also remains when entering or leaving native
browse sections. A throwaway native SwiftUI prototype confirmed that an empty
middle view in a three-column split still reserves a blank middle column. It
does not provide the existing two-column layout. Replacing that boundary needs
separate design and runtime evidence.

## Instruments comparison

Used signed macOS Release builds, the same sandbox/library, and the exact
running executable paths. Baseline source: `8cdcc099`; candidate: only the two
production Swift changes described above. Frozen apps, raw traces, build/test
logs, and exports are in `/tmp/ensemble-sidebar.lIRenS`. Portable source/binary
hashes, PIDs, timestamps, and per-event measurements are in
[metrics.json](artifacts/2026-09-30-sidebar-navigation-followup/metrics.json).

Host: Mac UUID `E3A3882D-C3B6-5B96-805E-B89E87E9E955`, macOS 27.0.1
(26A434), Instruments 27.0 (27A266a). Both conditions used the same zoomed
window, verified by 4968 × 2780 screenshots, with animations enabled.

Four accepted recordings alternated candidate/baseline/candidate/baseline.
Before each capture, freshly launched the exact frozen app, restarted the same
existing playback track, and warmed the journey once. During each capture,
clicked Home → Search → Albums → Songs → Artists → Genres → All Playlists →
Songs twice, with a fixed 1.8-second dwell after each input. No compiler, package
tests, export processing, or accessibility-tree snapshots ran during recording.
All 16 accepted journey events and their analysis windows fit inside each trace.
Playback timeline reports advanced on the same track during those events.

Because the candidate has fewer flagged events, compare all matching events
using main-thread sample weights in fixed 1.5-second windows after their logged
tab changes. Averaging only the remaining flagged intervals would select a
different population. Inclusive sidebar samples count each sample once if its
stack contains `SidebarView`; they are part of main-thread work, not an additive
metric.

| Transition | Baseline mean sampled main-thread work | Candidate mean | Events flagged over 250 ms |
| --- | ---: | ---: | ---: |
| Artists → Genres, four events per condition | 604.3 ms | 249.0 ms | 4/4 → 1/4 |
| Genres → All Playlists, four events per condition | 711.0 ms | 273.8 ms | 4/4 → 2/4 |
| Combined browse switches, eight events per condition | 657.6 ms | 261.4 ms | 8/8 → 3/8 |

The targeted switches used **60% less sampled main-thread work**. Inclusive
sidebar work averaged 14.6 → 2.1 ms, consistent with avoiding sidebar
reconstruction. Across the entire mixed journey, flagged events fell from
32/32 to 27/32. All 24 other transitions per condition still had flags; their
mean sampled work was 858.3 → 830.4 ms, a much smaller difference.

These are two recordings per condition on one Mac, not a general latency or
frame-rate guarantee. Fixed windows can truncate stalls longer than 1.5 seconds
and include unrelated main-thread work. System/input accessibility work remains
in the stacks despite excluding tree snapshots. No memory/leak or physical
device performance improvement is established by this comparison.

Excluded from the comparison: the initial reproduction used a smaller window
and different playback state; one recorder stalled before starting; its retry
ended before most inputs. Their timing/geometry did not match the accepted
recordings.

## Verification

- Signed macOS Release and iOS Debug simulator workspace builds passed.
- Existing `NavigationRootHelperTests` and `PlatformAndDragPolicyTests` passed:
  30 tests, no failures. Command: `swift test -q --package-path
  Packages/EnsembleUI --filter
  'NavigationRootHelperTests|PlatformAndDragPolicyTests'`. These cover navigation
  policies, not SwiftUI lifecycle performance; Instruments and direct UI checks
  are the evidence for this change. No layout-only unit test was added.
- On the candidate Mac build, opened AJR → Neotheater, switched Genres → All
  Playlists → Artists, and verified the same album and native Back button.
  Back returned to AJR. Selecting Aimee Mann replaced the artist detail and
  removed the nested album path. Artist browse scrolling survived a round trip
  through Genres. Native sidebar hide/show and window zoom retained the detail
  and mini player. A divider drag did not resize the column and is not resize
  evidence.
- Freshly installed the candidate on the iPad A16 / iOS 26.5 simulator, UUID
  `08CA3DD8-D174-40E9-A361-62B95671B969`. Opened AJR → Neotheater, switched
  Genres → All Playlists → Artists, and verified the album remained. After
  dismissing the native sidebar overlay, Back returned to AJR.
- Freshly installed the same candidate on the iPhone 17 Pro / iOS 26.5
  simulator, UUID `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`. Its compact tabs
  opened ABBA → Gold: Greatest Hits, switched to Playlists and back to Artists,
  restored the album, and navigated Back. This is a compact-tab regression
  check; it does not measure the sidebar or verify expanded iOS 27 phone scenes.
- Both simulator installed executable hashes matched the new build:
  `eae40b3690553a902ced0d19f7b295f3cee4f75ffd89b8f431f2fe662358fcc3`.
  Version `0.4.0 (202609301406.8099)`, verified running PIDs 23476 and 24664 at
  their installed executable paths. Screenshots are `ipad-restored-album.png`
  and `phone-restored-album.png` in the run directory.

## Remaining work

The expensive two/three-column replacement, other native SwiftUI/AppKit layout
work, and system accessibility work remain. This change removes a redundant
reset within the three-column browse layout; it does not eliminate every sidebar
stall. Further root/layout changes need their own matched measurements and
navigation/chrome/compact-layout checks. Expanded physical-phone iOS 27 behavior
was not verified in this pass.
