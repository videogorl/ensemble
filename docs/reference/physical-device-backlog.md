# Physical device backlog

Checks the simulator could not prove, kept until they are run on real
hardware. See [`rearchitecture-plan.md`](rearchitecture-plan.md) section 7.

- Add an item when a step's acceptance check cannot run, or runs only partly,
  on a simulator. Name the commit it applies to.
- Run iPhone items on the iPhone SE (Guest's iPhone, UDID
  `00008030-00090C493C13402E`, no passcode) unless another device is named
  (Felicity, 2026-11-09). Prove the installed build first.
- An item the SE cannot run (no Apple Music sign-in, SIM, AirPlay receiver,
  TV, Bluetooth output, paired watch or second iCloud client) stays listed
  with the missing prerequisite named beside it.
- Remove an item only with physical evidence, and record that evidence in the
  step's note under `docs/investigations/`.
- A later step can supersede an item. Replace it rather than keeping both.

## iPhone SE — shared browse, 2026-11-06

Guest's iPhone, UDID `00008030-00090C493C13402E`, iOS 27.0.1.
Production source: `01b96a83`. The installed build was initially 0.4.0
`202611042151.0196`; the acceptance run rebuilt the same app source as
0.4.0 `202611061142.0196` with the new iPhone UI tests.

| Check | SE result |
| --- | --- |
| Artists: sort, filter, search, artist detail | Passed in XCUITest |
| Albums: sort, Downloaded Only, Hide Singles, search, album detail | Passed in XCUITest |
| Playlists: sort, search, playlist detail | Passed in XCUITest; no playlist mutations |
| Genres: search, genre detail | Passed in XCUITest; no sort/filter controls offered |
| Play a song from album detail, confirm progress, pause | Passed in XCUITest |
| Songs: sort, filter, search; accessible rows after scrolling | Passed in XCUITest twice consecutively on Nov 8, no skips |

Sort/filter state and existing search text were restored by the passing checks.
On Nov 8, all five `PhoneBrowseAcceptanceUITests` passed twice consecutively on
this SE, with zero failures and zero skips. `testSongs` is no longer skipped.
The rebuilt installed app was 0.4.0 `202611081007.8943`. Core and UI package suites
and the standalone iOS Debug build also passed after the change.

The timeout came from XCUITest's full accessibility snapshot: iOS killed Ensemble
at its process memory limit (2098 MiB), before delivering the toolbar tap. A
user-approved DEBUG hook bounds native table accessibility to its header, visible
cells and footer only for Songs automation launches. Default/release accessibility
and normal app behavior are unchanged. The test also distinguishes track rows
from the table's header/footer and reads the nested sort menu's child chevron.
See the [Nov 8 investigation](../investigations/2026-11-08-se-songs-xcuitest-snapshot.md)
for the cause, implementation boundary and evidence.

Final manual readback confirmed Date Added descending, Downloaded Only off, no
selected genres, empty search and paused playback. The phone was locked through
Device Hub and the GUI lock released. The SE has no passcode; Home wakes it.

Nov 8 evidence: `/tmp/ensemble-songs-20261108/browse1.xcresult` and
`browse2.xcresult` (five passes each); `core-final.log`, `ui-final.log`,
`ios-build-final.log`, `final-sort.jpg`, `final-filters.jpg`, `final-paused.jpg`.
No new device crash reports appeared across the two acceptance runs.

Device Hub observations (restarted after ignored taps):

- Albums' red filter dot corresponds to saved Hide Singles = on, with
  Downloaded Only = off. Hide Singles defaults to off in code; the dot is not
  an unexplained default filter.
- The letter index did not overlap the visible album covers at rest. It did
  overlap the genre-chip strip above the grid.
- Launch logs contain `tabChanged` to Settings for Albums, Genres and Songs,
  but not Artists or Playlists; it does not occur on every launch.

Local evidence from this run (temporary files may expire):
`/tmp/ensemble-se-20261106/browse5.log` and `browse5.xcresult` contain the four
passing browse checks and playback; `scoped8.log` and `scoped8.xcresult` capture
the final Songs query timeout. `albums-grid.jpg`, `filter-retry.jpg` and
`paused.jpg` show the visual observations and paused player. `songs-wake.jpg`
shows the lock screen that blocked the manual follow-up. Device launch logs
are in `/tmp/ensemble-se-20261106/closing-device-logs/`.

This SE pass does not cover Albums StageFlow rotation or Songs pull to refresh.
The iPhone, Mac, iPad and Watch items below remain independent checks.

## iPhone (run on the iPhone SE)

These items were deferred on 2026-11-02 and written for the iPhone 16 Pro. On
2026-11-09 Felicity moved them to the iPhone SE. They are not passed and not
verified until they run there.

### TV Now Playing scene accessory, 2026-10-17 fix

At `c273feb5`, Felicity confirmed on 2026-10-18 that the view looks good on her
real TV. The fixed build `202610171652.2735` was installed on the iPhone 16 Pro
running iOS 27.0.1 before that check. See the
[investigation and evidence](../investigations/2026-10-17-tv-now-playing-screen-mirroring.md).

- The real-TV report confirms the dedicated presentation. Individual checks
  of lyrics timing, pause/skip, phone dismissal, reconnect/cold launch and
  audio-only AirPlay were not itemized; retain those as focused follow-ups if
  timing or lifecycle symptoms recur. Do not infer them from simulator results.
- iPad multiwindow handoff and interactive external windows remain unverified
  on hardware. The integration onto the later playback split is build/test
  checked separately; it has not been reinstalled for another physical run.

### Streaming decoder PCM crash, at `d735bf26` or later

The 2026-10-30 abort in `AVAudioCompressedBuffer` is fixed and covered by
`StreamingAudioDecoderTests` on macOS only.

WAV (transcoded and direct PCM), MP3, AAC and FLAC passed on the SE on
2026-11-10 ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)).

- Direct-stream an AIFF track to the end (none was run).
- Fixed at `a890293c`, passed on the SE on 2026-11-10 (build `202611100947.9277`
  at `d92d77e2`): with a successor queued, the direct WAV stream of 8731 used to
  drop with `NSURLErrorDomain -1005` because the prefetch of 8732 requested its
  own direct file and Plex keeps one direct-play session per client. Direct
  downloads are now one per server at a time. In two runs at original quality
  (`testG1b`, `testG1g_SuccessorPrefetchWaitsForDirectDownload`) 8731 stayed
  `kind=directHTTP` with no "failed after startup", the prefetch of 8732 was
  deferred and started 16 s later when 8731's download ended, and 8732 then
  played from the stream cache. The Plex log still shows "Terminated session"
  for the phone's client when the next request starts, but only for a download
  that had already finished; the app saw no failure. Still owed: the same pair
  on a slow link, where the current download is still running at the boundary.
- Offline downloads of originals were not changed. Whether one ends a playing
  stream is unobserved (the Plex log keeps about 10 hours); see `ON_DECK.md`.

### Bounded retry of a stream that fails after loading

Covered on macOS by a `PlaybackServiceFlowTests` regression test and the real
11631 transcode bytes; not exercised on the phone. Plex track 11631 ("Christmas
in June", AJR) is a truncated FLAC on the server, so its transcode is shorter
than the metadata and is rejected after it loads.

The retry, skip and halt passed on the SE on 2026-11-10 with 11631 and 11700
([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)).

- Fixed at `4f791813`: invalid audio data now fails the track without a retry.
  Before that, a failure 1.2 s into playback made the retry start at 1.0 s,
  where the short-transcode check has no length to judge, and the truncated
  audio played. On the SE (build `202611100615.4791`, 2026-11-10) 11631 was
  skipped at once in two of two runs, and 11631 then 11700 halted.
- Changed at `4a8dd66d`: a dropped stream is retried inside a 30 second window from
  its first failure (the engine's no-audio limit) instead of twice, including when a
  reload fails at resolution or startup. Reloads are at least a second apart, and
  none starts with under three seconds of the window left. Covered by
  `PlaybackServiceFlowTests`; the real-network part is this item.
- Play a normal track and drop the network mid-stream (Airplane Mode, then back
  on). Confirm it still recovers and keeps playing. The scripted run could not
  do this: Control Center gestures take 60 to 120 s on the SE, longer than the
  track. Run it by hand or with a longer track.

### Playback error toasts and halt recovery, `fix/playback-failure-handling`

Covered on macOS by `PlaybackServiceFlowTests` only; the simulator UI and the
phone were not run. Tracks that fail today: 11700 ("Noah's Descendants", HTTP
400) and 11631 at a non-original quality (above). The twenty one pilots tracks
14291, 14292 and 14300 no longer fail: their server files were replaced at
about 22:50 on 2026-11-09 and now decode cleanly.

- Skip: a bad track followed by a good one shows "Skipped <title>" and
  playback continues. Halt: two bad tracks in a row stop on one persistent
  "Playback stopped" toast with Retry; Retry retries, and leaving the failed
  state any other way dismisses it. With a download progress toast showing,
  the halt toast still appears at once. The mini player shows no error text.
- Tap Retry on the halt toast and press Pause at once: playback stays paused.
  Pause just as a track's retries run out (Airplane Mode mid-stream): it stays
  paused, never skips to the next track, and Play restarts the stream.
- After a halt on a bad track, toggle Wi-Fi off and on so a health check
  runs: the halted track does not restart. After a halt caused by an
  unreachable server (Wi-Fi off, or a VPN-only server with the VPN off),
  restoring the connection retries the track once; if that retry fails, it
  waits for Retry.
- A track reached by a skip that plays a few seconds and then fails halts
  with Retry instead of skipping on, also after removing an earlier queue
  track or toggling shuffle. Pause, Next, then Previous back to it and Play:
  a failure now skips again, also after Previous then an immediate Pause and
  Next back to it.
- Recovery follows the user: drop the network mid-stream, then press Next
  (the next track starts at 0:00) or Pause (stays paused; Play resumes from
  the same spot). A failure while paused starts nothing.

### Customizable Now Playing secondary actions, 2026-10-13 feature commit

Builds and SE/macOS/iPad evidence are in
[the feature verification note](../investigations/2026-10-13-now-playing-secondary-actions.md).
Physical AirPlay passed on the iPhone 16 Pro on 2026-10-14, at `09a1bcc0`.
Both the pinned native button and overflow item opened the route picker.

- Verify Apple Music availability in the real app (capability logic is covered
  by focused tests; simulator row checks used Plex).
- Verify a controlled iCloud layout round trip between two physical clients,
  including sync OFF. SE displayed actual local push and remote pull statuses,
  and coordinator tests cover gating, but those do not prove full convergence.
- Exercise the guarded visible AirPlay fallback if the native internal button
  is unavailable; normal runtime used an intact native picker hierarchy.

### Playback position fixes, at `4dfcae14` or later

Proven on macOS with a real AVAudioEngine (`AudioPlaybackEnginePositionTests`),
not on the phone or AirPlay.

- AirPlay then interruption (`9aaf9815`): switch to AirPlay, let several tracks
  advance gaplessly, then trigger an interruption (call or Siri). The paused
  scrubber and the resumed position match the current track, not the track
  that was playing at the switch.
- Pause and resume after gapless advances (`ae391278`) passed on the SE on
  2026-11-10, also from the system media controls with the app in the
  background ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)). Still owed: a later AirPlay switch logs a `render=` close to
  `observed=` and never `Ignoring render clock`.
- Relaunch and resume (`62e82bac`) passed on the SE on 2026-11-10 by the log
  and scrubber. Still owed: the Lock Screen follows the new track.
- Early segment end (`9ee8cf42`, diagnostic only): keep AirPlay playing a
  stream-cached queue. If a track ends early, read the `Segment ended early`
  line for the playhead, duration, frame counts, and file size.

### Sweep fixes, at `4dfcae14` or later

Engine and service paths are covered by EnsembleCore tests on macOS; none ran
on the phone. Name each commit by its subject until it has a hash here.

Paused Next/Previous/Play, relaunch then Next, autoplay off during an
autoplay track, and SmartMix cancel (by turning SmartMix off) passed on the
SE with Plex on 2026-11-10 ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)).

- After a Plex track hands off to Apple Music ("Unload the current item when
  the engine stops"), the duration shown is the Apple Music track's. Needs
  Apple Music.
- Apple Music pause while buffering ("Rebind Apple Music events when a pause
  starts a new session"): press Play on a paused Apple Music track and pause
  again before it starts; then resume, once in the app and once from Control
  Center. The scrubber and Lock Screen move, and the next track advances. Not
  covered by any automated test.
- SmartMix cancel by reordering Up Next during the first half of a crossfade
  (the turn-SmartMix-off variant passed).
- Downloads ("Keep in-flight installs out of the orphan download sweep"):
  while a large album downloads, remove a different downloaded album (which
  runs the orphan sweep). Every finished track of the first album plays
  offline.

### Step 2, at `31f8e27c` or later

See [the step note](../investigations/2026-10-21-step-2-composition-observation.md).

- External display: with the main scene open, start Screen Mirroring; the TV
  shows the same Now Playing model (lyrics, queue page, pause and skip stay in
  sync). The scene now receives the container from the app root (2b) and the
  model from `RootScreenModels` (2e).
- App Shortcuts: run Play Album and one other from Ensemble's section of the
  Shortcuts app; Device Hub could not scroll to it on 2026-10-26. Siri
  playlist and artist requests and a Play Track shortcut passed that day.
- Step 2f, at `15d9b8ab` or later: Low Power Mode pauses a download already
  in progress (a download queued under Low Power Mode waits and resumes when
  it turns off, 2026-10-26); turning off "stream on cellular" makes
  non-downloaded tracks unavailable on cellular; artwork that failed while a
  server was unreachable reloads when it comes back; after a sync that changes
  the library, Siri finds the new items. That last check failed on 2026-10-26:
  a request for the newest album played a different Apple Music album (step
  note).

- Steps 2c and 2d, at `cf4e8d19` or later: an album's blurred header
  backdrop. Launch, a toast, the Downloads sheet and the Autoplay and SmartMix
  toggles passed on the SE on 2026-11-10 ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)).
- Now Playing debug link, at `ebf55f2a` or later: run items 1–3 and 11–13 of
  the 2026-10-26 list using
  `ensemble://debug/now-playing?page=queue&shuffle=…&repeat=…&autoplay=…`
  instead of swipes.

### Step 1f split, at `302a5d78` or later

See [the step note](../investigations/2026-10-17-step-1f-split.md). The split
moves code without changing it; the 1b to 1e checks cover it when run on this
build or later.

- Apple Music one-at-a-time advance and Clear Queue (Plex and Apple Music,
  Autoplay on and off, with shuffle) passed on the iPhone on 2026-10-19
  (step note). Still owed: play a library-only (uploaded) Apple Music track,
  and a catalog track whose catalog match is stale but which is in the
  library.

### Step 1e snapshot, at `691211a9` or later

See [the step note](../investigations/2026-10-17-step-1e-snapshot.md).

- G7: toggle shuffle during an Apple Music track; the track keeps playing and
  the next track comes from the new order. Same during a SmartMix overlap.
- G17: in Airplane Mode, an Apple Music track is greyed out and skipped. (A
  fully streamed Plex track played offline on the SE on 2026-11-10, [2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md).)
- G18: pause an uncached Plex stream, switch from Wi-Fi to cellular, press
  Play; it continues from the same position. Needs a SIM. With Wi-Fi turned
  off and on instead, it resumed in 1.3 s at the same position on 2026-11-10.
- Watch: queue, track, and shuffle state still mirror after the snapshot
  change.

### Step 1d session lifecycle, at `2544a52a` or later

See [the step note](../investigations/2026-10-17-step-1d-session-lifecycle.md).

- Phone call during a load: the load finishes, then pauses; it resumes only
  if iOS sends the should-resume hint, and stays paused while locked otherwise
  (G14).
- Bluetooth disconnect during a load: ends paused.
- Apple Music item that fails to start: skipped once (G11).
- Next and Pause during a load, and a failed track that skips once and then
  halts, passed on the SE on 2026-11-10 with the app in the background, driven
  from the system media controls on the cover sheet ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)). Still owed on a
  literal Lock Screen, by hand: it shows playing after Next, paused after
  Pause, and the error after the halt (G11, G15). The scripted run cannot lock
  the SE with the button.

### Step 1c engine contract, at `5dfdef45` or later

See [the step note](../investigations/2026-10-16-step-1c-engine-contract.md).
Everything on Apple Music runs through the new adapter and is unproven:

- Plex to Apple Music, Apple Music to Apple Music, and Apple Music to Plex
  by natural completion, locked and unlocked. (With Next, passed 2026-10-26.)
- System Previous on an Apple Music item: the first restarts, a second within
  three seconds goes back (inferred by the adapter). The restart passed on
  2026-10-26; two quick presses restarted twice (step note, 2f device run).
- Apple Music autoplay station: items advance, the queue mirrors upcoming
  items, and a station Previous does not add a duplicate (D5).
- Lock Screen progress for native and Apple Music items.

### Step 1b queue policy, at `3e063453` or later

See [the step note](../investigations/2026-10-16-step-1b-queue-policy.md).

- End of queue and the Repeat One wrap passed in the app on the SE on
  2026-11-10, as did a shuffle toggle during playback ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)). Still owed: the
  Lock Screen shows the paused item at the end of the queue, and Next under
  Repeat One wraps from the Lock Screen.
- Q2: an Apple Music item at the end of a queue under Repeat All with autoplay
  on wraps to the first item and does not start a station.
- Apple Music boundary at the end of the queue with autoplay off: stays on the
  last item, paused.
- Q7: Next during a SmartMix transition on the last item with autoplay on
  plays the autoplay item.
- Changing repeat with a gapless successor scheduled, with the phone locked.

### Step 0, at `254691f2` or later

Rows from [`surface-checklist.md`](surface-checklist.md). Results so far are in
[the step 0 note](../investigations/2026-10-13-step-0-verification.md).

Impossible on a simulator:

- Lock Screen scrub. FAILED in the scripted SE run on 2026-11-10 ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)): after
  a drag on the system scrubber to about 70%, the app was on the next track
  at 6.8 s. It is not known whether the synthesized drag was read as a scrub;
  repeat by hand before treating it as an app defect. (Artwork, title, pause
  and Next passed on 2026-10-26; play and pause passed on 2026-11-10.)
  Passed on the SE on 2026-11-11 through Device MCP (`drag` on the Lock
  Screen scrubber, positions read from its accessibility value): forward
  from 0:21 to 1:40 of 3:02 and back to 0:32, the same track kept playing
  and advancing each time, so the 2026-11-10 failure was the synthesized
  drag. After a scrub back to 0:31 and an unlock with Home, the app's Now
  Playing read 0:36 and kept advancing. (Device MCP's `launch_app` restarts
  the app, so unlock with Home.) Seen once, not reproduced: the first wake
  after locking showed no Now Playing on the Lock Screen while the track
  kept playing; the next lock and wake showed it.
- Control Center: Next. (The tile's pause and play passed on 2026-11-10.)
- Offline playback: a blocked track toasts. (A downloaded track played with
  the network off, and a natural track change in the background after an idle
  lock passed, on 2026-11-10.)
- Siri affinity and add. (Siri media requests passed on 2026-10-26.)
- App Shortcuts: all five listed; Play Album runs.
- Focus filter offered in Settings.

Not run or only partly run on the simulator:

- Songs: genre chip filter and clear; tap a row to play; scroll to the last row
  above the mini player.
- More: open each row from More and go back; Edit Tabs open and cancel.
- Feed: scroll a hub sideways; hub order sheet open and cancel.
- Settings subpages: Merging, Sync, SmartMix, Connection Security, Track Swipe
  Actions.
- Hidden, Moods, Pins, Item info.
- Now Playing: dismiss by swipe; go to artist from Controls.
- Now Playing queue: History, shuffle and repeat toggles restored after.
- Now Playing lyrics: highlighted line advances on a track that has lyrics.
- StageFlow in landscape.
- Song permalink route.
- Download manager settings; Music source detail.
- Share: confirm the shared URL is a song.link URL.

Every other iPhone row passed on the simulator and still needs one physical
pass before step 0 is called verified.
- Step 6 shared detail screen: album, artist (including a merged artist),
  playlist (single and merged), genre, Favorites and Mood each open, show
  their sections and artwork, and play. On Artist, check the hero artwork
  does not flash or re-trim on push or back, the collapsing title appears on
  scroll, and the sort and More menus work. Passed on the iPhone 17 Pro
  simulator for album, artist, playlist, genre and Favorites only.
- Step 6b shared browse screen: Artists, Albums, Playlists, Songs and Genres
  each open, sort, filter, search, open a detail and play a track; Albums
  StageFlow rotation keeps the album in view and hides the nav bar; pull to
  refresh on Songs (not exercised in the simulator).
- Step 6d part 1, one track-list host, at `ea5b1f2c` or later: on Songs,
  album detail (track numbers, disc headers), playlist detail (artwork),
  artist favourited tracks, Mood, Search songs and Favorites, a leading and a
  trailing swipe action, a long-press context menu, tap to play with the
  play-state indicator, and a 1,000+ row Songs scroll with the scroll index.
  Also Stage Flow's track panel in landscape and pull to refresh on Songs,
  which the simulator run did not exercise. Simulator results:
  [step 6d note](../investigations/2026-11-10-step-6d-track-list-host.md).
- Step 6d part 2, one row model, at `d27961ee` or later: on Songs, a fast
  scroll away and back keeps titles and artwork; the play-state indicator
  moves to the tapped row; pull to refresh or a sync that changes tracks
  does not flicker artwork, lose the indicator or jump the scroll; a rating
  or download change shows on visible rows without scrolling (not exercised
  on the simulator: it would change data). With VoiceOver, the playing row
  announces the indicator rather than the duration (see `known-issues`).
- Step 6d part 3, the queue on the row model, at `6dc28d59` or later: on
  the Now Playing queue, rows show title, artist and artwork in Up Next,
  Continue Playing, Autoplay and History; a track queued twice shows two
  rows; a drag reorder within Up Next keeps titles and artwork on the right
  rows and plays in the new order; Remove from Queue (long-press menu)
  removes that row; skipping or tapping a row updates the list; artwork
  appears after the server comes back from offline (retry path, not
  exercised in the simulator). Drag reorder by finger, not the synthesized
  drag the simulator run used.

## Mac

- Share Link with Apple Music access denied: confirm what is shared (the code
  falls back to plain text) and whether the prompt needs in-app context. Access
  is currently allowed on this Mac, so this needs a reset of that permission.
- Control Center Now Playing tile: item shown and controls work. Media keys
  were checked instead.
- Step 1c at `5dfdef45`: play, pause, seek, Next, a gapless advance, and a
  natural end at the last item in the built Mac app.
- Step 1d at `2544a52a`: sleep the Mac while playing; after wake it stays
  paused (G22). Play and pause from the keyboard shortcut still work after
  the main-actor change.
- Step 6 shared detail screen in the built Mac app (not run: no GUI driver
  was available): the same detail kinds as the iPhone row, with artist detail
  inside the Mac split.
- Step 6b shared browse screen in the built Mac app (not run; the Mac launch
  check comes with 6c): the same five browse kinds and the picker columns for
  Artists, Genres and Playlists.
- Step 6d part 1 in the built Mac app, at `ea5b1f2c` or later: Songs and
  one album detail rendered, double-click played and context menus opened in
  the Debug build; Mac swipe (trackpad row actions), drag-out, Search,
  Favorites, Mood, artist and playlist track lists were not driven.
- Step 6d part 2 in the built Mac app, at `d27961ee` or later: a rating or
  download change redraws visible rows without a reload, and Mac swipe and
  drag-out still work on the shared row model (not driven).
- Step 6d part 3 in the built Mac app, at `6dc28d59` or later: the queue
  list renders with artwork, follows a track change, and reorder and remove
  work. Its code is unchanged by part 3; not driven
  because the Mac's session was locked during the run.
- Mac smoke, 2026-11-10, build 202611101933.9772 (Debug, `develop` at `f97addb7`,
  driven with Cua Driver; the Mac was heavily loaded):
  - Launch after the account-polling cleanup at `82b1928e`: Passed with a caveat. The
    window, sidebar and library rendered and no sign-in prompt appeared, but the log has
    `AccountManager: credential read timed out; preserving cached source data` at start
    (see ON_DECK.md); Home showed "Loading..." on the first read.
  - Step 6b browse: Passed. Songs, Artists, Albums, Genres and Playlists listed items;
    picking ABBA, Electronic (145 albums) and "am test" showed their contents.
  - Step 6 detail: Passed. Album detail (10 tracks), artist detail inside the split
    (ABBA, 1 album, 12 songs), playlist detail (14 songs) and genre detail rendered.
  - Step 6d parts 1 and 2: part 1 Passed (double-click on "(Anesthesia) – Pulling
    Teeth" logged `STATE: loading → playing`; the context menu listed Start Track
    Radio, Play Next, Add to Playlist, Go to Album and more, Escape closed it).
    Part 2 (rating or download redraw, swipe, drag-out) not run.
  - Step 1c playback: Passed. Pause, resume, Next, a scrubber seek (`seekRequested`
    then `seekCompleted` at 221.68 s) and a gapless advance at a track boundary.
  - Step 6d part 3 queue: Passed. Rows showed artwork and followed track changes; a
    foreground drag of a handle moved a row from position 1 to 3 (a background drag
    did nothing). The row-menu remove at `3d9b9443` removed "(One Of Those) Crazy
    Girls", the row whose ⋯ was pressed, not a neighbour. Pressing ⋯ was done through
    the accessibility action, not a mouse click.
  - Favorites header gap: Confirmed, see ON_DECK.md (about 97 px extra above).
  - Window without `-ApplePersistenceIgnoreState YES`: a window appeared within 20 s,
    so the ON_DECK item did not reproduce.
- Step 6c panes on a physical iPad (not run): native `NavigationSplitView`
  now serves every iPad, including iPadOS 17; Artists, Genres and Playlists
  show detail in the next column, rotation and Split View resizing keep the
  selection, and full-width kinds push. Also the iPhone tab flow after the
  shell removal, and the built Mac app (launch, ten sidebar switches, switch
  time against the 299 ms baseline).

## iPad Pro and Apple Watch

- iPad, step 6d part 2 at `d27961ee` or later: in landscape at full width,
  Songs shows the artist and album columns; album detail shows no album
  column; a playlist's "Library not synced" rows show artist and album in the
  columns, stay dimmed, and a tap shows the "Library not synced" toast.

- Watch, step 1b at `3e063453`: Next on the last track wraps under Repeat One
  and Repeat All; with repeat off, Next and a natural end leave the last track
  paused at the start.

- Siri AirPlay handoff, route-change wait (simplification batch, 2026-11-10):
  the app now waits for `AVAudioSession.routeChangeNotification` instead of
  polling every 250 ms. Needs a HomePod (not available on a simulator): ask
  Siri on the iPhone to play something on the HomePod, with the app killed and
  with it running. Playback must start on the HomePod after the app's nudge,
  without a stretch of local speaker audio, and the SIRI_APP log must show
  "Route switched to external" in the preExecute or postExecute phase.

- iPadOS 17, step 6c: accepted as untested on 2026-11-09 (no simulator
  runtime for this Xcode, no device). If an iPadOS 17 iPad becomes available:
  Artists, Genres and Playlists show detail in the next column, rotation and
  Split View resizing keep the selection, full-width kinds push, and back
  navigation keeps scroll position.

## iPhone SE — step 3a, playlist membership constraint (model 12)

Applies to the commit that adds model 12. The SE's store was copied read-only
on 2026-11-10 and migrated on the Mac (5,827 membership rows, no duplicates);
the installed app has not been touched.

| Check | Status |
| --- | --- |
| Install the 3a build over the existing SE store: the app launches and the store loads | Passed 2026-11-10, build `202611100947.9277` at `d92d77e2` |
| Playlists show their tracks and counts after migration | Passed 2026-11-10 by `PhoneBrowseAcceptanceUITests.testPlaylists`; the store copied back has 5,827 rows, all keyed, no duplicate positions, same distinct playlist-track pairs as before |
| Offline playlist targets still list their tracks and downloaded state | Owed |
| The first launch logs `Playlist membership backfill: keysFilled=... duplicateRowsRemoved=...` and later launches do not | Owed |
| A Plex playlist sync after migration (full and incremental) saves without error and leaves one row per position | Launch syncs ran and the store has one row per position; a forced full playlist sync is owed |

## iPhone — step 3b, library writer (Plex library sync)

Applies to the commit that adds `LibraryWriter`. The simulator proved full and
incremental Plex library syncs against the live server (store comparison in
`docs/investigations/2026-11-10-step-3b-library-writer.md`).

| Check | Status |
| --- | --- |
| Background Refresh delivers the same library change through the writer: add or remove a file in the owned album, wait for a Background Refresh, then see the album count, the Siri index save and the offline download follow | Owed |
| A Background Refresh near its deadline stops without leaving a partial inventory: the next launch's sync completes and counts match the server (the writer queues WebSocket batches behind a running one) | Owed |

The iPad and watch checklist sections start with steps 5 and 6.

## iPhone SE and a phone with a SIM — stream drop resume (steps c and d)

Applies to the commits "Resume a dropped direct download with a Range request..." and
"Restart a ranged download as soon as the network path changes". Proven on the iPhone 17 Pro Max
simulator with the DEBUG drop hook and in unit tests; a real network change is not proven.

| Check | Status |
| --- | --- |
| iPhone SE, WAV pair 8731/8732 at original quality: `PhonePlaybackAcceptanceUITests.testG1h_ConnectionDropMidDownloadKeepsPlaying`. The probe stays `playing`, position keeps advancing through the drop, the track ends and 8732 plays; the session log has `injectedStreamDrop` and `[StreamingPipeline] resumed` | Passed on the SE on 2026-11-10 (build 202611101056.9843): dropped at 1,015,808 of 50,699,330 bytes, resumed 0.26 s later at the same offset, state stayed `playing`, 8732 followed from the stream cache |
| A real Wi-Fi to cellular switch mid-track at original quality (needs a phone with a SIM; the SE has none): playback continues without buffering while the reserve lasts, the session log shows `resumeRequested` right after the path change, and the audio after the switch is the original file, not an MP3 transcode | Owed |
| Plex log for the SE run: no `Client stopped playback` for the in-flight part, and the ranged request is answered 206 | Passed on 2026-11-10: `range: bytes=1015808-` answered 206 with 49,683,522 bytes (the exact remainder); the only terminations fall on downloads that had already closed |

## iPhone SE — damaged original falls back to a transcode (step e)

Applies to the step e merge (`fix/damaged-original-transcode-fallback`, HEAD `01811c88`). Owner's server
tracks: 11631 (original ends at 2:14 of 4:39; its transcode is as short) and 11700 (zeroed header; Plex
answers HTTP 400). 14291 is healthy: it played all 4:52 at original quality, unflagged, on the SE on
2026-11-10, so the earlier "damaged" saved copies of the twenty one pilots tracks were truncated downloads.
No track on the server has a damaged original with a complete transcode, so "plays on past the damage" is
covered by unit tests only.

| Check | Status |
| --- | --- |
| `testG2e1_DamagedOriginalFallsBackWhenPlaybackReachesTheDamage` with 11631: flagged when the download completes, plays the original to the damage, reloads as a forced transcode at the playhead, then moves on when the transcode has nothing more | Passed on the SE on 2026-11-10: `originalFlagged ... audio ends at 133 of 279 seconds` 5.6 s in, `retrying from 133.9s`, `forceTranscode=true` with `kind=transcodedHTTP start=133.00`, next track 1 s later; no halt |
| `testG2e2_SeekAfterTheDownloadCompletedLoadsTheTranscode` with 11631: after the download finished, a seek loads the transcode, not the cached damaged file | Passed on the SE on 2026-11-10: seek to 120 resolved `kind=transcodedHTTP start=120.00` with `forceTranscode=true`; the first run of this sequence (before the verified-cache fix) had served `kind=cachedFile` |
| A healthy original is not flagged, and the verified cache still serves the successor after drop-and-resume | Passed on the SE on 2026-11-10: 14291 played in full with no `originalFlagged`; `testG1h` passed with the successor from the stream cache |
| The "Playing at reduced quality" notice is raised when the fallback loads | Passed on the SE on 2026-11-10 as app state: both `testG2e1` and `testG2e2` assert the probe's `toast` field equals "Playing at reduced quality". Not read from the pixels |
| A damaged original in the queue behind a good track: the prefetch fetches the transcode and the notice shows when the track starts | Owed: needs a damaged original whose transcode is complete; none is on the server |
| `testG2e3_DamageReachedWhilePausedWaitsForPlay` (11631, pauses at 129 s): stays paused for 20 s with no notice; Play continues to the damage and reloads as the forced transcode with the notice | Passed on the SE on 2026-11-10: paused 13:51:20 to 13:51:42 with no state change, then `retrying from 133.9s`, `forceTranscode=true`, `kind=transcodedHTTP start=133.00`. The decoder had not reached the damage during the pause, so the paused-damage branch itself is still unit-test only |


## iPhone SE — a seek keeps the original (`fix/seek-keeps-original-quality`)

Proven on the iPhone 17 Pro Max simulator and in unit tests; the phone's real link and decoder timing are not.

| Check | Status |
| --- | --- |
| `PhonePlaybackAcceptanceUITests.testG1i_SeekDuringDirectDownloadStaysOriginal` on the SE with `TEST_RUNNER_ENSEMBLE_PHONE_PLAYBACK=1` (optional `TEST_RUNNER_ENSEMBLE_SERIAL_TRACKS=8731`, `TEST_RUNNER_ENSEMBLE_SEEK_TO=90`): a seek made while the original's download is held in flight waits, then plays from the file. The probe shows `src=stream` before and `src=file` after, `fb=` empty; the session log has `seek requires stream restart`, then `sourceDecisionCompleted kind=cachedFile`, never `kind=transcodedHTTP`, and one request for the part in the Plex log | Passed on the SE on 2026-11-10 (develop with the 30 s limit): WAV 8731, seek to 90 s 4.8 s in, `downloadComplete bytes=50699330` then `kind=cachedFile origin=streamCache`, no `transcodedHTTP`. The wait was 18 s (8 s of it the test's injected delay). With the first 10 s limit the same run fell to `transcodedHTTP` |
| Real link, no delay injection: seek to 120 s a few seconds into 14291 at original quality; the track shows buffering until its download finishes and then plays the original from 120 s | Owed |

## iPhone SE — Device MCP pass, 2026-11-11 (build `202611110741.9140`)

Run with Device MCP on the SE; details and evidence in the
[2026-11-11 note](../investigations/2026-11-11-iphone-se-device-mcp-checks.md). These results update the
matching "owed" lines in the sections above. Network checks used Wi-Fi off and on, not Airplane Mode.

| Check | Status |
| --- | --- |
| Relaunch and resume: the Lock Screen follows the resumed and the next track | Passed |
| Literal Lock Screen: playing after Next, paused after Pause, Play resumes | Passed |
| Lock Screen after a halt | Observed: the failed track with no position and a disabled Play button; the app shows one "Playback stopped" toast with Retry and no error text in the mini player |
| Retry on the halt toast, then Pause at once: stays paused | Failed once: playback skipped on to the next track and played. The halted track (11700) always fails, so the skip may be the ordinary skip-on-failure; see `ON_DECK.md` |
| Skip toast "Skipped <title>" and playback continues | Passed |
| End of queue: the app and the Lock Screen show the last item paused | Passed |
| Next under Repeat One from the Lock Screen | Not as written: on the last item with autoplay off the Lock Screen's Next is disabled; with autoplay on it goes to an autoplay track |
| Control Center: Next | Passed, with a caveat: the gesture showed a media page like the Lock Screen's, so it may not have been the Control Center tile |
| Network drop mid-stream (Wi-Fi off about 10 s) on an original-quality FLAC: recovers and keeps playing | Passed: dropped at 7.2 of 18.3 MB, resumed 14.4 s later, no skip |
| Drop the network, press Next: the next track starts at 0:00 when the network returns | Failed: Next while offline halted on the next track with "No internet connection" and did not start when Wi-Fi returned; Retry played it. See `ON_DECK.md` |
| Drop the network, press Pause: stays paused; Play resumes from the same spot | Passed |
| Offline: tapping a track that is not cached plays nothing and toasts | Passed; the toast text is the raw `NSURLErrorDomain error -1004` (see `ON_DECK.md`) |
| A halted track does not restart when Wi-Fi is toggled | Passed on a halt caused by being offline, not repeated on 11700 |
| Plex → Apple Music → Plex → Apple Music → Plex by natural completion, unlocked; each Apple Music track shows its own duration | Passed |
| The same handoffs locked; Lock Screen progress for an Apple Music item | Passed |
| Apple Music pause while buffering, resumed in the app and from the Lock Screen | Partly: stays paused and resumes both ways; the advance at the end of that track was not confirmed |
| Shuffle toggled during an Apple Music track (G7) | Partly: no restart; the queue had one item, so the new order was not checked |
| System Previous on an Apple Music item | Partly: the first press restarts; a second within 3 s restarted again (single-item queue), as on 2026-10-26 |
| Apple Music last item, autoplay off: stays on it, paused | Passed |
| Q2: Apple Music last item, Repeat All, autoplay on: wraps, no station | Passed (wrapped to the first item of the session queue, a Plex track) |
| Apple Music autoplay station (D5) | Passed: a catalog item followed, Up Next listed more, Previous added no duplicate |
| Now Playing secondary actions on an Apple Music track | Partly: AirPlay, Favorite, Add to Playlist, Go to Album, Go to Artist, Share Ensemble Link, Share Link are offered; not compared with a Plex track |
| Step 3c: Apple Music play counts survive a sync | Passed: "Her Majesty" read 0 Plays, was played to its end, a full sync ran, and it then read 6; "Hotel California" read 1. Nothing went down |
| Songs: genre chip filter and clear, tap to play and the indicator moves, last row above the mini player, fast scroll keeps titles and artwork, scroll index, pull to refresh | Passed (13,313 songs); the indicator surviving a refresh was not checked separately |
| Track rows: leading swipe (Play Next, Play Last), trailing swipe (Add to Playlist…, Favorite), long-press menu; album track numbers | Passed on Songs, album and playlist; no multi-disc album found, Search rows not swiped |
| More rows open and go back | Partly: Songs, Albums, Genres, Favorites, Hidden, Downloads; Edit Tabs not opened |
| Feed: hub scrolls sideways; hub order sheet opens and dismisses | Passed (the sheet has Reset… and Done, no Cancel) |
| Settings subpages | Partly: iCloud Sync, SmartMix, Manage Downloads opened; Merging, Connection Security, Track Swipe Actions and source details not run |
| Hidden, Moods, Pins, Item info | Partly: Hidden shows its empty state; album Get Info opens; a track row's "Get Info…" did nothing in three tries (see `ON_DECK.md`); Moods and Pins not found |
| Shared detail screens | Partly: album, playlist (2 sources) and merged artist (The Beatles, 2 sources) open and play; collapsing title, sort and More menus work; genre, Favorites and Mood not run; hero-art flash not judged |
| Browse screens | Partly: Albums sort and filter work; Artists and Playlists were opened under a saved filter (see the note); Genres not run |
| Now Playing: swipe to dismiss, queue page rows, History, shuffle and repeat toggles | Passed; lyrics showed "No Lyrics Available" on the one track tried; Go to Artist not run |
| Queue: a track queued twice shows two rows; Remove from Queue removes that row only | Passed |
| Queue drag reorder | Failed with Device MCP's drag: with a 0.2 s or 0.6 s hold the row moved, but dragging row 2 to row 4 swapped rows 1 and 2 each time; titles stayed on their rows and Next played the new row 1. Unknown whether the tool or the app put it in the wrong place; repeat with a finger. The handle is 24 pt wide and the context button 20x20 pt (see `ON_DECK.md`) |
| StageFlow in landscape: no nav bar, track panel opens, portrait restores the grid | Passed |
| Share: the shared URL is a song.link URL | Failed for an Apple Music track: Share Link… gave a `music.apple.com` URL. A Plex track was not tried |
| App Shortcuts | Failed: with Shortcuts installed (2026-11-11), its Apps list shows Audible, Files and Sonnet but not Ensemble, also after reinstalling and relaunching Ensemble. The build's `Metadata.appintents` declares all five (see `ON_DECK.md`) |
| Focus filter offered in Settings | Passed: Do Not Disturb → Add Filter lists "Ensemble, Playback & Libraries" |
| Step 3a: offline playlist targets list their tracks and state | Not applicable on the SE: Downloads holds three library targets and no playlist target |
