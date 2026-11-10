# On Deck

Things agents notice outside their task: bugs, workarounds, over-complex code, a native
API that would replace custom machinery. Each entry gives evidence, impact and a next
step, and says whether it is suspected or confirmed. Remove an entry when it is fixed.
An entry does not authorize the work; Felicity picks what gets done.

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

## Confirmed: excessive disk writes on the iPhone SE 2 (2026-08-10 report, noted 2026-11-10)

- Evidence: a disk-writes resource report, 1,073 MB in 107 minutes. 37 of 66 samples are an
  Ensemble async task into a Foundation file write (frames unsymbolicated, writer unknown);
  15 of 66 are Core Data saves. See
  `docs/investigations/2026-11-10-crash-evidence-and-library-writer.md`, report 6.
- Impact: battery and storage wear, and iOS can penalize the app. The step 3 shared writer
  should cut the Core Data share (it skips unchanged rows); the larger file-write share is
  not explained.
- Next step: symbolicate the report (needs the dSYM for TestFlight build `…0709`), or
  measure writes by subsystem on a device with Instruments File Activity during a sync and
  a streaming session. Suspects: stream cache, offline downloads, the session log file.

## Suspected: EnsembleCore's tests are heavier than they need to be (2026-11-10)

- Evidence: about 40,000 lines of tests against 70,000 of source in `EnsembleCore`. Three
  entries above are flaky or racy tests, and several pin internals such as private state.
- Impact: slow full runs, ambiguous failures, and tests that must be rewritten on every
  refactor without protecting behaviour.
- Next step: per the plan's test policy, list tests that pin internals or duplicate another
  test's behaviour class, by file, and propose deletions or table-driven merges.

## Confirmed: the Mac app opens no window without `-ApplePersistenceIgnoreState YES` (2026-11-09)

- Evidence: launching the built `.app` on this Mac showed no window until that flag was
  passed; stale window-restoration state is the suspected cause.
- Impact: a user with the same saved state would see the app launch with nothing on screen.
- Next step: reproduce with the saved state kept, then check the scene and
  restoration setup.

## Confirmed: a track that appears twice in a detail list plays its first occurrence (2026-11-09)

- Evidence: seen while checking playlist detail on the simulator; tapping the second copy
  starts the queue at the first.
- Impact: wrong start position in playlists that repeat a track.
- Next step: start playback from the tapped row's index, not a lookup by track id.

## Suspected: playback slot held through a stream-retry reload (2026-11-09)

- Evidence: read from the code during the playback failure work; same on `develop` before it.
- Impact: unknown; may delay a user action that arrives during the reload.
- Next step: fold into the stream drop recovery design
  (`docs/investigations/2026-11-10-stream-drop-recovery-and-fallback.md`, in progress).

## Unchecked: gap above the Favorites header on Mac (2026-11-09)

- Evidence: reported by a Mac check worker; not looked at again.
- Next step: open Favorites on the Mac and compare the header spacing with Album detail.
