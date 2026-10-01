# Artists filtering and Home toolbar readability

## Scope and baseline

Work stayed in `t3code/bug-bash-investigation` in the existing Minibar checkout.
HEAD was `6f3d6b290f6fc2d7b2466d2ddc557d13d9f858dd` with a clean worktree
before edits. The permanent native panes and single detail-host toolbar/search
owner are unchanged. No push, merge, deployment, permission changes, provider
mutations, or playback changes were performed.

Local artifacts: `/tmp/ensemble-filter-toolbar-20261001`. The fresh baseline
and final macOS apps are frozen as `Baseline.app` and `Final.app` there.
`provenance.json` records source/binary hashes, targets, and process IDs.
The Debug macOS artifacts share build version `202610011516.6362`; their
`Ensemble.debug.dylib` hashes differ and explicit process paths identify them.
The final macOS library hash is
`2fe3586844e553041d37d9e7ea79a3b5a03e12396161566be2c5456954f9243a`.

## Reproduction, causes, and delivered fix

**Artists:** On the fresh baseline, enable Downloaded Only from the Artists
filter sheet and close it. The A–Z rows remain; reopening confirms the toggle
is on. This Mac has no downloaded tracks. `MediaFilterEngine.filterArtists`
never consumed the flag, and the artist pipeline did not observe tracks.

`LibraryViewModel` now derives downloaded artist identities from downloaded
tracks, using both source key and artist rating key. The existing initial and
live projections both consume tracks. The engine filters source copies before
artist merging, consistently with Albums' any-downloaded-track behavior.
Search, genres, exclusions, favorites, sorting, and visibility still compose
with the download filter. Missing artist identity cannot qualify a download.
No new service, observer, cache, or filtering abstraction was added.

**Home:** On the fresh baseline, scroll Recently Added artwork into the toolbar.
Album art and section headings render sharply behind the feed title and controls
(`baseline-home-scrolled.png`). Home requested forced toolbar transparency through
`artworkBackedToolbarBleed`; its automatic scroll-edge request did not provide
readability protection in this hierarchy.

Home now requests the existing `toolbarMaterialBackground` on macOS. Native
material protects the title over scrolling content (`final-home-cold-scrolled.png`
and `final-home-warm-scrolled.png`). The actual scroll owner, normal hosting safe
area, first-heading padding, profile artwork background, and iOS presentation
remain unchanged. No custom mask, scroll probe, bridge, or spacer was necessary.
The older macOS sampling note is updated without claiming older-runtime proof.

A broader change to artwork-backed toolbar behavior would affect artist/album
and other detail surfaces. Registering or replacing native scroll owners would
also enlarge the platform bridge. The Home-only request fixes the reproduced
problem with four added conditional lines; neither broader alternative is needed.

## Focused regression tests

- `MediaFilterEngineTests.testArtistDownloadsStayWithinTheirSourceAndComposeWithOtherFilters`:
  no downloads, colliding artist IDs on different sources, multiple downloaded
  artists, combined search/genre/exclusion/favorite filters, and filter off.
- `LibraryViewModelCacheCleanupTests.testArtistDownloadsFilterPreparesInitialSnapshotAndTracksDownloadChanges`:
  persisted filter on at first load, repeated off/on toggles, and download addition
  and removal with stable artist/album metadata. Uses an in-memory database and
  removes its uniquely named local fixture. The baseline failed with six assertions;
  the final test passes. It restores the exact prior persisted filter data.

Home's regression is visual rather than a new implementation-mirroring unit test.
Repeat this manual test on a verified build: cold-launch Home; confirm the first
heading is below the title; scroll artwork and headings through the titlebar;
scroll back to the top; navigate Songs → Artists → Home and repeat; open and
close Edit; hide and restore the sidebar. The title must retain native material
protection, the initial heading must keep its safe area, and all actions must
remain reachable. Cold and warm title-protection/heading gates passed on macOS
27.0.1 (26A434). The independent failures below prevent a blanket chrome pass.

## Final verification

All builds use `Ensemble.xcworkspace` and separate DerivedData paths.

| Check | Result and evidence |
| --- | --- |
| Focused Core tests | **Passed**, 18 tests, zero failures; `final-core-tests.log` |
| Existing native/navigation UI helper tests | **Passed**, 31 tests, zero failures; `final-ui-tests.log` |
| macOS Debug build | **Passed**, `final-macos-build.log` |
| Generic iOS Debug build, signing disabled | **Passed**, `final-ios-build.log`; compile proof |
| iPad simulator Debug build | **Passed**, `final-ipad-build.log` |
| macOS cold navigation | **Passed**: fresh Songs process → first Artists visit; separate fresh Artists process → first Songs visit |
| macOS warm navigation | **Passed**: repeated Songs/Artists transitions, search-focused section switch, correct per-section search binding |
| macOS filter/search/sort/Back | **Passed**: repeated toggles give zero artists then restore rows; ABBA search; artist selection, album push/Back; Date Added sort and Name restore |
| macOS Home | **Passed**: separate cold Home process and warm Home return, top heading, scroll protection, Edit open/dismiss, return to top |
| macOS Downloads and Settings | **Passed**: Downloads open, Manage Downloads/Back, close; Profile/Merging/Back and close; preferences unchanged |
| macOS sidebar | **Passed** hide/restore; mini-player remains accessible, but placement fails as described below |
| iPad downloaded filtering | **Passed**: real cached downloads narrow to AJR, Gungor, twenty one pilots; read-only database query matches these names; `ipad-downloaded-artists.png` |
| iPad cold and warm filtering | **Passed**: fresh process with persisted filter on shows the same three artists; Songs → Artists return preserves results; artist selection, album push/Back retain picker |
| iPad sidebar | **Passed** opening sidebar and using it to navigate; portrait uses native overlay behavior |
| Diff whitespace | **Passed**, `git diff --check` |

The iPad target is `08CA3DD8-D174-40E9-A361-62B95671B969`, actual iPadOS 26.5.
Installed executable and debug-library hashes match the produced artifact; launch
processes were 82941 and 91328. Installed version is `202610011524.6362`.
macOS PIDs 79290, 87218, and 89757 were verified against the explicit final app
path. No reentrant-publication warning appears in the retained final session logs.
Builds retain warnings in untouched playback, Watch, design-token import, and
AppIntents metadata code. Provider WebSocket cancellations/offline messages also
appear during startup; these checks do not establish provider network health.

## Known failures and limits

- **Failed, pre-existing:** At a 1100 × 883 macOS window, hiding the 220-point
  sidebar leaves the mini-player centered about 110 points to the right of the
  full window center. Frozen baseline and final screenshots reproduce the same
  offset (`baseline-sidebar-hidden-player.png`, `final-sidebar-hidden-player.png`).
  Sidebar restoration works. Root player/chrome ownership was not expanded here.
- **Observed in baseline and final:** Home's rightmost Edit action can be partly
  clipped during scrolling at this window size, although it remains clickable
  and opens its sheet. The title/readability fix does not claim to repair this
  separate toolbar-width/layout behavior.
- **Tool failures, recovered:** Agent-device rejected an expired reference after
  a toggle; a new snapshot corrected it. Its first switch reference tapped the
  row center without changing the switch; a screenshot located the actual switch.
  Neither acknowledgement was accepted as app-behavior proof. Some snapshots used
  the helper's fallback backend and reported slow accessibility capture.
- **Untested:** older macOS/iOS runtimes, compact iPhone and physical-device UI,
  Watch, alternate appearance/accessibility configurations, actual download
  transfer/removal lifecycle, audio interruption/route changes, and performance
  profiling. iPad Home/Downloads/Settings were not separately swept. No whole
  Core package run is claimed; previously documented unrelated full-suite failures
  were not re-evaluated by this focused selection.

Test cleanup: Artists Downloaded Only restored to off on both platforms (iPad
persisted data rechecked), macOS search cleared and alphabetical sort restored,
sidebar restored, Home scrolled to top. Playback remains paused on macOS and
Nothing Playing on iPad. The simulator was shut down; physical devices were
not touched.
