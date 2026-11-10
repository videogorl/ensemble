# On Deck

Things agents notice outside their task: bugs, workarounds, over-complex code, a native
API that would replace custom machinery. Each entry gives evidence, impact and a next
step, and says whether it is suspected or confirmed. Remove an entry when it is fixed.
An entry does not authorize the work; Felicity picks what gets done.

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
- Impact: the full suite is not a reliable gate while the host is busy.
- Next step: rerun on an idle Mac to separate load from real defects; widen the 1 s waits to
  event-based waits with a long timeout.

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

## Audit, 2026-11-10: custom machinery a native API might replace

From a read-only audit; none of these is a confirmed defect. Ranked by expected stability
gain per unit of work. Sizes are S, M or L.

- **Account loading polls every 25 ms** (`AccountManager.swift:268`, S). A detached Keychain
  read is followed by a poll for up to 1 s (commit `8ab31f92`, Keychain can block at macOS
  startup). Next step: await the task's value and race it against one deadline; keep the
  timeout and the cached-source fallback.
- **Scroll index stops momentum by toggling scrolling** (`ScrollIndex.swift:141`, S/M). A
  UIKit probe finds the enclosing `UIScrollView` and turns scrolling off and on before a jump
  (commit `fdb0d4cc`). Next step: try `.scrollPosition(id:anchor:)` (iOS 17) in the scroll
  owner and see whether a jump during momentum behaves acceptably.
- **StageFlow is a `UICollectionView` cover flow** (`StageFlowCarousel.swift`, 196 lines, M).
  Next step: prototype `ScrollView` with `.scrollTargetBehavior(.viewAligned)` and
  `.scrollTransition` (iOS 17); keep UIKit if the 3D transform or cell reuse is lost.
- **Artwork has its own resolved-image cache beside Nuke's** (`ArtworkLoader.swift`, 988
  lines, M). Next step: check whether Nuke's pipeline cache can hold the resolved images
  while keeping stable identity, offline fallback and targeted invalidation.
- **Siri AirPlay handoff polls the audio route every 250 ms** (`AppDelegate+Siri.swift:463`,
  M). Next step: observe `AVAudioSession.routeChangeNotification` with one timeout; needs a
  HomePod check on a physical phone.
- **Toasts use a separate window** (`ToastView.swift`, 588 lines, M/L) so they appear above
  sheets (commit `405ecc4f`). A root `.overlay` is simpler but hides toasts behind a sheet.
  Low gain unless that behaviour is relaxed.

Decided by Felicity on 2026-11-10: the AirPlay menu item that presses the button inside
`AVRoutePickerView` (`AirPlayButton.swift:28`) stays as it is. The account polling, scroll
index and Siri route polling items are scheduled as one batch.

Checked and left alone: the visible AirPlay control, artwork's persistent cache and retry
rules, the Plex WebSocket polling fallback, and the size of `WatchRootView.swift`.

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
