# On Deck

Things agents notice outside their task: bugs, workarounds, over-complex code, a native
API that would replace custom machinery. Each entry gives evidence, impact and a next
step, and says whether it is suspected or confirmed. Remove an entry when it is fixed.
An entry does not authorize the work; Felicity picks what gets done.

## Suspected: the iCloud profile subscription never fires (2026-11-10)

- Evidence: `CloudSyncService` registers a `CKDatabaseSubscription` (`profile-changes`), but
  saves `UserProfile` and `HiddenMediaState` without a zone, so they live in the private
  database's default zone. Apple documents database subscriptions as covering custom zones
  only. Not reproduced.
- Impact: a profile or hidden-media change on one device may only reach the others on their
  next pull, not by push.
- Next step: change the profile name on one device and watch the other's log for a remote
  notification. The fix in `docs/reference/web-client-design.md` section 3.1 moves both
  records into a custom zone.

## Suspected: other EnsembleCore tests fail under heavy host load (2026-11-10)

- Evidence: with the Mac at load average 400-800 (other simulators and builds), three full
  `swift test` runs executed 1187 tests with 5, 1 and 1 failures, a different set each time:
  `AudioPlaybackEngineStreamingTests.testStreamingFailureAfterFormatReadyReachesEngineErrorHandler`
  (1 s `fulfillment`), `DownloadQueueCoordinatorTests.testQueueLoopRestartsWhenMorePendingWorkArrivesDuringWindDown`,
  `HomeViewModelRefreshPolicyTests.testLibraryDataClearInvalidatesLateCachedRestore` and
  `testSourceChangeDuringActiveLoadFlushesAfterLoadCompletes` (1 s `fulfillment`),
  `AccountManagerAuthPolicyTests.testAsyncCredentialLoadTimesOutWithoutBlockingCachedFallback`
  (elapsed-time bound) and `NowPlayingViewModelFavoriteTests.testPlaybackProjectionTracksSmartMixTransitionState`
  (fixed `waitForProjectionPropagation`). None touched the tests fixed in this change.
- Update 2026-11-10 (step 3b): `HomeViewModelRefreshPolicyTests` (eight methods, 1 s waits) and
  `LibraryViewModelCacheCleanupTests.testBrowseSnapshotPreservesVisibleTracksUntilEmptySourceStateSettles`
  also fail on the unmodified base `e8ec7ef0` when a macOS build runs beside them, and all pass alone on
  a quiet machine.
- Impact: the full suite is not a reliable gate while the host is busy.
- Next step: rerun on an idle Mac to separate load from real defects; widen the 1 s waits to
  event-based waits with a long timeout.

## Confirmed: the full library fetch and the single all-track write are unbounded (2026-11-10)

- Evidence (read): `PlexConnector.fetchFullLibrary` (`PlexConnector.swift:337`) holds every artist,
  album and track of a source, twice when the confirming read runs, and `LibraryWriter.writeRows`
  (`LibraryWriter.swift:227`) writes them in one batch. The write predates 3b; fetching everything
  before writing adds peak memory. Unmeasured for a 100,000-track library on a phone (the largest
  source measured is 9,696 tracks).
- Next step: measure peak memory on the iPhone with a synthetic large source, then chunk
  `writeRows` by entity page if it is high.

## Suspected: `applyChanges` has no stale guard (2026-11-10)

- Evidence (read): `LibraryWriter.applyChanges` (`LibraryWriter.swift:195`) writes without the
  `lastSuccessfulSyncAt` check that `apply` has; it relies on the coordinator running one pass per
  source at a time.
- Impact: none while that serialisation holds; a delta older than a committed pass would overwrite
  newer rows if it ever stops holding.
- Next step: pass the query start with live deltas and apply the same guard.

## Known limit: library rows commit before the cursor advances (2026-11-10)

- Evidence (read): `LibraryWriter.apply` (`LibraryWriter.swift:157`) writes rows, deletions and each
  cursor in separate transactions.
- Impact: an interruption leaves committed rows with the old cursor. That is safe (the next pass
  re-fetches and finds the rows unchanged) but repeats the work.
- Next step: only if repeated work shows up in logs; one transaction would need a persistence API
  that writes rows and cursor together.

## Suspected: hidden entries pruned by a deletion do not return when the track reappears (2026-11-10)

- Evidence (read): `LibraryWriter.removeMissing` (`LibraryWriter.swift:313`) calls
  `HiddenMediaStore.removeMissing` for artists, albums and tracks the inventory no longer lists.
  The entry is dropped, so an item that is removed and later added again is visible again.
- Impact: a user-hidden item that is briefly absent from the server returns unhidden. Not new in 3b.
- Next step: decide whether hiding should survive absence; if so, prune only after a grace period.

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

## Unchecked: gap above the Favorites header on Mac (2026-11-09)

- Evidence: reported by a Mac check worker; not looked at again.
- Next step: open Favorites on the Mac and compare the header spacing with Album detail.

## Audit, 2026-11-10: custom machinery a native API might replace

From a read-only audit; none of these is a confirmed defect. Ranked by expected stability
gain per unit of work. Sizes are S, M or L.

- **Scroll index stops momentum by toggling scrolling** (`ScrollIndex.swift:141`, S/M). A
  UIKit probe finds the enclosing `UIScrollView` and turns scrolling off and on before a jump
  (commit `fdb0d4cc`). Next step: try `.scrollPosition(id:anchor:)` (iOS 17) in the scroll
  owner and see whether a jump during momentum behaves acceptably.
  Tried 2026-11-10 and left as is: Songs on iOS is a `UITableView` (`MediaTrackList`), so
  `.scrollPosition` does not apply there, and its owner already jumps with `scrollToRow`.
  Removing the probe passed a flick-then-tap XCUITest on Songs, but nothing proved the
  list was still decelerating when the tap landed (XCUITest waits for idle before it taps),
  and Albums and Genres jump through `ScrollViewReader`, which the test did not cover. Next
  step: log `isDecelerating` at the jump to confirm the scenario is reachable, then cover
  Songs, Albums and Genres before deleting the probe.
- **StageFlow is a `UICollectionView` cover flow** (`StageFlowCarousel.swift`, 196 lines, M).
  Next step: prototype `ScrollView` with `.scrollTargetBehavior(.viewAligned)` and
  `.scrollTransition` (iOS 17); keep UIKit if the 3D transform or cell reuse is lost.
- **Artwork has its own resolved-image cache beside Nuke's** (`ArtworkLoader.swift`, 988
  lines, M). Next step: check whether Nuke's pipeline cache can hold the resolved images
  while keeping stable identity, offline fallback and targeted invalidation.
- **Toasts use a separate window** (`ToastView.swift`, 588 lines, M/L) so they appear above
  sheets (commit `405ecc4f`). A root `.overlay` is simpler but hides toasts behind a sheet.
  Low gain unless that behaviour is relaxed.

Decided by Felicity on 2026-11-10: the AirPlay menu item that presses the button inside
`AVRoutePickerView` (`AirPlayButton.swift:28`) stays as it is. The account polling, scroll
index and Siri route polling items are scheduled as one batch.

Checked and left alone: the visible AirPlay control, artwork's persistent cache and retry
rules, the Plex WebSocket polling fallback, and the size of `WatchRootView.swift`.

## Suspected: flaky `NowPlayingArtworkProjectionTests` in the full EnsembleCore run (2026-11-10)

- Evidence: `testProjectionUsesCachedArtworkImmediatelyAndSkipsReloadForRatingChanges` (`NowPlayingArtworkProjectionTests.swift:31`, `XCTAssertTrue`) failed in 2 of 3 whole-package `swift test -q` runs on the stream-retry branch and passed in the third, and in 3 of 3 runs of its own filter. Playback code is not involved; it looks order- or timing-dependent on shared artwork cache state.
- Impact: a red full-suite run with no real regression.
- Next step: run the package a few times with `--filter 'NowPlayingArtworkProjectionTests|Artwork'` to find the sibling test that leaves the cache populated.

## Suspected: an offline download of an original may end a playing stream (2026-11-10)

- Evidence: offline downloads request `/library/parts/...` with the same client identifier as playback (`PlexMusicSourceSyncProvider.swift:1654-1680`), and Plex ends the previous direct-play session for a client on any new part request (stream drop proposal, section 3). The Plex log keeps about 10 hours and held no offline download, so it is unobserved; the one-download-per-server gate covers streams only.
- Impact: a download running while a track streams at original quality could cut the stream (-1005) the same way the prefetch did.
- Next step: in one simulator run, start an offline download of an original while a delayed stream plays, then search the Plex log for "Terminated session" on that client. Only if it appears, make downloads of originals wait behind a stream download (Felicity's decision 2 in the proposal).

## Audit, 2026-11-10: network and server health checking

From a read-only audit; nothing here is a reproduced defect. One `NWPathMonitor`
(`NetworkMonitor.swift`) owns device state; `PlexAPIClient` and its
`ConnectionFailoverManager` own per-server state. Ranked by stability gain per unit of work.

- **Suspected: a route change on the same interface is invisible** (M). The monitor publishes
  only network type and Low Data Mode, so Wi-Fi to Wi-Fi or a cellular route change does not
  invalidate the chosen server endpoint or trigger a health check. Next step: publish a
  debounced path-change generation and have routing and stream recovery (step d of
  `docs/investigations/2026-11-10-stream-drop-recovery-and-fallback.md`) use it.
- **No timing data for a stream's connection** (S). Next step: record `URLSessionTaskMetrics`
  and retry/probe timing per stream, without URLs or tokens.
- **Stale "offline" can show while a fresh check runs** (M). Next step: move server state to
  `checking` on a routing change.
- **A recently healthy endpoint gets a sequential head start of up to 3 s** before the other
  candidates race (M). Next step: after a route change, race it with the alternatives under
  the same local, remote, relay order.
- **The Plex WebSocket has no ping** (S/M), so a silently dead socket is noticed late. Next
  step: `URLSessionWebSocketTask.sendPing` on a modest interval.
- **`NWPath.isExpensive` is not used** (S/M). It could gate optional prefetch and downloads
  on cellular or hotspot; never user-requested playback.
- **Playback probes the server before it asks for the stream** (L). Letting the real request
  be authoritative, with bounded failover on failure, is simpler but a broad change.

Checked and found reasonable: the 1 s network debounce, endpoint ordering, coalescing of
identical probes, the health cache lifetimes, and the five-minute sync fallback.

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

## Pre-existing, weigh later: streaming tracks have no sample-gapless or file-backed SmartMix handoff (2026-11-10)

- Evidence (reviewer's boundary notes, from reading the code): an uncached streaming track ends through a cached-file reload rather than a sample-gapless handoff (`AudioPlaybackEngine.swift:2392`), and a streaming outgoing track has no file-backed SmartMix crossfade path (`AudioPlaybackEngine.swift:1426`). Serializing direct downloads (one per server) can delay the successor's download further on a short track or a slow link, so more boundaries take this path.
- Impact: a possible audible gap or no crossfade at the boundary after a track that was still streaming; unmeasured.
- Next step: measure the boundary after a short original-quality track on a slow link, then decide whether the successor's prefetch needs to start earlier or the handoff needs a streaming path. Not authorized to change.

## Confirmed: deleting a track loses Hidden choices and leaves dangling IDs (2026-11-10)

- Evidence (read): `LibraryWriter.removeMissing` calls `HiddenMediaStore.removeMissing` for artists, albums
  and tracks, which prunes their Hidden entries for good, and removing a track cascades its playlist
  membership rows. The queue, play history, pins and the Siri index keep the removed IDs.
- Impact: a temporary wrongful removal (a short inventory that passed the checks) loses the user's Hidden
  choices even after the track returns on the next pass, and leaves queue, history, pin and Siri entries
  pointing at rows that no longer exist.
- Next step: decide whether deletion should keep Hidden entries (prune only on a later pass that confirms the
  absence) and which owners should drop dangling IDs when `removedTrackRatingKeys` is reported. Not fixed.

## Apple Music sync failure shows an opaque error (suspected)

- Evidence: on the iPhone SE with Media & Apple Music revoked, the log line was
  `Sync failed for appleMusic:device:system:library: The operation couldn’t be completed. (EnsembleCore.AppleMusicLibraryError error 0.)`
  (session `2026-11-10-131550`, step 3c). `AppleMusicLibraryError` has no
  `LocalizedError` description, and `AppleMusicSourceDetailView` shows
  `syncErrorMessage` verbatim in red.
- Impact: suspected; a user who revokes access sees that raw text on the Apple
  Music source page instead of a "Allow Apple Music access in Settings" message.
  Not confirmed on screen.
- Next step: read the Apple Music source page after a revoked sync (UI text) and,
  if it is the raw text, give `notAuthorized` a localized description.

## A Plex library cursor vanishes when its server is unreachable after launch (explained, by design)

- Evidence: on the iPhone SE (`$TMPDIR/se-playback/results/n12` and `n14`,
  2026-11-10 15:40 to 15:56) server `…3ccca` library 7 failed four full syncs
  with `NSURLErrorDomain -1004` and its library cursor row was gone afterwards;
  its 9696 tracks stayed. Code read only: `SyncCoordinator.performStartupSync`
  calls `invalidatePlexReconciliationCursors`, which `removeCursor`s every Plex
  library cursor on each cold launch to force an authoritative pass. The
  UI-test runs relaunched the app, so the cursor was cleared at launch and the
  failed fetch never recreated it. Not a writer fault.
- Impact: confirmed explanation. While a Plex server is unreachable after a
  launch its library has no cursor, so the next successful sync is a full one.
  No rows are lost. It reads like data loss in a store comparison, so compare
  Plex cursors only across runs that did not relaunch the app.
- Next step: none required; if the full re-read after every cold launch proves
  costly on large libraries, revisit that startup rule.
