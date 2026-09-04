# State and routing performance: simulator evidence

## Baseline

- Source: `8aff52de844603c1ee8c677e9f65bc3495e02fb4`; initially clean checkout.
- Xcode 26.6 (17F113), Release, with dSYMs; build succeeded.
- iPhone 17 Pro, iOS 26.5, UUID `C0C6CF8B-7B59-4402-9D8D-CB4CFBF5D64D`.
- Existing cache: 18,002 tracks, 1,754 albums, 969 artists. No cache clearing or source changes.
- Normal build `202609041301.8528`: installed executable SHA-256 matched the freshly built executable; initial PID 46451.
- Animations enabled. Automation routes established starting surfaces; actual touch input exercised search and detail navigation.
- ETTrace 1.1.0 temporarily linked using an external xcconfig and embedded in the build artifact. No project or production source changes. App dSYM UUID `BA726857-16F6-3E1C-8C28-E0BD1175E8CB` matched the instrumented executable. First-party symbol gaps were below 0.004% of reported frames in the completed captures.
- Instrumented process 48545 handled searches; process 51463 handled the launch/navigation captures and subsequent debugger probe.

Raw artifacts are local, under `/tmp/ensemble-state-audit-0904/`. They are not committed and may be removed by temporary-directory cleanup.

## Results against the original review

### 1. Competing navigation timers: runtime mechanism confirmed

An actual artist-card tap produced this sequence in automatic-continuation LLDB breakpoint logs:

1. `ForegroundWorkScheduler.beginInteraction(.navigating)` from `NavigationCoordinator.markRouteInteraction()`.
2. Another begin from `NavigationCoordinator.markNavigationInteraction()`, through `push()` and `logJourney()`.
3. End from the `markRouteInteraction()` task.
4. End from the `markNavigationInteraction()` task.

This confirms two owners operate the same scheduler state for one route. The source gives them 500 ms and 700 ms durations; the scheduler uses set membership rather than independent leases. The first end can therefore release the shared state before the second owner finishes. Debugger stops distort elapsed time, so the probe establishes call order and ownership, not production timing or a measured hitch. No background job starting early was demonstrated. The separate overlapping `routeTransitionTabs` timer case remains source-only.

Evidence: `timer-events.jsonl`, `timer_probe.py`, and `journey.log`.

### 2. Local search: confirmed, with a more important downstream cost

| Query | Raw tracks / albums / artists | Logged search elapsed | Main-thread sampled attribution |
| --- | --- | --- | --- |
| `The` | 7,672 / 482 / 109 | 202 ms | Search result processing 159 ms inclusive; visibility/projection processing 138 ms, including merge identity work 127 ms; track/album/artist fetch closures approximately 37 ms combined |
| `love` | 620 / 28 / 1 | 44 ms | Track fetch approximately 22 ms; result processing 17 ms, including visibility/projection processing 11 ms |

Elapsed values exclude the approximately 300 ms input debounce and do not measure final rendering. Inclusive sample values overlap; do not add parent and child figures. Counts are raw repository results before display merging.

The profile backs moving fetches off the main context, but moving only fetches misses most of the broad-query cost: `SearchViewModel.applyVisibilityToSearchResults()` and `MergingProjection.tracks` also run on the main actor. Prefer background fetch-and-map plus value-based filtering/merging, preserving generation/cancellation checks and exact source identity. No speedup is claimed until an equivalent before/after run exists.

Evidence: `search-first/output_259.json`, `search-first/app-stacks.txt`, `search/output_259.json`, `search/app-stacks.txt`, `search-the.png`, and `journey.log`.

### 3. Synchronous first-frame browse fallback: confirmed

A process-cold launch into Artists captured approximately 64 ms inclusive in `LibraryViewModel.immediateArtistBrowseSnapshot.getter` on the main thread. `DisplayArtist.group` accounted for approximately 31 ms across the capture. This supports replacing repeated synchronous fallback computation with a prepared snapshot and explicit readiness while preserving the first-frame contract.

Artist equality checks also accumulated approximately 97 ms during launch. This is an additional reason to inspect snapshot comparisons/publications before introducing more copies or caches. These are accumulated sample weights, not proof of one continuous 97 ms stall.

The capture lasted 14.961 seconds, with approximately 3.910 seconds classified active by the analyzer. It includes launch, account/cache hydration, UIKit work, and application startup; that total is not the cost of the fallback getter.

Evidence: `launch/output_259.json`, `launch/summary.txt`, `launch/app-stacks.txt`, and `launch-artists.png`.

### 4. Filter-before-sort: runtime cost confirmed; savings not yet measured

With the normal uninstrumented build restored (PID 53847), an eight-second sample covered clearing the Songs filter, and a separate seven-second sample covered entering `love` from an empty Songs filter. The latter captured 96 samples beneath the track computation closure on the serial `com.ensemble.library-compute` queue: 63 in the sorting branch, 23 in filtering, and 8 in merging, plus other work.

This confirms sorting is a material part of that background computation. Source inspection establishes that sorting currently precedes filtering. Filtering first is supported as a small optimization, but this run does not measure its benefit or establish a main-thread stall from the background sort. Album dependency pruning was not isolated in this run.

Evidence: `filter-normal-sample.txt` and `filter-love-normal-sample.txt` (library-compute stack begins around line 6346).

### 5. Destination factory's whole-library artist grouping: not confirmed

An actual Artists → a-ha → album → Back → Back flow rendered correctly, with matching `push` and `setPath` breadcrumbs. The 41.789-second navigation capture did not establish the specific fallback-grouping path as a hotspot; do not promote this source-level candidate to a measured finding.

It instead sampled approximately 160 ms in `LibraryRepository.findArtistsByName` and approximately 156 ms in artist equality checks across the flow. These warrant focused follow-up before changing destination identity/resolution behavior. The navigation capture includes accessibility snapshots and therefore cannot be treated as a clean animation/frame-time benchmark.

Evidence: `navigation/output_259.json`, `navigation/app-stacks.txt`, and `journey.log`.

## Profiling limits and cleanup

- Instruments Time Profiler rejected the verified live PID (`Cannot find process for provided pid`) with both simulator selection and host attachment. No usable Instruments `.trace` resulted; the completed profiles are ETTrace flamegraphs and macOS `sample` reports.
- ETTrace all-thread mode stalled the instrumented app immediately after recording started. That capture was discarded; a diagnostic sample is retained as `ettrace-multithread-stall.txt`. It is not evidence of an ordinary Ensemble hang.
- Completed ETTrace runs used main-thread mode with matched dSYMs. Keyboard, accessibility automation, profiler overhead, and background startup activity appear in the captures. Absolute simulator timings do not establish physical-device frame times, thermal behavior, or energy savings.
- No implementation changes or before/after performance comparison were made.
- Debugger detached. Normal Release build reinstalled; executable hash matched the saved normal build, and ETTrace was absent (`restored.json`). Songs text filter cleared, keyboard dismissed, playback left paused, and log streaming stopped.

Priority: fix navigation bookkeeping at its shared owner; move broad-search processing off main; eliminate synchronous browse recomputation; then apply and compare filter-before-sort. Keep destination fallback grouping as an unmeasured candidate.
