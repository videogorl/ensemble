# Search navigation stalls follow-up

Date: 2026-09-30

## Delivered change

`SearchView` copied the coordinator's selected tab, Search path, and More path
into three `@State` values. A newly mounted Search view initially considered
itself inactive, then corrected those values in subscriptions and `onAppear`.
That changed the conditional `.searchable` / `.searchFocused` structure after
the first render. The trace showed expensive native focus/accessibility and
SwiftUI layout work entering Search.

Current navigation state now comes directly from the existing coordinator.
Only the previous tab's Search status remains local: it is transition history
used by the existing outgoing-tab chrome handoff. Removed two subscriptions and
the `onAppear` state copies. Search can render its correct modifier structure on
the first pass. No navigation owner, dependency, retained hidden root, or new
delay was added. Existing result routing, More -> Search behavior, keyboard
collapse, and cancellable 300 ms outgoing-tab preservation remain.

## Instruments evidence

Baseline source: `e1867ed7`. Candidate: only the Search state cleanup. Both are
signed macOS Release builds using the same sandbox/library, existing playback
track, and 4968 x 2780 window. Attached Time Profiler plus Activity Monitor to
the exact verified PID. Host UUID: `E3A3882D-C3B6-5B96-805E-B89E87E9E955`,
macOS 27.0.1 (26A434), Instruments 27.0 (27A266a).

Two recordings per condition, each from a fresh launch, with Pins and Smart
Playlists collapsed and Playlists expanded. Warmed the journey once, restarted
the same existing track, then clicked Home -> Search -> Albums -> Songs ->
Artists -> Genres -> All Playlists -> Songs twice. Each input had a minimum
three-second dwell. Input-tool overhead varied, especially in the first
candidate recording. The comparison uses fixed **2.5-second windows** anchored
to the app's logged tab changes, rather than whole-trace totals or only flagged
events. All 16 events and their complete windows were validated in each trace.
No accessibility-tree queries, builds, tests, or export processing ran during
recording.

| Entering section | Baseline mean sampled main-thread work | Candidate mean | Events with potential-hang flags |
| --- | ---: | ---: | ---: |
| Search, four events per condition | 1327.0 ms | 795.0 ms | 4/4 -> 4/4 |
| Home | 692.3 ms | 811.0 ms | 4/4 -> 4/4 |
| Albums | 970.8 ms | 948.3 ms | 4/4 -> 4/4 |
| Songs, eight events per condition | 775.9 ms | 730.0 ms | 8/8 -> 8/8 |
| Artists | 777.8 ms | 721.3 ms | 4/4 -> 4/4 |
| Genres | 260.0 ms | 242.3 ms | 0/4 -> 0/4 |
| All Playlists | 325.3 ms | 314.8 ms | 2/4 -> 3/4 |

Search used **40% less sampled main-thread work**. The two recording pairs
separately showed 41% and 38% reductions. The first Search entry in each
recording averaged 1882.5 -> 945.0 ms; the second averaged 771.5 -> 645.0 ms.
Inclusive accessibility samples averaged 645.8 -> 244.3 ms, consistent with
avoiding the late structural change during native focus setup. This attribution
is an inference supported by the code and stacks, not a frame-rate measurement.

The rest of the mixed journey averaged 654.0 -> 642.5 ms, with substantial
per-section/run variation. Whole-journey potential-hang flags were **26/32 ->
27/32**. Home was worse in the accepted candidate captures. These results
establish a targeted Search reduction; they do not establish an app-wide stall
or responsiveness improvement. Search itself still has potential-hang flags.

Direct UI checks confirmed the same track and Pause control before and after
each recording. Retained logs for the second baseline/candidate pair also
confirmed advancing playing timeline reports on that track through the actions.
The first pair's session files rotated out before archival; their direct UI
playback evidence remains, but their timeline samples are unavailable.

Portable hashes, PIDs, timestamps, per-event numbers, timeline samples, and
installed-build provenance are in
[metrics.json](artifacts/2026-09-30-navigation-stalls-followup/metrics.json).
Raw traces, exports, logs, and frozen apps are local in
`/tmp/ensemble-stalls.VrXQxf`; raw Instruments environment data is not committed.
This is a small sample on one Mac, not a general latency, memory, leak, physical
device, or older-OS performance guarantee.

## Discarded experiments and remaining stalls

An outer Home `LazyVStack` rendered and scrolled correctly on Mac, iPhone, and
iPad. Its exploratory capture averaged 648 ms entering Home. The unchanged
baseline varied from 729.5 to 655 ms across its recordings, so a repeatable Home
gain was not established. Restored `VStack` before the accepted builds.

An earlier deep-link capture had a different window size and idle playback; it
is excluded. Early native UI input failed with `windowNotFoundAtPosition` /
`cgWindowNotFound` while the app remained visible. The user confirmed the Mac was
unlocked. Later native clicks and typing worked using the canonical built app
path. Those tool failures are not counted as app stalls; their cause was not
established.

Native two/three-column replacement and other AppKit/SwiftUI layout/focus costs
remain. The [sidebar investigation](2026-09-30-sidebar-navigation-followup.md)
records why a permanent empty middle column fails the existing layout contract.
This change does not replace that navigation structure. A wider redesign needs
its own product/layout decision and matched runtime evidence.

## Verification

- Existing `NavigationRootHelperTests` and `PlatformAndDragPolicyTests`: 30
  passed, no failures. Command: `swift test -q --package-path
  Packages/EnsembleUI --filter
  'NavigationRootHelperTests|PlatformAndDragPolicyTests'`. These protect routing
  policies, including Search/More result routing, not SwiftUI focus performance.
  No layout-only unit test was added.
- Accepted source passed signed macOS Release and iOS Debug simulator builds
  through `Ensemble.xcworkspace`. Build version: `202609301945.1867`.
- Mac: verified the explicit accepted executable and PID 63027, then used native
  sidebar clicks and keyboard typing to search ABBA. The query/result, artist
  and album route, native Back, section switching, preserved query, and absence
  of Search chrome in Songs were inspected on the candidate Search source.
- iPhone 17 Pro / iOS 26.5, UUID `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`:
  freshly installed the accepted build, verified executable and debug-dylib
  hashes, and running PID 61420. Dedicated Search opened ABBA -> Gold: Greatest
  Hits and returned through native Back to the preserved query. Artists uses its
  own filter field, and returning to Search preserves the query.
- iPad A16 / iOS 26.5, UUID `08CA3DD8-D174-40E9-A361-62B95671B969`: the same
  fresh installed hashes, running PID 61469. Search results use the existing
  native Artists sidebar/detail route; album and Back navigation, returning to
  Search, and the preserved query were inspected. Accessibility snapshots
  occasionally marked visible sidebar rows covered or fell back to the private
  AX backend; screenshots and resulting UI state were used to verify input.
- The More -> Search root was covered by existing routing tests and source
  tracing, not by a fresh UI journey with a customized hidden Search tab.
  Expanded iOS 27 physical-phone behavior was not verified. Playback was paused
  at the end of testing.
