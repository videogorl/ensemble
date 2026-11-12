# On Deck

Things agents notice outside their task: bugs, workarounds, over-complex code, a native
API that would replace custom machinery. Each entry gives evidence, impact and a next
step, and says whether it is suspected or confirmed. Remove an entry when it is fixed.
An entry does not authorize the work; Felicity picks what gets done.

## Open: Siri AI does not route voice add or create station to the app (2026-11-12)

- Evidence: six phone builds on an iPhone 16 Pro (iOS 27.3, typed Siri); table in the investigation note, "Withdrawn
  2026-11-12". Siri AI queries one entity kind per request, a different one each run, and on the last build 0 of 4
  adds reached our intent: Siri created "ZZ Test Siri AI" in Apple Music and added there. Create station was "not
  supported" without `playAudio`. The schema code is parked on `parked/siri-ai-audio-schemas` (24cc5782).
- Impact: on Siri AI phones, "add this song to <playlist>" is answered by Siri itself and can write to Apple Music;
  play still works through the SiriKit extension (4 of 5 on the build without `playAudio`).
- Next step: retry only on a later iOS 27 build where Siri queries the playlist kind for add destinations reliably, or
  once Apple documents how Siri AI chooses the entity kind; start from the parked branch.

## Confirmed: the shared matcher strips a trailing kind word for every kind (2026-11-12)

- Evidence: phone session log, Siri AI, "Play my focus playlist": `audio search kind=artist query='focus playlist' found=2`
  and the artist "Focus On The Family Radio Theatre" played. `SiriPhraseNormalizer.queryVariants` adds
  `strippingPossessiveAndTrailingMediaType` ("focus") for any search, so a prefix match scores 0.84 against an artist.
  The shared matcher is unchanged (the schema path that refused another kind's query was withdrawn).
- Impact: SiriKit and any other `rankCandidates` caller with `requestedKinds` of an artist, album or track can still
  match a "... playlist" request to those kinds.
- Next step: make the stripped variant count only when the stripped word's kind is requested (or no kind is);
  `SiriMatchingTests` and the SiriKit handler tests need a read first, which this change did not undertake.

## Confirmed: foreground launch work starts about 0.75-1.3 s later than before (2026-11-12)

- Evidence: iPhone SE, build 202611120623.9162, cold icon launch: `didFinishLaunching` 06:25:00.100,
  `configurationForConnecting` .132, scene phase `active` 06:25:01.429. Before the background-launch change the work
  started at `didFinishLaunching`; it now starts at the first `.active` for any launch without a URL or user activity.
- Rejected earlier signals: `applicationState` is `.background` at `didFinishLaunching` in this scene-based app, so it
  cannot tell a plain launch from an intent. `UIScene.willEnterForegroundNotification` arrived 1.0 s after the scene
  connected and only ~0.29 s before `.active`, and it races the scene-phase handler: the `.inactive` phase flipped the
  scheduler back and the Siri refresh, KVS bootstrap and startup sync were skipped (06:28:12). Scene connection can also
  happen in the background.
- Impact: health checks, WebSockets and startup sync start later on a plain launch; not yet shown to be visible.
- Next step: measure time-to-content on Home before and after; only if the delay is visible, look for an earlier signal.

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

## Confirmed: an Apple Music sync timeout is reported as a cancellation (2026-11-11)

- Evidence (iPhone 16 Pro logs, 2026-11-11): `07:25:10.495 [ERROR] Apple Music data request failed path=/v1/me…
  NSURLError message=The request timed out.` is followed 2 ms later by `⏹️ SyncCoordinator: Cancelled sync for
  appleMusic:device:system:library without surfacing an error`; the same pair at 09:24:10 and 09:54:03.
  `SyncCoordinator.failSourceSync` treats `error is CancellationError || Task.isCancelled` as a cancellation, so
  a timeout that arrives while the task is cancelled is classified by task state. Suspected, not shown by the
  log: whether the task was cancelled before or after the timeout.
- Impact: the status is restored silently and no error is shown; retry treats it as a user cancel. No partial
  fetch is committed (`fetchPages` throws on any failed page).
- Next step: classify by the error first, then by task state. The sync freeze ended with step 3e.

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

## Side findings from the step 3d phone test (2026-11-11, iPhone SE, build `202611111150.4978`)

Report: `$TMPDIR/ensemble-devmcp-checks/group-3d.md`. None of these come from step 3d.

- Confirmed: after a playlist is renamed, a track row's menu still offers "Add to <old name>". The recent
  target is observed by id (`PlaylistActionPresentationHost`, `TrackListRuntimeObservation`), so a title change
  does not refresh it. Next step: include the title in the observed projection.
- Confirmed: a song added to a playlist while offline is queued (`Enqueued playlistAdd`) but the playlist's
  count and rows do not change until the upload replays, and no toast or pending mark was visible. It landed
  3 s after reconnect. Next step: decide whether a queued add should show at once like a queued rename does.
- Suspected: adding a song already in a Plex playlist does nothing and says nothing (count stays, no toast, no
  `Enqueued`). Probably Plex ignoring the duplicate. Next step: confirm against the endpoint and decide whether
  to tell the user.
- Not run: reordering a playlist by dragging. Device MCP's drag moves neither playlist rows nor queue rows;
  needs a finger.

## Suspected: the first Queue-indicator tap after opening Now Playing can mark Queue without showing it (2026-11-11)

- Evidence (iPhone SE, build `202611111345.4519`, after the larger tap areas in `7989ef52`): 20 of 20
  indicator taps chose the right panel, but once, a Queue tap made right after Now Playing opened left the
  Now Playing page up with Queue marked selected. Seen once, through Device MCP taps.
- Impact: small; a second tap fixes it.
- Next step: try by hand right as the sheet settles; if it reproduces, look at the page selection racing the
  open animation.

## Suspected: repository seed helpers and one decoded field have no production caller (2026-11-11)

- Evidence (step 3e caller search across `Packages/`, `Ensemble/`, `EnsembleWatch/`, the Siri extension and
  tests): `LibraryRepository.upsertTrack` and `upsertGenre`, and `PlaylistRepository.setPlaylistTracks`, have
  no production caller since 3b to 3d moved every sync write onto `LibraryWriter`'s batch methods. About 20
  test call sites seed stores through them, and about a dozen test fakes implement them for the protocols.
  `fetchGenres` is called only by a protocol-extension default and by tests. Separately,
  `AppleMusicConnector.Attributes.hasCatalog` is decoded and never read (since `a387ff2c`), and
  `PlaylistViewModel.isPlaylistPendingCreation` is read only by a test (since `3fd55d25`, 2026-09-30).
- Impact: dead surface the tests keep alive; nothing wrong at runtime.
- Next step: seed tests through `batchUpsertTracks`/`setPlaylistTrackSnapshots`, then drop the three
  protocol requirements and their fakes. Not authorized by this entry.

## Suspected: a background refresh and the foreground resume of its handoff can run at once (2026-11-11)

- Evidence (iPhone SE, build `202611111416.1954`, debug route started just before foregrounding): the refresh
  handler was `triggered` at 14:20:20.155 and `Resuming background refresh handoff in foreground` started a
  second run at 14:20:21.007 while the first was still going; two `handoff saved` lines; the first returned
  `needsRecovery=true` while the resume was in progress. The end state was clean (`handoff cleared`).
- Impact: unknown; duplicated work at least. Only seen with the debug route, which runs in the foreground;
  a system-delivered refresh that is still running when the app is opened may do the same.
- Next step: read how the foreground resume decides a handoff is abandoned, and whether it should wait for
  a refresh that is in flight (`isRefreshInFlight`).

## Fix did not hold: Apple Music playlist sync still rewrites two playlist headers every sync (2026-11-12)

- Evidence: 16 Pro build `202611111729.7573`: each sync wrote the same two headers, differing only in
  `compositePath`, in the same sync that logged "inventory withheld: MusicKit lists playlists the API list
  lacks". So the two are playlists the REST list lacks: `fetchPlaylistHeaders` gives them no REST artwork URL
  and `playlistInput` falls back to MusicKit's `artwork.ensembleResolvableURL()` (`AppleMusicConnector.swift`),
  a full `musicKit://` URL whose parts other than `aat` change per read (inferred: the logs do not print
  paths). Their bodies were not re-read (`needsBody` was false: dates equal); only the header was rewritten,
  each time marking artwork stale and the Siri index changed.
- Fix: that fallback now stores only the `aat` asset (`AppleMusicArtworkPath.stable`), what `getArtworkURL`
  reads, so a new image still writes. The first sync after the update writes those two once.
- Remaining: on the phone, two syncs after the update must log zero `Apple Music` header writes
  (`differs: compositePath`). If they still write, the `aat` itself varies or the artwork alternates with nil:
  print the stored and incoming path hashes next. Remove this entry once confirmed, with the diagnostic line.
- Phone result, 2026-11-12 (iPhone 16 Pro, session logs from builds `202611111806.5525` through
  `202611120844.8867`, all containing `1ef74494`): every Apple Music playlist sync still wrote
  `p.1YeW3rpCkzaPXR` and `p.V7VYlM7CoLPe16` with `differs: compositePath`: 5 of 5 syncs on 2026-11-11
  between 18:53 and 21:06, and 7 of 7 sessions that synced on 2026-11-12. So the `aat` value itself varies
  between reads, or the artwork alternates with nil. Not fixed.
- Code read (branch `diag/apple-music-header-churn`): the comparison is `PlaylistSyncState.headerMatches`
  (exact string equality; no normalisation on write: `upsertPlaylist` stores `input.compositePath` as is).
  `AppleMusicArtworkPath.stable` strips only `musicKit://` URLs that carry `aat`; an `https` URL, or a path
  segment that varies, passes through untouched. Hypotheses, unproven: (1) `artwork.url(width:height:)` returns
  a non-`musicKit` URL for these two playlists (generated mosaic), which `stable` does not touch; (2) the `aat`
  value or the path part varies per read; (3) the artwork alternates between a URL and nil.
- Diagnostic now in: `LibraryWriter.write` logs, on each header write whose `compositePath` differs, the stored
  and incoming path shape (nil/empty, length, SHA-256 prefix, scheme+host, path with long segments as lengths,
  query parameter names) and `valuesDiffer=` (the parts or query names whose values differ). Next step: run two
  syncs on the 16 Pro, read those lines for `p.1YeW3rpCkzaPXR` and `p.V7VYlM7CoLPe16`, then decide: compare a
  stable part only, or keep the stored path when the playlist's dates are unchanged. Remove the diagnostic with
  this entry.
- PROVEN CAUSE (16 Pro, build `202611121404.6631`, two syncs on 2026-11-12, sessions 140928 and 141257): stored
  and incoming `compositePath` are both 377-character https URLs with query names `X-Amz-Algorithm,
  X-Amz-Credential,X-Amz-Date,X-Amz-Expires,X-Amz-Signature,X-Amz-SignedHeaders` and
  `valuesDiffer=query.X-Amz-Date,query.X-Amz-Signature`; sync #2's stored value equals sync #1's incoming one.
  So `artwork.url(width:height:)` returns a pre-signed (AWS SigV4) URL, fresh on every read, which
  `AppleMusicArtworkPath.stable` (musicKit:// only) passes through. Each rewrite queues a `.pathChanged` artwork
  invalidation (`PlaylistRepository.recordPlaylistArtworkInvalidationIfNeeded`), which wipes the artwork caches
  and sends `.artworkInvalidated` (every `ArtworkView` reloads), and the changed `sourcePath` makes
  `cachePlaylistArtwork` download the image again; the Siri index also changes (`artworkPath` is in its items).
- Fix status: NOT built. The stored URL is fetched lazily (`ArtworkLoader` -> `getArtworkURL` returns an https
  path as is) and `X-Amz-Expires` is not recorded anywhere (unknown), so ignoring signature-only differences
  could leave an expired URL stored. Options and a decision are with the lead; see the branch hand-off report.
- Latent, not fixed: `reconcilePlaylist` builds its header with `canEdit: true`, no REST artwork and a
  MusicKit-only date, so after a playlist mutation the next list sync rewrites that header once (bounded).

## Implemented, awaiting phone checks: background launches skip the foreground launch work (2026-11-11)

- Done on `perf/background-launch-work`: a process launched in the background no longer starts the early health
  checks, WebSockets, startup sync, Siri/Spotlight refresh, iCloud bootstrap or download healing until its first
  `.active` scene phase. Design: `docs/investigations/2026-11-11-launch-pipeline-cost.md`. Phone checks:
  `docs/reference/physical-device-backlog.md` ("Background launch work").
- Next step: run those checks, then a Release Time Profiler cold launch to attribute the 14.9 s CPU. Remove this
  entry when the phone checks pass.

## Confirmed: every cold launch removes the Plex library cursors, about 9 s of sync work (2026-11-11)

- Evidence: `SyncCoordinator.performStartupSync` calls `invalidatePlexReconciliationCursors` (`SyncCoordinator.swift`
  near `:1527`, `:1532`), forcing a full re-read of 5 sources: `14:30:03.093` to `14:30:11.928`, 8.8 s on the 16 Pro.
  `performStartupSync(registrations:)` already forces a full sync when the last one is over 24 h old.
- Impact: battery and heat on every foreground cold launch; also network use.
- Next step: trace why the invalidation was added (git blame, `ON_DECK.md` "A Plex library cursor vanishes ..."),
  then relax it to once per 24 h with the stamp stored beside the cursor. Needs the owner's approval: it changes
  the "authoritative pass every launch" rule. Not changed.

## Confirmed: the download healing scan re-reads the same files on every foreground (2026-11-11)

- Evidence: `downloadTruncationScan completed=331 ... elapsedMs=887` plus `downloadHealing ... elapsedMs=1216`, with
  `truncated=0 artworkMisses=0`, at 14:30:17, 14:34:17, 14:35:40, 14:36:52 (`OfflineDownloadService.swift:1938`,
  `:2114-2125`, `:1645-1655`). `AVAudioFile(forReading:)` runs on every file each pass.
- Impact: 0.9 to 1.2 s of file I/O per foreground (2.8 to 3.7 s on a cold cache).
- Next step: a per-file verified stamp (path, size, mtime) rescanning only changed or new files, with a full scan
  after an app-version change. Risk: corruption with unchanged size and mtime is missed.

## Suspected: two health passes at launch, 1.5 s apart (2026-11-11)

- Evidence: `Startup health checks complete in 1.49s` at 14:30:02.907, then `account_inventory_refresh force=true`
  `Health refresh complete in 1.46s` at 14:30:04.369. Call site of the forced refresh not traced.
- Impact: about 1.5 s of probes to 3 servers, once per launch.
- Next step: find the caller of the forced refresh and skip it when the early pass finished under about 10 s ago.

## Confirmed: the library map is built three times in one startup (2026-11-11)

- Evidence: `libraryMap generation=1,2,3` at 11:41:27, 11:41:31, 11:41:34 (4.6, 2.0, 1.6 s); one build at 14:30.
- Impact: CPU and heat during startup sync. Scene-only; no effect on background launches.
- Next step: coalesce rebuild requests made during startup sync into one rebuild after it ends. The 21,654-track map
  itself needs its own design (paged or per section).

## Suspected: Siri index rebuilds with `changed=false` and repeated offline target reconciliation (2026-11-11)

- Evidence: `siriIndexRebuild ... changed=false` 6 of 8 times (146 to 322 ms); 23 offline reconciliation lines in 9 s.
- Impact: low, 0.15 to 0.3 s each.
- Next step: skip the rebuild when no source committed since the last one. Low priority.

## Suspected: leaving the scene stops network monitoring even while audio plays (2026-11-11)

- Evidence: the `.background` scene-phase handler calls `networkMonitor.stopMonitoring()`
  (`EnsembleApp.swift:408`) unconditionally. `SyncCoordinator` reacts to reconnects only through that monitor.
- Impact: a track playing with the app in the background (foreground launch, or an intent process that later had a
  scene) does not refresh server health or reconnect after Wi-Fi changes until the next foreground. Pre-existing.
  An intent-only process with no scene keeps its monitor (`prepareForBackgroundPlayback` starts it).
- Next step: keep monitoring while playback is active, then verify with the Wi-Fi off/on phone check.

## Suspected: Siri played `kind=album entity=26197` for a request that was not an album (2026-11-11)

- Evidence: iPhone 16 Pro run, `$TMPDIR/ensemble-16pro/report-3.md` check 5 and `logs3` (temporary files).
- Impact: a spoken request resolved to a different kind than asked; cause unknown.
- Next step: log the media type Siri sent and whether it preselected the item, then reproduce.

## Confirmed duplication: the Add to Playlist sheet and `PlaylistActionService.addTarget` pick a target separately (2026-11-11)

- Evidence: `PlaylistActionSheets.swift:220` carries its own target-selection rule; Siri/Shortcuts Add uses
  `PlaylistActionService.addTarget`. They currently agree (table-tested) but can drift.
- Impact: none today; a future rule change must be made twice.
- Next step: have the sheet call `PlaylistActionService.addTarget`.

## Suspected: the Dock menu is briefly empty right after launch (2026-11-11)

- Evidence: `MacDockMenuAppDelegate` loads pins asynchronously after `applicationDidFinishLaunching`; a Dock menu
  opened before that load finishes lists no pins.
- Impact: cosmetic; self-heals once pins load.
- Next step: check on a Mac whether a right-click in the first seconds shows no pins, then render from the cached
  pin list.

## Suspected: the Spotlight reconcile cannot remove orphans (2026-11-11)

- Evidence: `SystemMediaIntegrationService.swift:506` deletes items the index holds but the projection does not
  present, plus the baseline diff. An item in neither the current catalog nor the saved baseline is never deleted.
- Impact: a leftover result for a playlist deleted before the upgrade; unmeasured.
- Next step: delete the app's Spotlight domains once for the projection version, then reindex in full.

## Suspected: audio frequency analysis is Ensemble's largest CPU cost during playback (2026-11-11)

- Evidence (iPhone 16 Pro, Debug build `202611111703.9499`, Time Profiler attached for 3 minutes while the
  phone was in thermal state Serious): `FrequencyAnalysisService.analyzeFile` (`AudioAnalyzer.swift:628`) took
  2.9 s of Ensemble's 10.2 s of CPU, in four bursts of 1 to 1.8 s about 20 s apart, on a worker thread.
  Ensemble as a whole was 5.6% of one core (idle floor 2 to 3%); a cold launch cost 14.9 s of CPU in 23.6 s.
  Debug builds inflate this (unspecialised generics). No disk writes and negligible GPU were seen.
  Report: `$TMPDIR/ensemble-16pro/warm-phone-profile.md` (temporary file).
- Impact: not the cause of the warm phone in that recording (test tooling, screen-on time and Siri AI were
  larger), but it is recurring work during playback.
- On-device power trace, same day, unplugged, Debug build (analysis: `$TMPDIR/ensemble-16pro/power-trace-analysis.md`,
  temporary file): 7 minutes of locked background playback against 6 minutes paused. Whole-phone drain was about
  7.9 %/hr playing (busy stretch excluded) against 4.2 %/hr paused. Ensemble used about 2.8% of one core while
  playing, no GPU, almost no network after the first 20 s, and nothing at all once paused (suspended 7 s after
  the pause). One burst (34 G instructions, 1.5 s on core) had FLAC-scanning stacks consistent with this
  analysis. SwiftUI/AttributeGraph frames were in 34 of 96 steady samples while the screen was locked, and
  WatchConnectivity frames appeared every 20 to 60 s.
- Code findings (2026-11-11, branch `perf/playback-background-cpu`): the analysis feeds only the Aurora
  visualizer (SmartMix, loudness and the Plex waveform use other data). It ran for every track change and every
  scheduled prefetch whenever the visualizer setting was on, regardless of scene phase or visible surface. The
  four bursts were four different tracks (a tester skipping), not re-analysis: results are cached per track in
  memory (cleared only by `stopAnalysis`, never evicted) and persisted as a `.freq` sidecar only for files under
  `Downloads`, so streamed/cache files are re-analysed every launch.
- Fixed on the branch: analysis is deferred while the app is backgrounded or no visualization surface is visible
  and replayed (current track first) when one appears; the in-memory cache is bounded to 8; the Mini Player
  waveform and Now Playing scrubber ignore progress ticks while the scene is backgrounded and resync on return;
  the watch position tick is sent only while the watch is reachable.
- Remaining, not built: persist sidecars for cache files too (disk and invalidation policy); stop an in-flight
  analysis when the app backgrounds; remaining SwiftUI work while locked is unidentified (needs a trace);
  `WatchCompanionSessionSnapshot.updatedAt` makes the publisher's equality check never match.
- Phone confirmation: Release or Debug build, same 7-minute locked playback power trace as before, visualizer on,
  Now Playing closed. Compare Ensemble CPU time per minute, the count of `analyzeFile` bursts (expect none while
  locked or with Now Playing closed), SwiftUI/AttributeGraph samples while locked (was 34 of 96) and
  WatchConnectivity samples (expect none with the watch app closed).

## Siri AI (iOS 27) resolves audio requests before our SiriKit extension (suspected, evidence in console log 2026-11-11)
- Evidence: for the 18:49 to 18:58 typed "Add this song to playlist ZZ Test Voice" attempts the iPhone log has no
  `EnsembleSiriIntentsExtension` process at all, while `AudioAppIntentsExtension` ran an
  `AudioEntityIntentValueQuery.values(for: SiriKitQueryCriteria)` and `assistant_cdmd`/`searchtoold` matched the
  `AppCustomMediaPlaylistTitle` group. For the play request at 17:50:59 the same query was followed by
  `EnsembleSiriIntentsExtension` launching at 17:51:00. The add never reached our code.
- Impact: voice Add on Siri AI phones is decided by Siri's own playlist entities (vocabulary, Spotlight); the extension
  path and its tests only matter where Siri hands the request over.
- Next step: App Intents phase 4 (iOS 27 audio schema `addToPlaylist`, `docs/reference/app-intents-design.md`); first
  retest with a day-old playlist to separate "new playlist unknown to Siri" from "Siri never offers add".

## Metal command buffers submitted from the background (confirmed, Ensemble console log 2026-11-11 18:48)
- Evidence: hundreds of `kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted` errors per second from
  Ensemble while it was backgrounded (about 19k IOGPU lines in the filtered 18:40 to 19:05 log).
- Impact: wasted CPU/GPU work and log noise while playing in the background; likely the aurora/Metal visual still
  rendering. Next step: stop the Metal view's display link when the scene is not active.

## Hiding a merged row's representative leaves its saved shortcut unresolved (confirmed by reading, not run)
- Evidence: with Merging on, `SiriMediaRows.presented` shows the preferred source's copy as the merged row and a saved
  Shortcuts entity pins that copy's `ratingKey||sourceCompositeKey`. Hiding that library makes
  `IndexItemEntityQuery.entities(for:)` drop it (`visibleItems`) and `SiriPlaybackCoordinator.storedItem` return nil, though
  an equivalent copy in a visible library is still shown. Playlists have the same gap only for the picker; Voice Play falls
  back to the name (`SiriPlaybackCoordinator.scoped`).
- Impact: a saved Play Song/Album/Artist shortcut shows as missing until re-picked.
- Next step: in `entities(for:)`, when a saved reference is not visible, look up its merge identity
  (`SiriMediaRows.mergeIdentity`) among the visible rows and return that row, keeping the saved id as an alias.

## Shortcuts picker misses off-index albums and artists whose names differ only by apostrophes (confirmed by reading)
- Evidence: `LibraryRepository+Search.swift` `boundedNameSearch` matches the normalized words with `CONTAINS`, which handles
  "&", "and" and punctuation ("AC/DC", "Earth, Wind & Fire") but not apostrophes: "dont believe the truth" does not contain
  "Don't Believe the Truth". Songs are covered by the bounded normalized scan in `SiriPlaybackCoordinator.libraryCandidates`;
  there is no scan for albums or artists.
- Impact: typing such a name in a Play Album or Play Artist picker finds nothing when the item is outside the capped index.
- Next step: add `mapAlbums` / `mapArtists` batched, cancellable scans beside `mapTracks` (with defaults for test doubles) and
  score titles in `libraryCandidates` as for songs, keeping the best `limit × 10`.

## A Focus restoration run that never completes is never retried (confirmed by reading)
- Evidence: `SharedRestoration.ensure` keeps one `run` until `work` returns; if `EnsembleFocusFilter.refreshCurrent()` never
  returns, every later caller joins that run, times out and fails closed for the life of the process
  (`SharedRestoration.swift`, `BackgroundPlaybackReadiness.swift` `restoreFocusFilter`).
- Impact: in that process Play pickers return no entities and background playback throws until the app is relaunched.
- Next step: bound the underlying run (cancel it after a longer limit) or let `ensure` start a new run after a timeout.

## "Added to <playlist>" can be said before the server takes the write (confirmed by code read)

- **Evidence:** `enqueuePlaylistAddOptimistically` returns `.completed` whenever the network monitor is connected, after
  persisting the mutation and scheduling the background drain. With internet but the Plex server unreachable, the
  Add to Playlist Shortcut says "Added to …" while the write is still pending. Found in the Codex review of the Siri AI
  withdrawal (2026-11-12); the behaviour predates it. The `SIRI_SHORTCUT:` log line says `accepted` for this reason.
- **Impact:** a spoken confirmation that is early, not wrong: the mutation is stored and replays. Low.
- **Next step:** decide whether the Shortcut should await the first write attempt (bounded) before choosing between
  "Added" and "Will be added".

## Siri offers two identical "Moby – Artist" rows for a typed artist request (suspected)

- **Evidence:** iPhone 16 Pro, build `202611121011.2049`, 2026-11-12 10:19: "Play Moby in Ensemble" got "What do you
  want to play in Ensemble?" with two identical "Moby – Artist" rows; picking the first played "Division" (payload
  `kind=artist entity=17156`). Logs: session `session-2026-11-12-101839.log` from that run.
- **Impact:** an extra tap and no way to tell the rows apart. Probably the same artist from two sources or two library
  sections offered as separate SiriKit media items.
- **Next step:** read what `INPlayMediaIntent` resolution returns for "Moby" (count, source of each item) and whether
  equivalent artists should be collapsed the way merged playlists are.

## Startup-to-playback measurements on the iPhone SE (2026-11-12, build `202611121020.2369`)

Request → `playing`, from session logs (app state, not audible output):

| Case | Result |
|---|---|
| Cold launch, mini-player Play, downloaded restored track (Wi-Fi on or off) | 0.14–0.18 s |
| Warm resume after ~1 min in background | 0.11–0.18 s |
| Cold launch, mini-player Play, restored Plex streaming track, uncached | 0.56–0.71 s (4 runs); `downloadComplete` always after `playing` |
| Same, in the stream cache | 0.25–0.33 s |
| Cold launch, tap a Plex album track, uncached | 0.79–0.89 s (2 runs); server decision + first byte is 0.5–0.7 s of it |
| Cold launch, tap an Apple Music device-library track | 1.28–1.61 s, almost all inside Apple's player |
| Cold launch through a Play Playlist Shortcut (local/cached first track) | 2.3–2.6 s from process start; 1.9–2.2 s of it is "No connected servers — running health checks" |

- **Not reproduced:** the code-read hypothesis that Play waits on a whole-file prebuffer for a restored streaming track.
  No `[preBuffer]` line was logged for any restored streaming track, including taps 6–15 s after launch.
- **Implemented, awaiting phone checks (branch `fix/siri-play-health-wait`):** the plain play entrances (Siri
  `INPlayMediaIntent` execution and the Shortcuts play actions for a track, album, artist or playlist) pass
  `serverHealth: .deferUntilPlaybackStarts` to `prepareForBackgroundPlayback`: no health wait, no early-task join.
  They start the explicit startup pass (`performStartupHealthChecks`, once per process, no forced pass) after the
  play call's source resolution or launch returns, not once it is `.playing`. Every other caller keeps the awaited
  default. The race this opens is fixed at its cause, see "Fixed in this branch" below. Owed rows:
  `docs/reference/physical-device-backlog.md`, "Shortcut cold play without the health wait".
- **Network state at a cold launch (why the wait is short):** `NetworkMonitor` persists `lastKnownNetworkState` and
  seeds `snapshot` from it at init (`NetworkMonitor.swift` init and `persistState`), so a second-or-later launch
  starts at the previous session's state, normally `.online(.wifi)`, and `SyncCoordinator.lastObservedNetworkState`
  starts there too. Only the first path update is debounced (1 s), so `hasLivePath` is not true for about 1 s;
  `startNetworkMonitorAndAwaitCurrentState` returns at once for a seeded connected state. A seeded `.offline` or
  `.limited` then live Wi-Fi, or a different interface, schedules a forced refresh through
  `SyncCoordinator.handleObservedNetworkState`. The measured SE run was cached online then live online, so no
  transition refresh was scheduled.
- **Unexplained:** one Shortcut run (the first after the shortcut was created) had ~31 s with no app log lines between
  `NetworkMonitor: Started monitoring` and `Server connectivity ready`. Next step: repeat a first-run-after-create and
  capture a sysdiagnose-level log to see whether the wait is in Shortcuts or in `prepareForBackgroundPlayback`.
- **Not tested:** restored mid-track position on an uncached stream; lossless or very long files; cellular.
- Logs: `/private/tmp/claude-501/-Users-felicity-Developer-projects-ensemble/1b53a1b0-2eca-4f16-ad9f-8a206686c84e/scratchpad/logs1`.

## Disabled-library cleanup repeats on every launch (confirmed, cause found 2026-11-12)

- **Evidence:** every SE session log on 2026-11-12 (20 of 20) has three `Cleaning up data for removed source: plex:…`
  lines for the same three disabled Plex sections, each ending `libraryItems=0, downloads=0, targets=0`; 1.7–1.9 s of
  serial store work per launch.
- **Cause:** the iCloud library-flag pull at launch calls `AccountManager.applyLibraryFlags`, which adds a library that
  is disabled both locally and in iCloud to `disabledSources` although nothing changed (`AccountManager.swift:543-548`);
  `CloudSyncCoordinator` then calls `cleanupRemovedSourcesIfPresent` (`SyncCoordinator.swift:2059`) for each. Deliberate
  since `6f0bd4b0` ("Harden synced disabled library cleanup"): it evicts leftover rows when flags already match, for
  example after a restore from backup.
- **Safety:** an unavailable server cannot enter this path (only an explicit synced `isEnabled == false` does), and
  `shouldPreserveSourceKey` and the persistence fence guard the delete.
- **Separate from** the per-launch cursor removal (`invalidatePlexReconciliationCursors`), which hits enabled sources.
- **Status:** merged to `develop` 2026-11-12, awaiting phone check (owed rows in
  `docs/reference/physical-device-backlog.md`). `cleanupRemovedSourcesIfPresent` skips a Plex source with no sync running
  and nothing stored (library rows, source row, hub items, downloads, targets, pending mutations, artwork files,
  lyrics cache, library cursor); any failed check or Apple Music source still runs the full cleanup. Remove this entry
  once the phone check passes.
- **Phone result (SE, build `202611121306.9716`):** the three skips log and no cleanup runs, but the probes still span
  about 1.5 s of wall time during launch (was 1.7–1.9 s), so the saving is small. Next step if it matters: time each
  probe step (artwork and lyrics directory listings, the mutation fetch that materialises every record) and see
  whether it is its own cost or contention with the Siri index rebuilds that run at the same moment.
- **Accepted omissions:** the skip probe does not check the global orphan-audio sweep or empty home-feed snapshot pruning;
  other paths still run them.
- **Resolved:** `.sourceCleanedUp` only triggers reloads in the Library, Search, Home and Playlist view models; the Siri
  index and background refresh do not subscribe. Skipped passes drop those redundant reloads too.

## Intermittent test: `testCancellationAfterAnAcknowledgedDeleteIsNotAFailureOrAReplay` (suspected timing race, 2026-11-12)

- **Evidence:** 2 failures in about 8 full EnsembleCore runs on branch `fix/skip-empty-disabled-library-cleanup`, always
  1 of 1321–1322 tests: `SyncCoordinatorPlaylistMutationTests.swift:1082`, `("[]") is not equal to (["playlist-1"])`
  ("the cancelled cleanup is the accepted limit: the row waits for a later pass"). Passes alone. The branch does not
  touch the playlist delete path. Confirmed on `develop`: 14 failures in 80 isolated runs (5 of 40, then 9 of 40).
- **Impact:** a red full-suite run now and then; it also means the "cancelled after acknowledge leaves the row" limit is
  timing-dependent: sometimes the local cleanup finishes before the cancellation lands.
- **Next step:** make the stub cancel deterministically before the local cleanup step, or assert "row kept OR removed, never a replay".

## Fixed 2026-11-12, SE checks passed, cellular check owed: a refresh cancelled playback's own server probe

Mechanism (code-read, from Codex's review): a configuration change bumps the connection revision
(`AccountManager.swift` ~1155) and `PlexAPIClient.synchronizeConfiguration` (`PlexAPIClient+Connections.swift`
~147-168) replaces the failover selector and retires the old one. A probe in flight then fails `isCurrentAttempt`
and `attemptFailover` throws `CancellationError` though the caller's task is live. `SyncCoordinator.ensureServerConnection`
rethrows it (cancelled errors are not swallowed), `PlaybackTransportCoordinator.resolvePlaybackSourceImpl` turns any
failure there into `PlaybackError.serverUnavailable`, and `PlaybackSessionStateMachine.shouldRetryResolution` retries
only NSURLError codes, so a reachable track failed to start. A Play tap during a foreground launch had the same
exposure. The stream decision request had the same path (`recordServerAttemptSuccess` throws `CancellationError`;
`shouldRetryStreamURLRequest` is false for it).
Fix: `PlexAPIClient.refreshConnection` re-probes once when it ended in cancellation, the caller's task is not
cancelled, and the connection revision or routing generation changed since the call began (debug log
"Connection refresh superseded ..."); `PlaybackTransportCoordinator.streamDecision` takes its existing
refresh-and-retry branch for a cancellation the task did not ask for. A second supersession surfaces as before.
The startup retry in `PlaybackService+Loading.swift` (refresh, then reassemble) also covers `cannotFindHost` and `dnsLookupFailed` for a URL assembled from a replaced endpoint, at the cost of one bounded extra attempt (500 ms sleep plus a refresh) for a genuinely unresolvable host.
Phone check: `docs/reference/physical-device-backlog.md`, "launched on cellular after last use on Wi-Fi".
