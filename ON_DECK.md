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

## Suspected, not reproduced 2026-11-10: the Mac app opens no window without `-ApplePersistenceIgnoreState YES` (2026-11-09)

- Evidence: launching the built `.app` on this Mac showed no window until that flag was
  passed (2026-11-09); stale window-restoration state is the suspected cause. On 2026-11-10
  (build 202611101933.9772, Debug, launched with `open -n <built .app>` and no flag, right
  after quitting a flagged run) a 1100x612 window was on screen within 20 s with the Home
  tree populated, so the failure did not reproduce.
- Impact: a user with the same saved state would see the app launch with nothing on screen.
- Next step: reproduce with the saved state kept from the failing launch (copy
  `~/Library/Saved Application State/com.videogorl.ensemble.savedState` aside when it
  happens), then check the scene and restoration setup.

## Suspected: Mac app logs a credential-read timeout at every launch and Home stays on "Loading..." for the first seconds (2026-11-10)

- Evidence: both launches of build 202611101933.9772 logged `[ERROR] AccountManager:
  credential read timed out; preserving cached source data` within 1 s of start, with
  `WebSocketCoordinator: Starting — accounts=0`. The library still loaded from cached source
  keys (`LibraryViewModel: using provider-authoritative cached source keys while credentials
  are unresolved`); Home showed "Loading..." on the first read and was populated on the second
  launch. `MattPlex` also logged offline websocket errors.
- Impact: unknown; sign-in never prompted and no data was lost, but a slow Keychain read on
  this loaded Mac delays Home and starts websockets with zero accounts.
- Next step: time the credential read at launch on an idle Mac to see whether it is load or a
  real regression from the account-polling cleanup at `82b1928e`.

## Confirmed: a track that appears twice in a detail list plays its first occurrence (2026-11-09)

- Evidence: seen while checking playlist detail on the simulator; tapping the second copy
  starts the queue at the first.
- Impact: wrong start position in playlists that repeat a track.
- Next step: start playback from the tapped row's index, not a lookup by track id.

## Confirmed: Favorites header has an extra gap on Mac (2026-11-10)

- Evidence: build 202611101933.9772, 1100 pt wide window, window-screenshot pixels (1366 px
  wide, so 1 px is about 0.8 pt; the accessibility tree gives no frames). Toolbar bottom at
  y=55 in both. Album detail: artwork top at y=94, a 39 px gap, and 73 px between the
  artwork bottom and the first track row. Favorites: artwork top at y=191, a 136 px gap
  (about 97 px more), and about 166 px between the artwork bottom (365) and the first row
  (531), against 73 px on Album detail.
- Impact: Favorites wastes about 100 px above and about 90 px below its header on Mac.
- Next step: compare the Favorites header container's top and bottom padding with Album
  detail's header in the shared detail screen.

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

## Confirmed gaps in stream drop resume (2026-11-10, review of steps c and d)

- **A resume re-requests the original URL** (confirmed, M). `StreamingAudioPipeline.beginResume` uses
  `configuration.request`, so after leaving home mid-track a resume goes to the LAN address and fails to
  connect (up to 15 s). Mitigation in place: after a path change, a resume that fails to connect is not
  retried, so the service reload (which selects a fresh endpoint) follows one attempt later. Fix: the
  transport coordinator hands the pipeline an async closure that rebuilds the track's stream request from
  its cached decision and the server's currently selected endpoint (`assembleStreamResolution`); the ETag
  and `Content-Range` checks stay. It needs the `Track` kept alongside the pipeline, an async `beginResume`
  with a guard against a second resume starting during the await, and a test, which was judged over the
  50 source lines allowed for it.
- **Codex review of steps c and d (through `32a7bff9`, delivered 2026-11-11).** Two races it found are fixed:
  a second `beginResume` no longer starts a request beside one in flight, and a stale response's validation
  failure no longer abandons the task that replaced it. Its third finding (a path change cancelling a healthy
  download) was already fixed at `6c352019`. Left open, none demonstrated: a resumed response is not rejected
  for a `Content-Encoding` (the request asks for `identity`); Play after a deferred failure resumes buffered
  audio before recovery starts, so `pausedStreamNeedsRefresh` is not set; there is no fixed deadline from a
  drop to the item failing while bytes keep trickling. No test covers the two races.
- **A resume with no route waits indefinitely** (confirmed from the code, S). The pipeline's session uses
  `waitsForConnectivity = true`, so a resume requested while offline does not time out and the 30 s window
  does not bound an offline period. While playing, the engine's rebuffer timeout still ends the stream;
  while paused, the pipeline holds its direct-download server slot until Play or the network returns (only
  prefetch consults the slot). Next step: decide whether a paused stream should release the slot or give up
  after a long offline period.

## Audit, 2026-11-10: network and server health checking

From a read-only audit; nothing here is a reproduced defect. One `NWPathMonitor`
(`NetworkMonitor.swift`) owns device state; `PlexAPIClient` and its
`ConnectionFailoverManager` own per-server state. Ranked by stability gain per unit of work.

- **Suspected: a route change on the same interface is invisible to routing** (M). The monitor now
  publishes a debounced `pathGeneration` / `pathChanges()` and stream resume uses it (step d), but
  server endpoint selection and health checks still do not: Wi-Fi to Wi-Fi or a cellular route change
  does not invalidate the chosen endpoint. Next step: have `AccountManager`/health checking use
  `pathChanges()` too.
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


## Confirmed: originals cached by an older build cannot be played offline until replayed online (2026-11-10)

- Evidence: the stream cache now serves a direct original only when its manifest entry is marked verified.
  Entries written before step e have no mark, so the lookup misses (`PlaybackTransportCoordinator.swift:266`)
  and, offline, throws "offline" (`:276`); `resolveOfflinePlayableTrack` and the availability resolver miss the
  same way. Found by the round-two review, by reading.
- Impact: once, after updating: recently streamed original-quality tracks that are not offline downloads will
  not play without a connection until they are streamed again. Offline downloads are unaffected.
- Next step: verify an unmarked direct entry on first use (the check takes well under a second) and mark it,
  instead of treating it as a miss; that also saves the one re-download.

## Suspected: a prefetched download adopted mid-check never reports damage early (2026-11-10)

- Evidence: `onDamageFound` is attached only to downloads the engine creates (`PlaybackService.swift:804`); a
  prefetched one it adopts (`AudioPlaybackEngine.swift:1101`) never gets it. By reading; not reproduced.
- Impact: low. The prefetch's own wait normally records the fallback, and playing into the damage still falls
  back; only the early switch for a later seek is lost.
- Next step: attach `onDamageFound` when the engine adopts a prefetched download.

## Suspected: two metadata-duration truncation checks still judge a direct original (2026-11-10)

- Evidence: `PlaybackService+Loading.swift` (the cached-file probe in `playCurrentQueueItem` and the prefetch
  probe) compare a file's container length with the library's duration and evict and re-download on a mismatch.
  The investigation's step e said library metadata must not judge a direct original. The stream's own check
  (`recordCompleted`) no longer does; these two were left, since they re-download rather than fail.
- Impact: an honest file whose metadata duration is wrong is downloaded twice, then plays. No fallback is
  involved.
- Next step: for a direct original, drop both comparisons and rely on the media check.

## Confirmed: the streaming decoder cannot stream ALAC or a moov-at-end M4A (2026-11-10)

- Evidence: a review decoded `afconvert -d alac` output and an ffmpeg fast-start file to 0 frames through
  `StreamingAudioDecoder`; the converter error is only logged (`StreamingAudioDecoder.swift` near line 330).
  A moov-at-end M4A fails with `parseFailed('optm')`.
- Impact: such an original now falls back to a lower-quality transcode (step e) instead of playing at its
  own quality, with the neutral "Playing at reduced quality" notice.
- Next step: find why AVAudioConverter yields no frames for ALAC; separately, play a completed non-streamable
  original from its downloaded file through the native engine so it stays at original quality.

## Suspected: a seek inside already-downloaded bytes of a direct original still waits for the whole download (2026-11-10)

- Evidence: the progressive decoder (`StreamingAudioDecoder`) is not seekable, so `AudioPlaybackEngine.seek` throws
  `streamingSeekUnavailable` for every streaming source. The seek fix waits for the in-flight download and then
  plays the verified file from the target; it cannot jump inside bytes that are on disk but not yet complete.
- Impact: on a slow link, a seek into audio that is already downloaded shows buffering until the whole file is down.
- Next step: only if the phone shows long waits, make the growing file seekable (WAV/FLAC offsets), which is a
  decoder change, not a seek-path change.

## Confirmed: a browse list's saved filter text keeps filtering with the field hidden (2026-11-11)

- Evidence: on the iPhone SE the Artists tab showed "1 artist" and Playlists "1 playlist" across relaunches while
  the store held 674 artists and 50 playlists. `Ensemble.FilterOptions.Artists` and `.Playlists` held
  `searchText` "Metric" and "Foc" (typed in an earlier test run). The filter field only appears after a pull
  down, and the Filters sheet showed nothing active.
- Impact: a forgotten filter makes the library look almost empty, with no visible sign of why.
- Next step: decide whether filter text should persist across launches at all; if it does, show the field (or an
  active-filter mark on the Filter button) whenever text is set.

## Suspected: pressing Next while offline halts and the track does not start when the network returns (2026-11-11)

- Evidence: SE, build `202611110741.9140`: with Wi-Fi off mid-stream, Next halted on the next track at 0:00 with
  "No internet connection"; turning Wi-Fi back on did not start it; Retry did. The backlog's contract says a
  halt caused by an unreachable server retries once when the connection returns.
- Impact: the user has to press Retry after a brief drop.
- Next step: read the session log in `$TMPDIR/ensemble-devmcp-checks/logs1` for the halt reason and whether the
  health check fired; compare with `PlaybackServiceFlowTests`' reconnect case.

## Suspected: Pause pressed right after Retry on the halt toast is lost (2026-11-11)

- Evidence: SE, same build: Retry on a halt at 11700, then Pause at once; playback skipped to the next track and
  played. 11700 always fails, so this may be the ordinary skip after the retry failed, with the pause dropped.
- Impact: breaks "never start playback while paused" if the pause was registered before the skip.
- Next step: script it with the playback probe (a test beside `testG...` halt cases) to see whether the pause
  arrived before the skip.

## Confirmed: small findings from the 2026-11-11 SE pass

- A track row's "Get Info…" context-menu item does nothing (three tries); album Get Info works.
- The offline toast for an uncached track shows the raw text "Network error: The operation couldn't be
  completed. (NSURLErrorDomain error -1004.)".
- Share Link… on an Apple Music track gives a `music.apple.com` URL, not a song.link URL.
- Suspected: Songs did not re-sort after switching the sort back to Date Added until the screen was reopened.
- Suspected: Repeat read All twice without being set (after `repeat=off` by debug link).
- Suspected: a "replace queue?" confirmation after tapping a Search song row was not visible or in the
  accessibility tree and blocked touches (`queueReplacementConfirmationRequested queueCount=7` in the log).
- Automation launch-argument overrides (shuffle, streaming quality) are written back to preferences.
- Next step for each: reproduce by hand or with a scripted test before fixing.

## Confirmed: the queue row's drag handle is narrow (2026-11-11)

- Evidence: on the iPhone SE the reorder handle is 24 pt wide (Apple's minimum is 44). It is `UITableView`'s own
  reorder control (`QueueTableView.swift`, editing mode). The context button beside it had the same problem and
  now has a 44 pt wide, full-row-height touch area (`QueueRowActionsButton`), so the gap between the two no
  longer plays the row.
- Impact: a drag that starts just left of the handle can still open the actions menu instead of reordering.
- Next step: only if it still annoys in use; widening the system control means replacing it. The other track
  rows' overflow buttons (`overflowControlDimension` 25) were not measured.

## Suspected: a queue drag reorder drops the row in the wrong place (2026-11-11)

- Evidence: Device MCP drags from row 2's handle to row 4 swapped rows 1 and 2 (three times, 0.2 s and 0.6 s
  holds). May be the tool's synthesized path rather than the app.
- Next step: repeat with a finger; if it reproduces, look at `moveRowAt` and the drag delegate both being
  enabled in `QueueTableView.swift`.

## Suspected: Siri may pick a suggested shortcut item on a misheard request (2026-11-11)

- Evidence: the shortcut queries returned no suggestions on purpose ("Siri may auto-pick an unrelated entry when
  speech capture is incomplete"). They now suggest the six most recently played items of each kind so the
  shortcuts list in Shortcuts and Spotlight (Felicity, 2026-11-11). The voice path was not re-tested.
- Next step: by voice, ask for an album or playlist that does not exist and one spoken unclearly; Siri should
  ask or fail, not play a suggested item.

## Owed checks that need hardware the iPhone SE does not have (2026-11-11)

Kept in `docs/reference/physical-device-backlog.md`; listed here so they are not forgotten.

- A SIM: a Wi-Fi to cellular switch mid-track at original quality; G18 (pause, switch network, Play); "stream
  on cellular" off makes non-downloaded tracks unavailable.
- An AirPlay receiver or HomePod: AirPlay then interruption, the `render=` clock line after an AirPlay switch,
  early segment end on AirPlay, the HomePod Siri route, the visible AirPlay fallback.
- A phone call and a Bluetooth device: a call during a load (G14); Bluetooth disconnect during a load.
- Felicity's own iPhone: an Apple Music library of many thousands of songs (step 3c); an uploaded library-only
  Apple Music track; the iCloud layout round trip between two devices.
- A TV or external display, an iPad and the Apple Watch: Screen Mirroring Now Playing, step 6c panes, the watch
  mirror.
- The Mac: rating and download redraw, swipe, drag-out, and a real mouse click on the queue's context button.

## Codex review of step e, the seek fix and the resume follow-ups (2026-11-11, at `4db0c641`)

- Fixed the same day: an original is no longer marked verified when the converter rejected a packet and audio is
  missing, or when a short file decodes under half its container length (the 10-second exemptions are gone);
  the give-up after a failed resume is decided under the lock, so a path change cannot slip a replacement in.
- Declined, by the lead's judgment: "a seek to 0 during the original's own download should wait for it". A
  seek to the start restarts the direct stream at once at original quality; waiting up to 30 s for the download
  would be worse. The cost is the bytes already downloaded. Revisit if Plex is seen ending the new request.
- Suspected, open: during playback a converter error is still only logged (`StreamingAudioDecoder.decode`), so
  a mid-file bad packet is a silent gap; the fallback fires only if the end-of-download check then flags the
  file. Next step: decide whether a converter error mid-play should trigger the fallback at once.
- Coverage the review asked for and nothing provides: both resume races under deterministic scheduling, and
  Pause, Next or Stop while a seek wait is pending.

## Codex review of step 3c (2026-11-11, at `aecf4a2c`): fixed and deferred

- Fixed before the merge: an Apple Music list that repeats a song, or whose pages state different totals or
  include an empty page that points onward, no longer yields an inventory, so it deletes nothing.
- Deferred, confirmed by code path: **a rating made during a sync's write can be overwritten locally.**
  `LibraryWriter.writeRows` reads stored tracks, then the queued ratings, then writes; a rating saved in
  between is rewritten with the server's older value while its upload stays queued. The upload still succeeds
  and the next sync restores the value. Fix: keep the queued rating inside `batchUpsertTracks`' own
  transaction, with a gated interleaving test.
- Deferred, confirmed by code path, inherited from step 3b: **a full pass interrupted between its delete
  saves is not retried until the daily interval.** Tracks, albums and artists are deleted in separate saves;
  a kill after the tracks leaves an empty album until the next inventory. Fix: mark a full apply unfinished
  before its first write and let recovery bypass the daily throttle.
- Known limit, predates the branch: Apple Music has one source key (`appleMusic:device:system:library`), so a
  different Apple Account signed in on the device reconciles against the same cached rows.
- Unmeasured: memory on a library of many thousands of songs (whole-library arrays, one track transaction).

## Suspected: a local playlist edit is protected only inside the process that made it (2026-11-11)

- Evidence: `LibraryWriter.localEdits` (create, optimistic add, local delete) is an in-memory map. It
  protects the edit from a read that began before it, in the same process; a relaunch forgets it. The
  durable `PendingMutationRecord`s cover queued renames, adds, removes and deletes, but creates and
  reorders are never queued (`MutationCoordinator` throws offline for both), so nothing durable names them.
  After a relaunch, an optimistic body whose server date is unchanged survives (no body read), but a
  just-created playlist with no server date can be replaced by a lagging server's complete-empty body.
  Not reproduced; Plex applies a create at once, so this is mostly an Apple Music window of seconds.
- Impact: a playlist created, then the app killed before its first refresh, may show empty until the
  server catches up and its date changes.
- Next step (Option B): a nullable `CDPlaylist.localEditAt` and a tombstone store for deletes (a new
  Core Data model version, lightweight migration), consulted like the queued-mutation records. Do it only
  if the window shows up in the log: a created playlist's body read back empty right after a relaunch.

## Suspected: a queued playlist mutation that never uploads freezes its playlist indefinitely (2026-11-11)

- Evidence: `LibraryWriter.queuedPlaylistMutations` protects every playlist named by a pending
  (`status == pending`) add, remove or delete record: its header and body are skipped and an inventory
  cannot delete it. A retryable record that never uploads (a stale payload against a playlist the server
  lost, a permanent 4xx that `isConnectionFailure` treats as retryable) keeps the record pending, so the
  playlist never takes a server change. Not reproduced.
- Impact: one such playlist shows its pre-queue state and cannot be removed by a sync.
- Next step: bound the protection (give up after the mutation's retry limit, or when the record's age passes
  a ceiling) and make the pending-mutations UI show which playlist is held.

## Suspected: uploading a queued playlist mutation schedules no refresh after its record is gone (2026-11-11)

- Evidence: `MutationCoordinator.drainQueue` replays an add, rename or delete through
  `syncCoordinator.addTracksToPlaylist` / `renamePlaylist` / `deletePlaylist`, whose own refresh (and, for
  Apple Music adds, the reconcile loop) runs while the record is still `pending`. `LibraryWriter` then skips
  that playlist's header and body (a queued add or remove) or keeps its title (a queued rename). The record is
  deleted afterwards and nothing reads the playlist again, so the reconcile loop logs "completed" for a batch
  the writer skipped. Not reproduced.
- Impact: after a queued add uploads, the playlist can show its pre-upload body until the next sync,
  WebSocket update or foreground pass.
- Next step: delete the record before the replay's refresh (the record only guards the window before the
  upload is acknowledged), or run one playlist pass after `drainQueue` removes a playlist record.

## Suspected: a REST-only Apple Music playlist is read again every pass (2026-11-11)

- Evidence: `AppleMusicPlaylistBodyProof.verifyREST` accepts a REST body with no reported total only when
  MusicKit's read of the same playlist agrees. A playlist the REST list has and MusicKit lacks has no
  witness, so its body is withheld, the header keeps its stored date, and `needsBody` is true again on the
  next pass. Not reproduced (needs `meta.total` absent on the device; see the step 3d device checks).
- Impact: one REST call per such playlist per pass, and the pass reports `.partial`, so background recovery
  stays outstanding while the playlist exists.
- Next step: read the device log for `Apple Music REST playlist body unavailable` / `body failed` with the
  same id on consecutive passes. If it happens, accept a REST body with no total when the playlist is
  REST-only and two consecutive reads agree, or stop reporting such a playlist as unresolved.

## Suspected: on `.partial` the UI still shows "last synced" and the list cursor advances (2026-11-11)

- Evidence: `completeSourceSync` sets `.lastSynced` before returning `.partial`, and `LibraryWriter.applyBatch`
  records the playlist cursor for any full-list batch that was not rejected, unresolved bodies included
  (their dates stay, so the bodies are retried; the cursor only dates the list read). A stale-rejected
  pass records nothing.
- Impact: Settings shows a clean "last synced" time while a playlist body is owed; only the log
  (`Playlists <scope>: N body reads unresolved`) and the background handoff say otherwise.
- Next step: give `MusicSourceSyncStatus` a partial state (or a detail line) and show it, or hold the
  playlist cursor's incremental date back while a body is unresolved.


## Suspected: a local delete that keeps failing leaves the last playlist's row (2026-11-11)

- Evidence: after the server acknowledges a playlist delete, `LibraryWriter.removePlaylist` retries the local
  delete three times (50 ms, 200 ms, 1 s) and then surfaces the error. For any playlist but the last, the next
  inventory removes the row. For the last one an empty inventory deletes nothing, so the row stays.
- Impact: a deleted playlist keeps showing until another playlist exists. Needs a persistent store failure,
  which would break much more than this.
- Decided by the lead on 2026-11-11: no durable marker for now. Next step if it is ever seen: write a
  pending-mutation record with a `localCleanupOwed` status after the remote delete (no schema change; replay
  filters on `pending`, so the remote delete is not re-sent) and consume it on the next playlist pass.


## Suspected: playlist favourite writes run outside the writer's playlist chain (2026-11-11)

- Evidence: `MutationCoordinator+CollectionFavorites.swift` writes a playlist's rating through
  `storeCollectionRating` (direct `performBackgroundContext`) and enqueues the `.collectionRating`
  pending mutation, neither inside `LibraryWriter.performPlaylistEdit`. Renames, adds, removes and deletes
  now run in the chain. Inherited from before step 3d; found by Codex review #3.
- Impact: a playlist pass fetched before a favourite toggle can overwrite the local rating for a window,
  and a toggle that fails restores the previous rating outside any ordering with a pass.
- Next step: route the playlist case through `performPlaylistEdit(editing:)` and teach the writer's
  playlist apply to keep a locally edited rating for the retention window. Not authorized by this entry.
