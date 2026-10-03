# macOS browse container and sidebar selection

Date: 2026-10-01

This follows [the sidebar latency investigation](2026-10-01-sidebar-latency-followup.md).
The delivered container improves the measured layout work and toolbar ownership,
but does not eliminate navigation stalls. The user confirmed no sidebar flashing
on a fresh-launch Songs → Artists → Songs journey, separately from their earlier
warm-navigation confirmation.

## Causes and alternatives

Two independent problems were traced to the shared root:

- `SidebarView` published `NavigationCoordinator.selectedTab` synchronously from
  the native List selection binding. LLDB showed this call underneath
  `OutlineListCoordinator.outlineViewSelectionDidChange` and `UpdateGroup.ensure`.
  The baseline produces “Publishing changes from within view updates” warnings.
  Updating local selection in the binding and committing coordinator changes
  from `onChange` removes these warnings in the measured journeys. A pending
  input marker distinguishes sidebar input from external routes, whose already
  pushed paths must survive.
- `nativeExplorerColumns` selected different two- and three-column SwiftUI
  containers. Entering Artists, Genres, or All Playlists replaced the split root
  and its sidebar. Keeping one native split controller removes that structural
  replacement. The earlier flash attribution was an inference from source;
  the user's cold and warm checks now establish its absence in those journeys.

A focused comparison build changes only the selection transaction at the
original SwiftUI root. It is much smaller and keeps automatic SwiftUI environment
and toolbar propagation, but still replaces the split root. It removes warnings
without a consistent speed improvement in this comparison.

The already-approved broader candidate uses one `NSSplitViewController` with
permanent sidebar, picker, and detail hosts. Ordinary sections collapse the picker;
Artists, Genres, and All Playlists retain it next to independently navigable
details. This preserves native divider resizing and gives one detail host ownership
of the title, toolbar, and search. The cost is a macOS bridge with explicit app
environment forwarding, sidebar geometry publication, and shared picker controls.
It is retained because it corrects the structural ownership problem and reduces
measured work. It adds no navigation engine or hidden collection of screen trees.

Remaining stalls are still predominantly SwiftUI/AppKit layout and graph work.
These captures do not justify a further container redesign, screen prewarming,
or changes to playback, Plex, or artwork services. Any implementation expansion
requires another user decision.

## Delivered code and removed experiments

- `MacBrowseSplitView` owns the native panes, collapses the picker, forwards app
  context, and publishes sidebar geometry after the current layout transaction.
  It copies specific public/app environment values, not the complete private
  SwiftUI environment. Only the detail host bridges window title and toolbars.
- `MainTabView` retains one native macOS container for every root selection and
  commits actual sidebar input outside the List's update. Downloads controls
  are shared; native sidebar geometry drives the existing root mini-player.
- `NativeBrowseSection` supplies picker search and toolbar controls through the
  detail NavigationStack. Search bindings still target the existing view models.
  Artists/Genres/Playlists leaf search and toolbar contributions are suppressed
  only in the macOS picker host. iPad retains SwiftUI `NavigationSplitView`.
- Artist filter/sort and playlist create/sort controls have one implementation
  each. Optional presenter bindings reuse the existing leaf-owned sheets; there
  are no duplicate filter or create screens.
- `SongsTrackListHost` permits top underlap at its actual macOS native scroll
  owner. The blanket `NSHostingController.safeAreaRegions = []` experiment was
  removed: it made Home's first heading overlap the toolbar. Home keeps its normal
  hosting safe area, and its initial heading is correctly below the title.
- `MediaDetailSurface` explicitly gives secondary macOS glass actions a clear
  tint. Songs Shuffle no longer inherits the purple system accent from its
  separate hosting root; primary Play retains its accent treatment. iOS is unchanged.

Custom picker header/chrome, duplicated control builders, full-environment
forwarding, search identity replacement, and deferred pane-root updates were
removed from the delivered source. Full-environment and identity experiments
caused layout/search feedback hangs and were rejected. The temporary focused
comparison checkout was removed after preserving its exact patch and proof.
Frozen binaries and traces remain outside the repository for review.

## Instruments comparison

Same Mac, real cached library, paused playback, unfiltered lists, no selected
artist before each launch, and a 2304 × 1766 window. Each variant has two fresh
processes: one starts on Songs, one on Artists. Each performs four alternating
mouse transitions. The first destination visit is cold; subsequent visits are
warm. “Cold” retains disk/artwork caches and is not initial library sync.

The Time Profiler plus Activity Monitor recordings ran without concurrent builds,
tests, or exports; thermal state was nominal. A fresh screenshot precedes each
mouse action, and a fixed 2.2-second dwell keeps subsequent AX observations out
of the measurement window. Sampled main-thread work is counted from 150 ms before
to 1 second after `tabChanged`, including the focused variant's pre-commit List
work. Potential hang intervals must overlap the selection or begin within 100 ms
afterwards. Capture-wide accessibility stalls are retained separately.

| Measurement | Baseline | Selection fix only | Stable native panes + selection fix |
| --- | ---: | ---: | ---: |
| Cold Songs → Artists, sampled main-thread work | 403 ms | 471 ms | 310 ms |
| Cold Artists → Songs, sampled main-thread work | 564 ms | 554 ms | 344 ms |
| Warm median, six transitions | 471 ms | 499 ms | 299 ms |
| Warm range | 398–538 ms | 472–519 ms | 251–351 ms |
| Cold selection-overlapping potential hangs | 383 / 555 ms | 460 / 548 ms | 332 / 337 ms |
| Warm selection-overlapping potential hangs | 389–527 ms, 6/6 | 450–510 ms, 6/6 | 267–292 ms, 5/6 |
| Reentrant-publication warnings, eight transitions | 60 | 0 | 0 |

This is one cold observation per direction/variant and six warm transitions,
not a statistical benchmark or click-to-paint measurement. Sidebar/picker widths
differ: baseline/focused 260/299.5, native 220/239.5. The first baseline Artists
capture lost its correlating session log to retention and was repeated in a new
process; the unmatched capture is excluded. Earlier observer-contaminated runs
are not used for this comparison. No hang flag on one transition means only that
Instruments did not flag that interval; it does not establish zero stall.

[metrics.json](artifacts/2026-10-01-macos-native-container/metrics.json) records
per-transition samples, all potential hang intervals, warning counts, protocol
limitations, executable/source hashes, versions, PIDs, and raw artifact location.

## Final verification

Final macOS candidate: `0.4.0 (202610011350.8943)`, executable SHA-256
`6f43c5126fab44ebacbcb9fbd36e9fca3e7cf4a9eb096301e75a2da9f31b3559`.
Both profiling PIDs and the final relaunched PID were launched from the explicit
frozen `.app` and checked against its executable path. All eight source hashes
still match the final artifact after the UI checks.

- Signed macOS Release workspace build passed (`native-neutral-build.log`).
- Generic iOS Debug workspace build passed with signing disabled
  (`native-final-ios-build.log`); this is compile proof, not device proof.
- Existing focused EnsembleUI tests passed: 31, zero failures. Selection:
  `NavigationRootHelperTests|PlatformAndDragPolicyTests|EnsembleUITests.testNative`.
  No layout-only or implementation-mirroring tests were added.
- Final build: Artists search ABBA narrows the picker; album push and Back restore
  the selected artist and keep the picker. Switching while search is focused
  changes to Songs' correct prompt/binding; ABBA matches Songs and can be cleared.
- Final build: Artists sort Date Added changes the picker order; Name restores
  alphabetical order. Artist and Songs filter sheets open from the toolbar.
  The Artist Downloaded Only toggle persists its state, but does not filter
  results: see the baseline failure below. It was restored to off.
- Final build: Genres retains three panes and changes from picker search to
  album search on selection. All Playlists exposes native toolbar create/sort;
  the existing New Playlist sheet opens, empty Create is disabled, and Cancel
  closes it without a mutation. Sort options are present.
- Final build: Songs has neutral Shuffle and accented Play; the native track
  list scrolls under the toolbar. Home's populated initial heading clears the
  toolbar. Home's scrolled toolbar legibility still fails, also in the baseline.
- Final build: sidebar hide/restore changes the native splitter from 220 to -1
  and back, with the player centered in the expanded/restored content region.
  Downloads and Settings open their correct windows and close normally. Settings
  displays the final build version. Playback remains paused and filters neutral.
- User independently confirmed cold no-flash on the final freshly launched build,
  separately from warm no-flash. The user previously confirmed both native
  dividers resize normally; the tool's unchanged drag positions do not establish
  a divider failure. No final frame-by-frame visual latency recording exists.
- Earlier signed iPad simulator verification used exact UUID
  `66A1479E-5175-437C-83B9-B74ACE002DEB`, actual iOS 27.0: Artists/Genres three panes,
  Songs two panes, and sidebar overlay worked with an empty library. The simulator
  was shut down. This predates the final macOS-only selection/tint/safe-area
  corrections and does not prove populated iPad push/Back flows.

## Baseline failures, regressions removed, and untested areas

Home's toolbar has no effective scroll-edge protection over artwork in both the
baseline and final build. Its first-heading overlap was introduced by the global
safe-area experiment and corrected before the final artifact. Remaining Home
toolbar legibility needs a focused investigation of the native scroll/toolbar
owner; it is not declared fixed.

Artists' Downloaded Only is a pre-existing functional failure.
`MediaFilterEngine.filterArtists` at the baseline and final code never reads
`showDownloadedOnly`; the LibraryViewModel artist pipeline does not consume
track download state. A focused follow-up should feed source-scoped downloaded
artist identities into that existing pipeline and filtering function, with one
regression test for downloaded/undownloaded sources and runtime verification.
No Core filtering implementation has been changed in this patch.

The baseline's reentrant-publication warnings disappear in both fixed variants.
Final build warnings match existing MiniPlayerBackground design-token import,
Watch app category, and AppIntents metadata warnings. A clean focused build also
shows existing Core/Watch async, implicit-self, and deprecated-menu warnings in
untouched files. Instruments exports report tool/schema compatibility warnings;
these are not app regressions. Only available exported tables are used.

Unsupported conclusions include universal absence of flashes/crashes, zero
regressions, eliminated stalls, or equivalent behavior on all supported OSes.
Older macOS 12–14 runtime, populated final iPad flows, phone/Watch runtime,
dynamic appearance/accessibility permutations, narrow-window limits, destructive
playlist operations, network refresh, and playback changes were not exercised in
this patch. The final candidate was inspected on macOS 27.0.1 (26A434).
