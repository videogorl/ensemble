# macOS sidebar latency investigation

Date: 2026-10-01

## Reproduction and causes

The signed Release build at `07a61377` reproduces the reported beat before
navigation. In two matched runs of Artists → Songs → Artists → Albums → Songs,
Instruments flags all eight transitions. Main-thread stacks are dominated by
SwiftUI/AppKit layout and view graph work. This is actual runtime work, rather
than a Debug-only slowdown or a package-test timing result.

Three concrete sources of work remain in the source:

- `SidebarView.nativeExplorerColumns` replaces its native two-column split with
  a three-column split when entering Artists, Genres, or All Playlists. That
  replacement also remounts the sidebar. It is a plausible explanation for the
  reported artwork/icon flash; no frame-by-frame recording proves that visual
  attribution or establishes its absence after this change.
- `GenreChipBar` eagerly builds the entire horizontal chip row. This library
  has 67 chips, including glass effects for offscreen items. Songs also builds
  the row in its native table's separate sizing host.
- Songs, Artists, Albums, and Genres initially display the library's current
  snapshot through a fallback while their local snapshot cache contains
  `.empty`. Receiving the already-displayed snapshot publishes another update.
  Songs also advances its table content revision for that initial receipt,
  unnecessarily reloading the same initial rows.

## Delivered change

On macOS, genre chips render in a `LazyHStack`. The existing eager row supplies
their accessibility representation, with the same labels, actions, and complete
button collection. Both representations use one shared chip-content builder;
iOS retains its existing eager layout and glass styling.

A plain lazy row crashed on this Mac when its native accessibility list action
`AXScrollToBottom` was invoked. Grouping the row did not correct it. Reports
`Ensemble-2026-10-01-082349.ips` and
`Ensemble-2026-10-01-084529.ips` record `SIGTRAP` in SwiftUI's lazy-layout
accessibility traversal, including `ForEachState.item(at:offset:)` and
`AGAttribute.syncMainIfReferences`. The delivered representation preserves the
original HStack's individual-button accessibility surface, rather than exposing
that lazy-list traversal. An offscreen Vocal button remains accessible and
successfully filters Songs to 40 tracks. See Apple's
[accessibilityRepresentation documentation](https://developer.apple.com/documentation/swiftui/view/accessibilityrepresentation%28representation%3A%29/)
for the native, non-visual representation mechanism.

The four macOS browse caches now start with the snapshot already being
displayed. Songs also seeds its native sections from that snapshot. Later real
snapshot changes still update the cache, sections, and table revision. A
snapshot-only diagnostic capture did not establish an overall speed gain, so
the combined improvement below must not be attributed to cache initialization
alone.

## Instruments results

The final baseline/candidate pair uses normal mouse clicks on the same Mac,
sandbox/library, 2200 × 1224 window, paused playback, and four-transition
journey. Both processes have visited those screens before recording and start
with an empty artist detail pane; their warmup counts are not identical. Exact
executable hashes, versions, PIDs, run dates, and per-transition weights are in
[metrics.json](artifacts/2026-10-01-sidebar-latency-followup/metrics.json).

Each transition is measured for 1.5 seconds after its logged `tabChanged` event.
A fixed 2.2-second dwell precedes the next AX snapshot, keeping those queries
outside the comparison windows. Each mouse action follows a fresh screenshot,
which was necessary for reliable coordinate mapping in the Mac UI tool. Full
captures contain additional accessibility stalls outside selection windows;
their capture-wide flag counts are not the navigation comparison. No compiler,
tests, or trace exports run during recordings. Thermal state is nominal.

| Condition | Mean sampled main-thread work per transition | Transitions with post-selection hang flags | Mean sampled Songs header/footer sizing work |
| --- | ---: | ---: | ---: |
| Source baseline, four mouse transitions | 345.0 ms | 3/4 | 37.0 ms |
| Candidate, four mouse transitions | 306.3 ms | 3/4 | 6.5 ms |

The final pair reduces sampled main-thread work by 11.2% and sampled sizing work
by 82.4%, without reducing the count of flagged transitions. These are sequential
captures on one Mac, not a click-to-first-frame latency measurement or a general
performance guarantee. Stalls remain.

Earlier diagnostic recordings selected rows through native accessibility actions.
Two baseline runs averaged 438.4 ms across eight transitions (8/8 flagged); two
candidate runs averaged 356.4 ms (7/8 flagged). The candidate was restarted for
its second run. A later baseline control averaged 335.8 ms (4/4 flagged), showing
substantial run-to-run variation. The earlier 18.7% difference is not used as the
headline result, and these runs are retained separately from mouse measurements.

Two accessibility-driven captures of the installed TestFlight build averaged
496.8 ms (8/8 flagged). That binary is verified TestFlight
`0.4.0 (202603240723)` with stripped app symbols; it is not proof of the exact
App Store build the user described as prod. The journeys do not establish that
the source baseline is uniformly slower than production.

## Rejected container changes

Several stable-container prototypes reduced layout work but failed direct UI
checks. Nested split views changed pane styling and window titles. An `HSplitView`
prototype triggered AppKit constraint feedback when selecting an artist;
bounding its detail pane prevented that crash but album navigation then removed
the browse selection pane. An always-three-column prototype collapsed the empty
column but lost the ordinary screen titles. All container changes and the
capsule-only styling experiment were reverted. Their faster profiles are not
evidence for the delivered change.

## Verification and remaining work

- Signed macOS Release workspace build passed. The frozen candidate is
  `0.4.0 (202610010831.0761)`, executable SHA-256
  `67dbb80aa6c1af7bb3e1aa6abd4e9482b15178571498f23cfe2e571f05bf08bc`.
  PID/executable path and all five source hashes were verified after the final
  UI checks; the running candidate did not restart during those checks.
- Generic iOS Simulator Debug workspace build passed. This is a compilation
  crosscheck, not fresh iOS runtime evidence.
- Existing focused cache-publication, array-storage identity, root-navigation,
  and platform/drag checks passed: 32 tests. No layout-only test was added.
- Direct inspection verified Songs include/exclude/clear and favorite cycles;
  filter updates settle asynchronously. Accessible offscreen Vocal filtering
  worked. ABBA → Gold retained the artist pane, sidebar switches restored the
  album, and Back returned to ABBA. Genres → Vocal displayed three albums.
- Native window zoom widened the chip row without breaking its header, then
  restored the original window size. Hide Sidebar and Show Sidebar preserved
  the Songs title and content. Playback and filters were left neutral and paused,
  with the measured candidate open on Songs.
- Horizontal wheel commands were acknowledged but did not visibly move the
  row. This also occurred with the eager baseline. Ordinary horizontal pointer
  scrolling remains unverified through the available Mac UI tool, including
  coordinate actions after refreshing its screenshot mapping. The accessible
  offscreen-button check does not substitute for that gesture proof.

The remaining two/three-column root replacement still needs a solution that
preserves native titles, the selection pane, independent detail navigation,
sidebar toggling, and scroll state. The reported flash is not declared fixed.
The accepted patch reduces a measured contributor without keeping hidden screen
trees, adding a navigation engine, or applying layout/timing shims.

Raw traces, exports, build/test logs, and frozen binaries remain in the
`raw_artifacts_directory` recorded in the JSON. The committed artifact contains
only the portable metrics and build provenance.
