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
- The baseline run above made no implementation changes; the follow-up below measures the implemented changes.
- Debugger detached. Normal Release build reinstalled; executable hash matched the saved normal build, and ETTrace was absent (`restored.json`). Songs text filter cleared, keyboard dismissed, playback left paused, and log streaming stopped.

Priority: fix navigation bookkeeping at its shared owner; move broad-search processing off main; eliminate synchronous browse recomputation; then apply and compare filter-before-sort. Keep destination fallback grouping as an unmeasured candidate.

## Implemented changes and repeat run

The follow-up implements the four demonstrated opportunities:

- Route links use the coordinator's existing generation-controlled interaction timer. Menu handoffs extend that same interaction; the separate UI timer is deleted.
- Local search repositories fetch and map rows on background contexts. Only Sendable values leave those contexts. Search visibility and merging run in a detached task; canceled projections cannot publish, and existing query/scope generation checks still guard completion.
- The initial library load prepares browse snapshots off main before publishing raw cache collections. Views consume committed snapshots instead of computing synchronous fallbacks. Preparation rechecks load generation, cancellation, settings, and source visibility before publication. Debounced results retain their input counts so an old empty computation cannot overwrite a newly prepared populated snapshot.
- Track and album computation filters before sorting. Initial preparation and subsequent updates share the same computation functions.

### Repeat-run provenance

Same UUID, iOS 26.5 runtime, Release configuration, animations enabled, and cached library counts as the baseline. Normal build `202609041334.0678`, initially PID 77195, matched the freshly built executable. The ETTrace variant used PID 79929 for search and PID 81418 for cold launch; its matching app dSYM UUID was `DC6B21D1-F1B3-37E4-9203-ECB509AF5880`. The profiler's localhost listener was verified as PID 79929, avoiding ambiguity from another booted simulator. First-party unresolved frames were at most 0.007% in these profiles.

All new artifacts are under `/tmp/ensemble-state-audit-0904/after/`. `normal-freshness.json`, `profile-freshness.json`, `launch-freshness.json`, and `dsym-check.log` record build/process provenance. ETTrace remains external to the project.

### Before/after evidence

| Check | Before | After | Interpretation |
| --- | --- | --- | --- |
| Actual artist-card tap | Two navigation begins and two ends, from separate owners | One begin and one end, both from the coordinator | Duplicate ownership removed; debugger timing is not a hitch measurement |
| Songs filter `love`, normal app, 7-second sample | 96 track-computation samples; 63 sorting, 23 filtering, 8 merging | 33 track-computation samples; 1 sorting, 23 filtering, 8 merging | Sorting work substantially reduced in this sampled interaction; no device frame-rate claim |
| Search `The` | 159 ms main-thread search processing, including 138 ms visibility/projection; approximately 37 ms fetch closures | No samples attributed to those search fetch/projection functions on main | Targeted work moved off main; absence of samples does not mean zero publication/rendering cost |
| Search `love` | Approximately 22 ms main-thread track fetch and 17 ms result processing | No samples attributed to those search fetch/projection functions on main | Same bounded conclusion |
| Process-cold Artists launch | Approximately 64 ms in synchronous Artists snapshot getter; approximately 31 ms grouping | Getter deleted; no main-thread `DisplayArtist.group` samples | First content now comes from prepared snapshots |

Both searches retained exactly the same raw counts: `The` 7,672 tracks / 482 albums / 109 artists; `love` 620 / 28 / 1. Search completion latency did **not** improve in these single runs: `The` was 244 ms versus 202 ms, and `love` 83 ms versus 44 ms, excluding debounce. Fresh background contexts and mapping trade some completion latency for keeping the main actor free. Do not describe this as faster end-to-end search.

The cold-launch capture was 10.549 seconds with 3.455 seconds classified active, versus the baseline's 14.961 / 3.910 seconds. Different capture windows and startup variability prevent treating that total as a measured launch-time improvement. Main-thread snapshot publication/comparison remains visible: approximately 22 ms in track snapshot commit and 83 ms aggregate display-artist equality. Those costs were not optimized in this change.

Direct snapshots/screenshots confirmed populated Artists, correct search results, filtered Songs, and Artists → a-ha → album → Back → Back. Evidence: `timer-events.jsonl` (Back then artist push), `filter-love-normal-sample.txt`, `search-the/`, `search-love/`, `launch/`, `journey.log`, and the PNG captures. The destination-resolution fallback and separate route-transition timer remain outside this change.

### Checks and cleanup

- Release simulator build succeeded. 96 focused Core checks and 27 playlist persistence checks passed, covering search responses/cancellation/visibility, navigation, first committed browse content, cache/readiness/concurrency, genre projection, and existing sort/filter behavior.
- The broader cache selection exposed two unrelated failures: `testRemoteDisabledLibraryFlagCleansAlreadyDisabledSourceDownloads` and `testRemoteLibraryDisableCleansSourceDownloadsAndPreservesEnabledSource`. Both produced the same 14 assertions on unchanged commit `067e8310` in an isolated worktree. They were excluded from the final focused cache run; they are not claimed fixed. Logs: `../baseline-cleanup-tests.log`, `../improvements-all-focused.log`, `../improvements-cache-tests.log`, `../improvements-final-focused.log`, `../improvements-sort-tests.log`, and `../improvements-persistence-tests.log`.
- Debugger detached; capture processes stopped. Normal Release app restored, PID 82241, matching executable and no embedded ETTrace (`restored.json`). Songs filter empty, keyboard closed, playback paused. No physical-device, energy, or frame-time proof is claimed.

## Filtering and hidden-media follow-up

The next change batches hidden-media updates through the existing store, shares Songs' non-genre filtering between rows and genre choices, and scopes artist genre lookup by source plus item ID. It also removes the unused artist-filter dependency from genre-choice computation. Persisted identities, timestamp conflict resolution, unhide tombstones, and raw catalog retention remain intact; no schema migration is needed.

### Focused checks

56 distinct focused Core tests passed across two selections (18 and 41 tests, with three overlapping). Coverage includes hidden-media persistence, cache cleanup, favorites, genre browsing, concurrency, and filter configurations. The added checks establish:

- A 100-item hide batch publishes once; cleanup of 99 items publishes once more. Older mutations are ignored, and all 100 mutation records plus related catalog IDs survive reload.
- Artists with identical item IDs on different sources cannot inherit each other's genres, for inclusion or exclusion.
- Songs genre choices retain the non-genre result while displayed rows apply included/excluded genres to that same result.

Logs: `/tmp/ensemble-state-audit-0904/hidden-filter-final-tests.log` and `hidden-filter-cache-tests.log`. The two previously baseline-confirmed download cleanup failures listed above were excluded from the cache selection and remain unresolved. Release simulator build succeeded.

### Runtime evidence

Artifacts are in `/tmp/ensemble-state-audit-0904/filter-batch/`. The same iOS 26.5 simulator UUID and cached catalog were used. Normal Release build `202609041534.2389`, PID 54587, matched the freshly built executable SHA-256 `d3481b1643aaa31fe22e762da2e22c891612d5a2bdbfe601e4d6fd110537b126`; ETTrace was absent (`freshness.json`).

| Interaction | Observed result |
| --- | --- |
| Songs text filter `love`, seven-second `sample` | Library-compute queue: 81 samples in the previous build versus 35 now. Previous work included a separate 42-sample genre-choice filter; that pipeline is deleted. Track computation itself was 33 versus 32 samples. |
| a-ha → Hide → All Sources | Artist disappeared from Artists. Hidden showed two source-specific entries; persisted data contained two hidden artist identities with the same batch timestamp. |
| Unhide both entries from Hidden | Hidden became empty, a-ha returned with “2 sources,” and persisted data retained two unhide tombstones with zero active hidden items. |

Evidence: `filter-love-sample.txt`, `love-filter.png`, `hidden-after-batch.json`, `hidden-two-sources.png`, `hidden-restored.json`, and `restored-artists.png`. Comparison sample: `../after/filter-love-normal-sample.txt`.

This is one sampled interaction per build, not an end-to-end latency, frame-rate, or energy benchmark. After simulator input stopped being delivered, only the assigned simulator was restarted and Simulator.app opened; the no-input capture is explicitly discarded (`discarded-no-input-sample.txt`). The valid run rendered “Love” because of keyboard capitalization; filtering is case-insensitive. Keyboard setup differed, so compare the targeted computation rather than whole-process activity. The final app is uninstrumented, Songs text is cleared, Artists is visible, and playback is paused. All temporary hides were restored through the UI.
