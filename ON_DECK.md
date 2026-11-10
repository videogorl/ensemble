# On Deck

Unrelated discoveries waiting for their own task. Remove an entry when it is fixed.

## Confirmed: data race in a NowPlayingViewModel test mock (2026-11-09)

- Evidence: one full `EnsembleCore` run crashed with SIGSEGV in
  `NowPlayingViewModelFavoriteTests.testToggleRatingUpdatesFavoriteStateForCurrentTrack`.
  The faulting frames are `Array.append` inside
  `MockLibraryRepository.fetchTrack(ratingKey:sourceCompositeKey:)`, which appends to
  `fetchTrackRequests` without a lock while `NowPlayingViewModel.setTrackFavorite` calls it
  concurrently. The class passed 3 times alone and the next full run passed.
- Impact: intermittent whole-suite crash; no production code involved.
- Next step: guard the mock's recorded requests with a lock (or make the mock an actor)
  and rerun the full suite a few times.

## Suspected: flaky WebSocket library-update test (2026-11-10)

- Evidence: one full `EnsembleCore` run failed
  `PlexWebSocketCoordinatorTests.testLibraryUpdateCarriesLatestExactItemChanges`
  (`PlexWebSocketCoordinatorTests.swift:100`: no changes received, after 3.25 s).
  The class passed 3 of 3 runs alone, and the playback branch that hit it does not touch
  the coordinator or its test.
- Impact: intermittent whole-suite failure; likely a timing window under full-suite load.
- Next step: check the test's wait/debounce timing against the coordinator's debounce
  and make it wait on the delivered change instead of a fixed interval.

## Suspected: flaky launch prefetch test (2026-11-10)

- Evidence: one `swift test --filter Playback` run (329 tests) failed
  `PlaybackLaunchCoordinatorTests.testCompleteLaunchDoesNotPostSeekStreamingSources`
  (`PlaybackLaunchCoordinatorTests.swift:193`: prefetch count 0, expected 1). The class
  passed 3 of 3 runs alone; the playback branch that hit it does not touch the coordinator.
- Impact: intermittent failure under load; the test checks a prefetch dispatched in a task
  after a single `Task.yield()`.
- Next step: wait on the prefetch call (for example `waitUntil`) instead of one yield.

## Known limit: membership backfill memory on a pathological playlist (2026-11-10)

- Evidence: `PlaylistMembershipBackfill` holds one attribute-only row per membership of the
  playlist it is processing. Measured on a Mac with a synthetic store (machine at load
  average 100 to 200, so CPU time is the fair figure): 100,000 rows with a 20,000-row
  playlist took 1.2 s CPU and +20 MB peak; a 200,000-row playlist with two different items
  at every position took 2.8 s CPU and +199 MB peak. Real stores are 5,800 rows (0.24 s CPU,
  +8 MB with 9,000 duplicates added). Details in
  `docs/investigations/2026-11-10-step-3a-playlist-membership-constraint.md`.
- Impact: a playlist of that size would cost an iPhone SE a few seconds and a few hundred MB
  once, at the first launch of the model 12 build. No such store is known.
- Next step: if one appears, fetch only positions with more than one row (grouped fetch with
  a count filter) so memory follows the suspicious rows instead of the playlist.
