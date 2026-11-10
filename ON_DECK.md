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
