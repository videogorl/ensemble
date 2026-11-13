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

### Skip cleanup of empty disabled libraries, `fix/skip-empty-disabled-library-cleanup`

- Cold launch on the iPhone SE with three disabled Plex libraries: the session log shows three
  `Skipped cleanup for empty removed source` lines and no `Cleaning up data for removed source` lines.
- Disable an enabled library on the phone: its data is still cleaned up (`Cleaning up data for removed source`).
- Disable a library on another device: after iCloud sync, its data is still cleaned up here.

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
  that was playing at the switch. Partly run on the SE on 2026-11-11 with
  the Mac mini as the AirPlay receiver (build `202611111034.1182`): a Next and
  one natural gapless advance on AirPlay, and switches to and from the iPhone
  speaker, kept the position continuous. Still owed: the interruption itself
  (a call or Siri) after the advances.
- Pause and resume after gapless advances (`ae391278`) passed on the SE on
  2026-11-10, also from the system media controls with the app in the
  background ([2026-11-10 SE note](../investigations/2026-11-10-iphone-se-scripted-playback-checks.md)). The AirPlay part passed on the SE on 2026-11-11: two
  switches made while playing (speaker to AirPlay at 21.8 s, back at 53.7 s)
  logged `render=` equal to `observed=`, with `presentation route=airPlay
  latency=2.023s`, and never `Ignoring render clock`. A switch made while
  paused logs `render=nil`, as expected.
- Relaunch and resume (`62e82bac`) passed on the SE on 2026-11-10 by the log
  and scrubber. Still owed: the Lock Screen follows the new track.
- Early segment end (`9ee8cf42`, diagnostic only): keep AirPlay playing a
  stream-cached queue. If a track ends early, read the `Segment ended early`
  line for the playhead, duration, frame counts, and file size. On 2026-11-11
  one natural end and one Next on AirPlay (SE to the Mac mini) logged no
  `Segment ended early`; the row stays open for a longer queue.

AirPlay from the SE to the Mac mini needs the Mac's "Allow AirPlay for" set to
"Anyone on the Same Network" and the Mac's Accept banner clicked within a few
seconds; keep the phone's volume for that route at 0%. Still not run there:
Screen Mirroring (no automated swipe opens Control Center on the SE), the
visible AirPlay fallback (nothing forces it), and a suspected miss: three taps
on Pause in the Lock Screen media controls did nothing while on AirPlay
(possibly the tool's tap; recheck by hand). Report:
`$TMPDIR/ensemble-devmcp-checks/group-airplay.md`.

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
  Run on the SE on 2026-11-11, mirroring to the Mac mini (reached through
  AssistiveTouch, since no automated swipe opens Control Center). Build
  `202611111307.4033` crashed 2 s after mirroring connected, and at launch
  while mirroring (`EnvironmentValues.subscript.getter`: the external view is
  the root of its own scene and did not provide the navigation coordinator or
  the source-action presenter its cards read). Fixed; on build
  `202611111332.2379` it passed: no crash in either order, the mirrored view
  follows the phone's panel (Queue, Lyrics, Info), the scrubber advances, and
  stopping mirroring leaves the app running. The layout is drawn at 1024x768
  and scaled to the display again (it was tiny on a 2560x1440 receiver).
  Still owed: a real TV or Apple TV, and an interruption while mirroring.
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

## iPhone with Apple Music — step 3c, Apple Music library on the writer

Applies to the commits that move Apple Music library sync onto `LibraryWriter`
(`d9150fee` and its follow-up). The iOS Simulator cannot authorize a MusicKit
library (a bare MusicKit probe on the simulator returned `denied` for the
library and REST requests), so the writer and fetcher behaviour is proved only by
`AppleMusicLibraryFetcherTests` with a fake source.

Run on the iPhone SE with scripted tests `testM0` to `testM19` in
`PhonePlaybackAcceptanceUITests`, 2026-11-10. Earlier passes ran on builds
`202611101258.4629` and `202611101534.1456`; the rows below were finished on
`202611101916.0576` (`0576ff63`: step 3c plus the "trust an empty Apple Music
library" change), confirmed with `devicectl` after the run. The SE's Apple
Account is a test account with an Apple Music subscription and Sync Library on;
its cloud library started empty. It now holds 20 songs added for these checks
(left in place for later tests): all 17 songs of "Abbey Road (2019 Mix)" by The
Beatles, "Hotel California" (Eagles), "Take On Me" (a-ha, album "25 (Deluxe
Version)") and "Bohemian Rhapsody" (Queen, album "A Night At The Opera (Deluxe
Edition)"), which is 4 albums and 4 artists. Row 4 needs a library of many
thousands of songs and stays Owed for Felicity's own iPhone.

| Check | Status |
| --- | --- |
| First sync after the update (no library cursor yet) reads the whole library, writes no rows that differ, deletes nothing, and records the cursor; the log has no `Apple Music inventory withheld` line | Passed (`202611101916.0576`): Remove Source cleared the Apple rows and cursor (store 0/0/0, no Apple cursor); re-adding logged `Apple Music library read: API 20 songs (total 20), MusicKit 20, matching 20`, wrote 20 tracks, 4 albums and 4 artists, recorded the cursor, and no `withheld` line appeared in any sync of the day |
| Add a song to the Apple Music library, sync: the song, its album and artist appear; the album count is right | Passed (`202611101534.1456`, `202611101916.0576`): one song took the store from 0/0/0 to 1/1/1 (album trackCount 1); the 20-song library synced to 20 tracks, 4 albums, 4 artists, with Abbey Road's 17 songs on one album |
| Remove that song, sync: the song leaves, and its album and artist leave when it was their last song | Passed (`202611101916.0576`), each in the first sync: deleting "Her Majesty" from Abbey Road logged `API 19 songs … Removed from appleMusic:device:system:library: 0 artists, 0 albums, 1 tracks` (store 19/4/4); deleting Queen's only song logged `API 18 songs … Removed … 1 artists, 1 albums, 1 tracks` (store 18/3/3). A second sync changed nothing. Both songs were added back (20/4/4). The empty-library case is covered by the unit table test, not the phone, to avoid deleting the 20 songs |
| A library of many thousands of songs is not mistaken for incomplete: no `inventory withheld` line, which would mean the REST total or the MusicKit witness check disagrees on a healthy library | Owed. The largest library on the SE was 20 songs; REST total and MusicKit agreed every time, no `withheld` line in about 40 syncs |
| Play counts and last played dates survive a sync that cannot read MusicKit history for a song (stored values kept) | Partly passed on 2026-11-11: "Her Majesty" read 6 plays and "Hotel California" 1 after a full sync, so counts are stored and a sync does not lower them. The cannot-read-history branch itself is unit-tested only. Earlier note: "Take On Me" played in Music for about 35 s and paused; MusicKit never reported a play for it (Ensemble stored play count 0 and no last played date after more than 25 syncs over about 80 minutes, with the app relaunched in between). A 35 s play apparently does not count, so there was no history to keep or lose. Needs a song played to its end, or Felicity's own iPhone |
| Toggle Apple Music off in Settings: its rows and its library cursor go, a Plex source's rows and cursor stay; turn it back on and the first sync rebuilds | Passed (`202611101916.0576`) on the 20-song library: Remove Source logged `Cleaning up data for removed source` and `Successfully cleaned up source`; Apple 20/4/4 went to 0/0/0, the Apple cursor and source row went; Plex stayed at 13732 tracks and its 2 cursors (the third was cleared at launch by design while its server was unreachable, see `ON_DECK.md`); re-adding rebuilt 20/4/4 |
| Revoke Media & Apple Music access in iOS Settings mid-use, then sync: the sync fails and the library is unchanged | Passed (`202611101916.0576`) on the 20-song library, which matters now that an empty read deletes: with the switch off the sync logged `Sync failed for appleMusic:device:system:library: … AppleMusicLibraryError error 0` and no `library read` line; the store stayed 20/4/4; permission and a normal sync were restored (`API 20 songs`) |

The iPad and watch checklist sections start with steps 5 and 6.

## iPhone — step 3d, playlists on the writer (Plex and Apple Music)

Applies to the commits that move playlist list and body sync onto `LibraryWriter`
(branch `refactor/playlists-on-library-writer`). The simulator proved the writer rules
(on-disk store tests, including overlapping passes, stale reads and cancellation) and
the Plex connector against a fake server. On 2026-11-11 the Plex rows below were run on the iPhone SE
with Device MCP on build `202611111150.4978` (the step 3d branch before its merge; the only later commit
adds a log line), against the live PMS on the disposable playlist "ZZ Test 3d" (deleted afterwards, 41
playlists before and after). Apple Music playlists and everything a finger is needed for are still owed.

How to read the log for the repeated-read checks (`EnsembleLogger`, in the session log):

- `🎵 Playlists <scope>: wrote N, removed M` (debug) appears only when a pass changed something. On a pass
  where nothing changed on the server, it must not appear. A playlist whose body is read and rewritten every
  pass makes it appear on every pass with N at least 1.
- `Playlists <scope>: N body reads unresolved, to retry next pass` (info) means the pass was partial. It
  must go away on the next pass; the same N on consecutive passes is a body that never proves complete.
- Apple Music: `Apple Music REST playlist body unavailable; trying MusicKit id=<id>` (info) and
  `🎵 Apple Music playlist body failed id=<id>` (error). The same id on every pass is a body that never
  becomes provable (see the `meta.total` and count rows).

| Check | Status |
| --- | --- |
| An unchanged Plex playlist pass makes no `/playlists/{id}/items` request (issue #98: a playlist whose stored rows are below the server count is no longer refetched) | Partly: four launches on 2026-11-11 (41 playlists) logged no `wrote` line and no `unresolved` line on idle passes, so no body was rewritten; the server request count itself was not read. Owed: a request count against the issue #98 playlist |
| No Plex playlist lacks `updatedAt` (such a playlist would be read again every pass: the `wrote N` line above on an idle server) | Passed on the SE, 41 playlists: no `wrote` line on idle passes |
| Plex, on a disposable playlist (needs Felicity's approval): create, add, rename, reorder and delete. The list matches the server after each; after the rename, Date Modified sort moves it up once the refresh lands | Create, add (3 songs), rename, remove (Edit Playlist, Save) and delete passed on the SE: each showed at once, held after a refresh and a relaunch, and logged `wrote 1, removed 0` per pass; delete left 41 playlists. Reorder not run: Device MCP's drag does not move rows in Edit Playlist (a finger is needed). Date Modified sort after a rename not checked |
| Plex: rename while offline, then reconnect. The new title shows throughout, uploads once, and the server's header applies afterwards | Passed on the SE (Wi-Fi off): the title changed at once, `Enqueued playlistRename`, replayed once about 57 s after Wi-Fi returned (the first drain timed out), and the title held through a refresh and a relaunch |
| A playlist edited from another Plex client reaches the phone through the WebSocket and the body changes | Owed |
| A playlist with repeated tracks, and one emptied on the server, keep their order and count | Owed |
| Apple Music: `/v1/me/library/playlists/{id}/tracks` reports `meta.total`. Without it the REST body counts only when MusicKit's song count agrees | Owed |
| Apple Music: MusicKit's song count for a playlist equals REST's. If they differ routinely, the body is never accepted and the playlist's id repeats in the Apple Music log lines above on every pass | Owed |
| Apple Music: the playlist list and bodies match the Music app; a playlist deleted in Music disappears; no `Apple Music playlist inventory withheld` line on a healthy library | Owed |
| Delete of a scope's last playlist removes its row even though the list that follows is empty. Not runnable on a real library without deleting every playlist; covered by `testDeletingTheLastPlaylistRemovesItsRow` and `testDeletingTheLastPlaylistRemovesItAndAnOlderReadCannotRestoreIt` only. Run it on a disposable Plex server or a fresh test account if one exists | Owed |
| `.partial` keeps background recovery outstanding: make one playlist body fail (disposable server, or a throttled network for one request), run a background refresh, and see the handoff stay pending (`Refresh pending sources=` in the log, `hasPendingBackgroundRefresh` true) and the next foreground recovery clear it once the body reads. No test drives this path (it writes the real handoff file) | Owed |
| Offline: a queued playlist add, remove or delete is not overwritten or deleted by a sync before it uploads; last-playlist offline targets keep their tracks | Partly: a queued add survived a pull-to-refresh offline and replayed 3 s after reconnect (`Enqueued playlistAdd`, `Replayed playlistAdd`, one copy of the song after a relaunch). A queued remove and delete, and offline targets, not run. A queued add shows no change or toast until it uploads (`ON_DECK.md`) |

## iPhone SE 2 and iPhone 16 Pro — step 3 close-out (3e)

What step 3 as a whole still owes the phones; the sub-step sections above hold the per-feature rows, which are
not repeated here. See the
[close-out note](../investigations/2026-11-11-step-3-close-out.md).

| Check | Status |
| --- | --- |
| The iPhone SE 2, which froze on 2026-08-08 while opening a playlist on a build before the duplicate-membership fix, opens a merged playlist (two sources) and a large single-source playlist on the current build without freezing; the first launch's `Playlist membership backfill:` line says how many duplicates it removed | Owed. Needs the SE 2 and its session log |
| Felicity's iPhone 16 Pro, with her own store: the update migrates it (model 12) and launches, then one pass of every step 3 row above for the sources she has. This is the physical acceptance that step 3 still lacks; until it is done step 3 is closed but not verified | Owed |
| The Apple Music row of `MusicSourceCapabilityAgreementTests` (flags against `AppleMusicConnector` conformance) runs and passes. The package test command runs on the Mac, where that row is compiled out; run it on an iOS destination (the `EnsembleCore` package scheme has no test action) | Owed; not a phone check, listed so it is not lost |

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
| App Shortcuts | Passed on the SE on 2026-11-11 after the shortcuts began suggesting recent items (build `202611110900`-series from `develop`): Shortcuts > Ensemble lists tiles for recently played tracks, albums and artists, and the "Hotel California" tile played that track; a playlist tile played its playlist in the trial build. Before the change Ensemble was not listed at all. Owed: a misheard voice request does not play a suggested item |
| Queue row actions button: a near miss opens the menu instead of playing the row | Passed on the SE on 2026-11-11 (trial build `202611110900.4703`): taps 8 pt left of the glyph and in the gap before the handle near the row's top edge both opened the menu; before the fix, taps 5 pt outside played the row 4 of 4 times |
| Focus filter offered in Settings | Passed: Do Not Disturb → Add Filter lists "Ensemble, Playback & Libraries" |
| Step 3a: offline playlist targets list their tracks and state | Not applicable on the SE: Downloads holds three library targets and no playlist target |

## iPhone SE — forced and system background refresh, 2026-11-11 (build `202611111034.1182`)

Run from the Mac with lldb attached (`_simulateLaunchForTaskWithIdentifier:` for
`com.videogorl.ensemble.refresh`). Report: `$TMPDIR/ensemble-devmcp-checks/group-bgrefresh.md`.

| Check | Result |
| --- | --- |
| A forced refresh runs to completion | Passed: triggered 11:22:10, next refresh scheduled at the start, `handoff saved sources=4`, library and playlist phases for each source, `handoff cleared`, `returned succeeded=true pendingSources=0 needsRecovery=false errors=0` after 18.8 s |
| iOS delivers a refresh on its own | Passed: runs at 11:47:04 and 12:18:14, about 15 to 17 minutes after each request was scheduled; the 12:18 run completed in 12 s |
| A failed refresh is recovered on the next launch | Passed: the 11:47:04 run returned `succeeded=false pendingSources=4 needsRecovery=true errors=1` and left the handoff; a cold launch at 11:53:30 logged `Resuming background refresh handoff on launch` and `handoff cleared` 14 s later |
| A refresh cut off mid-sync by its time budget | Passed on the SE, build `202611111416.1954`, through `ensemble://debug/background-refresh?budget=1` (foreground): one library phase completed, then cancellation, `finished syncComplete=false cancelled=true`, `returned succeeded=false pendingSources=4 needsRecovery=true`, handoff kept, no crash. With `budget=3` the sync finished first (2.6 s) and only the trailing Siri step was cancelled (`succeeded=false needsRecovery=false`). Not run: an expiry iOS itself sends to a refresh running in the background; the debug route does not run while the app is suspended. To run: wait for a system-delivered refresh with a debugger attached and send the expiry then |
| An interrupted refresh resumes when the app is brought forward without a relaunch | Passed on the SE, same build: after the cut-off run the app stayed in front 28 s with no resume; after Home and reopening, `Resuming background refresh handoff in foreground` came 0.11 s after the scene went active and `handoff cleared` 3.0 s after. A final normal run returned `succeeded=true needsRecovery=false` |


### iPhone 16 Pro, overnight 2026-11-11 to 2026-11-12 (build `202611111806.5525`, phone untouched)

Read from the session logs (`$TMPDIR/ensemble-16pro/bg-logs`, temporary). iOS started eight refreshes on its own; each scheduled the next one at its start.

| Run | Result |
| --- | --- |
| 19:16:03 | Completed in 17 s: `succeeded=true pendingSources=0`, handoff cleared |
| 20:20:58 (cold background launch) | Completed in 21 s: `succeeded=true pendingSources=0` |
| 21:05:55 | Completed in 16 s: `succeeded=true pendingSources=0` |
| 21:21:09 | Incomplete after 19 s: `step=sync BackgroundRefreshIncompleteError`, `pendingSources=1 needsRecovery=true`; handoff kept |
| 21:36:21 | Suspended by iOS about 26 s in, after library and playlist phases had logged; no `finished` line |
| 04:51:02 | The suspended run resumed and was cancelled at once (four `CancellationError` steps, `cancelled=true`), `pendingSources=3 needsRecovery=true`; the new request was coalesced into it |
| 05:21:47 | Incomplete after 14 s: one playlist phase `followUp=false`, `pendingSources=1 needsRecovery=true` |
| 05:37:55 | Completed in 12 s: `succeeded=true pendingSources=0`, handoff cleared. This recovered the interrupted runs without the app being opened |

Not explained: which source left `pendingSources=1` at 21:21 and 05:21 (the log names no source). Spotlight refresh was skipped in every background run (`foreground work is not available`), as designed.

Owed again on the step 3d build, where a partial playlist pass must keep recovery outstanding.

## App Intents phases 1 to 3 and playlist merging at every entrance, 2026-11-11

Merged as `71f8dae9`. Reports (temporary files): `$TMPDIR/ensemble-devmcp-checks/group-intents-4.md` to
`group-intents-8.md` (iPhone SE), `$TMPDIR/ensemble-16pro/report-3.md` to `report-5.md` (iPhone 16 Pro, typed
Siri). Last builds checked: SE `202611111806.5525` (the merged code), 16 Pro `202611111729.7573` (one fix round
earlier).

| Check | Result |
| --- | --- |
| Shortcuts pickers follow the merge setting; a saved shortcut plays the merged set (on) or the preferred copy (off) | Passed on the SE (27 / 25 / 2 for "focus") and the 16 Pro (28 merged, 25 for Minibar) |
| Typed Siri: a playlist by name plays the merged set with no list (on); a labelled "Which one?" (off) | Passed on the 16 Pro |
| Spotlight: one result per displayed playlist, opening the merged playlist; follows merge toggles, hide and unhide, also across backgrounding | Passed on the SE, build `202611111806.5525`; on the 16 Pro one result and a merged open on `202611111729.7573` |
| Stale per-source Spotlight items removed after updating | Passed on the 16 Pro (`deleted 25`, `deleted 26`, `indexed 17`) |
| A Spotlight item lost after an interrupted refresh comes back (one-time re-index) | Not shown: the SE already had the item when the fixed build was first checked; `indexed 42` ran. To run: reproduce the loss on build `202611111729.7573`, then install the fix |
| A hidden copy is never opened or played; all copies hidden gives not-found | Passed on the SE |
| Add Current Song to a merged playlist lands in the copy on the song's own server | Passed on the SE by Shortcut. Not run by voice |
| Voice Add to Playlist: server-labelled destinations, unique names, no write on an ambiguous name | Not run (tests only). To run: typed Siri on the 16 Pro with a disposable same-named playlist on two servers and merging off; needs approval to add a song to a test playlist on that phone |
| Matcher: "Kim & Jessie" not found; short titles still found | Passed on the 16 Pro. "Play Dark Side" arrives from Siri as a track request and is not found (not an album fallback) |
| Voice Play and Add right after an update, before the app has run | Play passed on the 16 Pro (fell back by name, 28 tracks). Add not run |
| Play Mood cancel; cancel during a cold intent launch | Weak pass on the SE: no crash or hang, but the tool cannot interrupt real work |
| Sidebar pins, Search pins and the Mac Dock menu follow the playlist-screen rule | Not run. To run: on the Mac, pin one copy of a merged playlist; open it from the sidebar and Search, press Play, and open the Dock menu after hiding it and after toggling Merging |
| Apple Music playlists no longer rewritten each sync (`1ef74494`) | Failed on the 16 Pro, 2026-11-12: both playlists (`p.1YeW3rpCkzaPXR`, `p.V7VYlM7CoLPe16`) were still written with `differs: compositePath` in every sync, 5 of 5 on 2026-11-11 evening (build `202611111806.5525`) and 7 of 7 syncing sessions on 2026-11-12. Next: log hashes of the stored and incoming path (see `ON_DECK.md`) |
| Less background CPU while playing locked or with no visualizer on screen (`33be6521`) | Not run on a phone (tests and builds only). To run: on the 16 Pro, the same 7-minute locked-playback Performance Trace as 2026-11-11 with the visualizer on and Now Playing closed; expect no `analyzeFile` bursts and fewer SwiftUI samples than 34 of 96. Also open Now Playing after a gapless advance and confirm the visualizer animates for the new track |
| Voice Add never writes to a similar or smart playlist; deferred server labels resolve to one playlist; extension trail appears in the session log (`SIRI_EXT_TRAIL`) | Not run (tests only). To run: on the SE (no Siri AI), with a smart and a regular "Road Trip Mix" style pair and a disposable "ZZ Test" playlist, ask Siri to add the current song to each; expect "not editable" for the smart one, one write for the test playlist, and `SIRI_EXT_TRAIL` plus `SIRI_APP: add-to-playlist` lines in the session log |

## Background launch work

Run on the iPhone 16 Pro (the iPhone SE as a fallback) with a Debug build. Prove the installed build first. Kill the
app before each check, then pull `Application Support/Ensemble/Logs` and read the newest session. UIKit's
`applicationState` is `.background` inside `didFinishLaunching` of a scene-based app, so a plain launch is not
distinguishable there. Every launch without a user-action option logs a session header `launch: no launch request yet ...`
and `LAUNCH_WORK: kind=no launch request yet ... foregroundLaunchWork=deferred until the first foreground activation`.
When the app is opened (a cold icon tap, or the first open after a background launch) the first `.active` logs
`LAUNCH_WORK: kind=foreground scene first foreground activation`, then `LAUNCH_WORK: starting foreground launch work`,
`LAUNCH_WORK: Siri/Spotlight refresh starting` and `Sync startup: iCloud/KVS bootstrap running` (or its `skipped`
line, with the retry at the next `.active`). A background intent logs none of these until the app is opened.
`.userActivity`/`.url` launches log `foregroundLaunchWork=started` at `didFinishLaunching`.

| Check | Expect in the log | Result |
| --- | --- | --- |
| Cold Shortcuts toggle (shuffle or repeat) from a killed app | `launch: no launch request yet`, `foregroundLaunchWork=deferred`. No `Starting network monitor + early health checks`, `Starting startup sync`, `WebSocket ... Connecting`, `siriIndexRebuild`, `Spotlight indexed`, `deferred healing started` | Not run |
| Cold Play/Pause, then Next | The same absences, `Server connectivity ready` from `SIRI_APP: [origin=intent]` (Play/Pause and Next wait for health, `health=awaited`), playback starts, queue restored | Not run |
| Cold play by name (Siri or Shortcut) | `SIRI_APP: [origin=...] Server connectivity ready (health=deferred)`, playback starts, then `Playback resolved — starting server health checks` | Not run |
| Cold add to playlist | `health=awaited`: the all-servers health result comes before the add (unchanged); the add lands or queues offline | Not run |
| Each of the above, then open the app within a minute | One `LAUNCH_WORK: starting foreground launch work` line at the first `.active`, one `Starting startup sync...`, one WebSocket start per server, Home and library show loading then fill, no empty or error flash | Not run |
| Locked phone: start playback by intent, then turn Wi-Fi off and on | `stateChanged ... transition=disconnect`, then `reconnect`, then `Health refresh complete`; playback recovers or resolves the next track. If not, see the `ON_DECK.md` entry on monitoring | Not run |
| Overnight background refresh | `Background refresh triggered` and `Background refresh phase=` lines, `foregroundLaunchWork=deferred`, no `starting foreground launch work` until the app is opened | Not run |
| Foreground cold launch and a launch that backgrounds at once | Launch log unchanged in task order, `first foreground activation` then one `starting foreground launch work` at the first `.active`, session header not `background`, one start | Not run |

## Merging toggle and merged playlist loading, 2026-11-11

| Check | Result |
| --- | --- |
| First Merging toggle after launch re-groups the Playlists list and sidebar (`c39429ce`); merged playlist shows "Loading tracks…" not "No tracks" (`17e0b6f2`) | Toggle passed on the Mac, build `202611112308.3942`, two fresh launches. Not run on a phone or iPad (shared view model). "No tracks" flash not observable by the Mac checker (first read too late). To run: on the iPad or phone, launch, toggle Merging > Playlists once and check Playlists re-groups; open a merged playlist on a slow connection and watch the footer |

## Mac — App Intents phase 5 (`feature/app-intents-mac`)

Built and unit-tested only; nothing here ran in Shortcuts or Spotlight. Why: the built Mac app was not registered with
Shortcuts (its ToolKit database listed no Ensemble actions for a DerivedData build, only the installed copies), and
`shortcuts run` only runs saved shortcuts, which an agent must not create. Launch the build under test with
`open -a <path to the built Ensemble.app>`, never a plain `open ensemble://…` or the display name (that starts the
installed `/Applications/Ensemble.app`), then check the PID's executable path (`lsappinfo`, or `ps -o comm`) and build version.

| Check | Result |
| --- | --- |
| Shortcuts on the Mac lists Ensemble's actions (30) and App Shortcuts. If the build does not appear, copy it to `~/Applications` and open it once | Owed |
| Build one shortcut with Get Current Song, Play/Pause and Next, quit Ensemble, run it: the app starts without coming forward, the saved queue restores (Get Current Song names the saved song), Play/Pause and Next act. The owed headless macOS Next/Play-Pause check. Look for a session log whose first line names a non-foreground launch | Owed |
| With Ensemble running and a window open, the same shortcut leaves focus where it was | Owed |
| Play Track, Album, Artist and Playlist pickers: suggestions appear; typing a name outside the index (a never-played song) finds it | Owed |
| Open Media and Get Ensemble Link bring the window forward or return a link | Owed |
| Spotlight on macOS 26 and 27: a played song, album, artist and playlist appear and open in Ensemble; App Shortcut phrases and actions appear under Ensemble | Owed |
| iPhone SE: typing a never-played song name into a Play Track picker finds it (the same fallback) | Owed |


## App Intents: visibility, Focus and the picker fallback (`feature/app-intents-mac`)

Unit-tested and built only; none of this ran on a phone or in Shortcuts or Siri.

| Check | Result |
| --- | --- |
| A Focus that hides library A, then a cold headless launch (force-quit Ensemble, run a shortcut or ask Siri): Play Song/Album/Artist pickers and playback never show or play library A; if the Focus lookup is slow the intent fails with "couldn't confirm which libraries are visible" and a retry works | Owed |
| The Play Track picker finds a song outside the Siri index by typing its name (including "rocknroll" for "Rock'n'Roll", and a name with "&" typed as "and"); items from a library hidden by the active profile never appear, and with Merging off the same song on two servers shows as two rows labelled by server | Owed |
| Voice Play for a song, album or artist that exists in a hidden library and, with the same title, artist and album, in a visible one: Siri plays the visible copy; with no visible copy it says it cannot find it. After an app update, before the app has run once, Voice Play defers to the app by name | Owed |


## Siri AI audio schemas: withdrawn (`fix/withdraw-siri-ai-intents`)

The schema intents were built, run on the iPhone 16 Pro across six builds and withdrawn (investigation note, "Withdrawn
2026-11-12"). Results: play via SiriKit was right 4 of 5 without `playAudio`; schema play 0 to 7 of 9 and add 0 to 2 of
2 depending on the build; Siri created a same-named playlist in Apple Music on the last build. Remaining owed checks on
the final build (iPhone 16 Pro, session log open; "ZZ Test Siri AI" is a disposable playlist):

| Check | Result |
| --- | --- |
| Play phrases through the SiriKit extension (`SIRI_APP` lines, no `SIRI_AI:`): "Play my focus playlist", "Play the playlist focus", "Play focus", "Play Lord Huron", "Play The Man Who Lives Forever" in Ensemble; the merged "focus" playlist plays once | Owed |
| Shortcuts action Add Current Song to Playlist, run twice on one song: the first writes (`SIRI_SHORTCUT: add ... outcome=added sent=1`), the second says the song is already in the playlist (`outcome=already in playlist`), no write | Owed |
| Remove the song from "ZZ Test Siri AI" in another Plex client without syncing Ensemble, then run the Shortcut: it must write, not say "already in" | Owed |
| Add to Playlist (Shortcut) with an album where one song is already in the playlist: only the missing songs are sent (`sent=N`) | Owed |
| Apple Music playlist: adding an explicit version of a song already present in its clean version still writes | Owed |

## Siri play after withdrawing the Siri AI intents (16 Pro, 2026-11-12, build `202611121011.2049`)

Typed Siri, each ending "in Ensemble": playlist (cold and warm), album, artist and song all played through
`INPlayMediaIntent`; no `SIRI_AI` line in the build's logs. Siri's reply text was not captured, and the playlist check
did not confirm the song was the playlist's first. The artist request needed a pick between two identical rows (see
`ON_DECK.md`). Still owed: the Shortcut duplicate-add rows listed above.

## Shortcut cold play without the health wait (`fix/siri-play-health-wait`)

Only the plain play entrances (Siri play, and Shortcuts play of a track, album, artist or playlist) skip the health
wait (`health=deferred`); the explicit startup pass starts after the play call's source resolution or launch returns,
which can precede `.playing`. Every other intent keeps `health=awaited`. A probe superseded by a configuration update
is retried once (`Connection refresh superseded by a configuration update — retrying once` at debug level).

| Check | Expect | Result |
| --- | --- | --- |
| Play Playlist Shortcut from a killed app, first track downloaded | Process start to `playing` about 0.5 s or less excluding system time (was 2.3–2.6 s); `Server connectivity ready (health=deferred)`, then `Playback resolved — starting server health checks` after the play call returns | Not run |
| Same, first track an uncached Plex stream | Plays; that track's server is probed before the explicit health pass starts | Not run |
| Same with Wi-Fi off | Downloaded song plays at once; a streaming-only item fails promptly with the existing message; `Offline — skipping server health checks` | Not run |
| Plex server unreachable, internet up | A downloaded or cached first track plays without waiting; a streaming-only item fails on its own server probe, not after an all-servers pass | Not run |
| Library hidden by the active Focus | Still refused (`Focus filter not restored` or the item not found), no playback | Passed on the 16 Pro, 2026-11-13 (see the section of that date) |
| Last used on Wi-Fi, then launched a streaming Shortcut on cellular (seeded `.online(.wifi)`, live cellular: a forced interface-switch refresh) | The track plays; the log shows the retry line if a refresh superseded the probe (a first-byte DNS failure also gets one refresh-and-reassemble retry); no `serverUnavailable` | Not run |
| Cold Add to Ensemble Playlist, and a radio or station start, from a Shortcut | `health=awaited` (`No connected servers — running health checks` when none is connected) before the request, as before | Not run |
| Cold Shortcut play, then open the app within a minute | One startup health pass in the log, not two back to back | Not run |

## Disabled-library cleanup skip (iPhone SE, 2026-11-12, build `202611121306.9716`)

One cold launch: three `Skipped cleanup for empty removed source` lines and no `Cleaning up data for removed source`
line, so the skip works. The time saved is small: the three requests were logged at 13:08:19.10 and the last skip at
13:08:20.63, about 1.5 s of wall time against 1.7–1.9 s before, while Siri index rebuilds and offline reconciliation
ran alongside. Whether the probes are slow themselves or only waiting their turn is not known from these lines. Still
owed: disabling an enabled library on the phone still cleans its data; disabling one on another device still cleans it
here after iCloud sync.

## Shortcut cold play without the health wait: SE results (2026-11-12, build `202611121337.9825`)

Disposable Shortcuts run from the editor, each from a killed app; times are session start to `playing`.

| Check | Result |
| --- | --- |
| Play Playlist, first track downloaded or cached, Wi-Fi on (3 runs) | `health=deferred`; 0.49–1.13 s (was 2.3–2.6 s) |
| Play Album, uncached Plex stream (2 runs) | `health=deferred`, `transcodedHTTP`; 1.67 s and 2.00 s; played |
| Play Playlist, Wi-Fi off, downloaded track | Played at 1.32 s; `Offline — skipping server health checks`; about 1.3 s of readiness is the wait for a live network state |
| Play Album, Wi-Fi off, nothing stored | "No downloaded tracks available offline" at about 1.4 s; no hang |
| Play Album right after Wi-Fi came back (offline → online, forced `network_reconnect` refresh) | Played at 2.98 s, `transcodedHTTP` |
| Start Track Radio | `health=awaited`, 1.9 s in health checks, as before |
| Cold play, then open the app | One health pass; the foreground launch logged both "Skipping … health checks" lines |
| Retry line | `Connection refresh superseded by a configuration update — retrying once` appeared once (the Wi-Fi-off playlist run) and playback succeeded |

Not run: Focus-hidden library (no Focus with an Ensemble filter exists on the SE; create one to unblock); last used on
Wi-Fi then launched on cellular (the SE has no SIM; needs the 16 Pro); a third uncached stream run. Logs:
`/tmp/ensemble-se-logs.XcmAFq`.

## iPhone 16 Pro — Apple Music playlist header churn diagnostic (`diag/apple-music-header-churn`)

| Check | Status |
| --- | --- |
| Install the diagnostic build, run two Apple Music playlist syncs, and read the session log's `compositePath stored … incoming … valuesDiffer=…` lines for `p.1YeW3rpCkzaPXR` and `p.V7VYlM7CoLPe16` (`ON_DECK.md`, "Fix did not hold"). Record scheme/host/path shape, query names, and which part differs between the two syncs; then choose the fix | Owed |
| Done 2026-11-12 (build `202611121404.6631`): the two playlists' artwork URLs are pre-signed (`X-Amz-Date`, `X-Amz-Signature` differ per read). Fix built, see below | Diagnosed |

## iPhone 16 Pro — Apple Music signed artwork header (`fix/apple-music-signed-artwork-header`)

| Check | Status |
| --- | --- |
| Install the build, run two Apple Music playlist syncs. For `p.1YeW3rpCkzaPXR` and `p.V7VYlM7CoLPe16`: the log shows `differs: compositePath(signature)` only (after the first sync, which may also show it once) and the summary line `Playlists …: wrote 0, removed 0, refreshed 2 signed artwork paths`, no `artworkInvalidated` or "marked stale" lines and no artwork re-download lines for them, and their artwork still displays in the Playlists list and detail, also after a force-quit and relaunch | Owed |
| A playlist whose cover really changes in Apple Music still logs `differs: compositePath`, is invalidated, and shows the new cover | Owed |

## Signed Apple Music artwork refresh (16 Pro, 2026-11-12, build `202611121446.6234`)

Four cold launches, five playlist syncs: every summary read `wrote 0, removed 0, refreshed 2 signed artwork paths`,
both playlists logged `differs: compositePath(signature)`, and no invalidation, re-download or catalog-change line
followed (one `Spotlight indexed 1 changed media items` 2.3 s after the first sync on the new build, the expected
one-time index rewrite). Every Apple Music playlist row showed artwork; a playlist detail header showed its cover.
Still owed: a real cover change on one of these playlists is picked up (add or remove a song in Music, then sync).
Logs: `/var/folders/10/2969pd1j52q59dfxzzd_v3f80000gn/T/tmp.BBiylz1QPW`.

## Duplicate-add Shortcut and cellular Shortcut play (16 Pro, 2026-11-12, build `202611121446.6234`)

Add to Playlist in Ensemble, target a disposable Plex playlist (deleted afterwards), all `health=awaited`:

| Run | Dialog | Playlist count | Log |
| --- | --- | --- | --- |
| One song | "Added to ZZ Test Dup." | 1 | `outcome=accepted tracks=1` |
| Same song again | "Division is already in ZZ Test Dup." | 1 | `outcome=already in playlist tracks=1` |
| Its 16-song album | "Added to ZZ Test Dup." | 16 | `outcome=accepted tracks=15` |
| Same album again | "Those songs are already in ZZ Test Dup." | 16 | `outcome=already in playlist tracks=16` |

Cold Shortcut play with Wi-Fi off after last use on Wi-Fi (two runs): `health=deferred`, playing 0.70–0.73 s after session
start, but both first tracks came from the stream cache (`kind=cachedFile`), so no stream was requested over cellular.
The monitor reported `interfaceSwitch(Wi-Fi->Cellular)` about 0.5 s after playing began; its forced refresh superseded
probes in flight, `Connection refresh superseded by a configuration update — retrying once` logged, and the retried
probes selected a remote endpoint with every server Connected in 0.35 s. Still owed: the same run with a first track
that has never been played or prefetched on the phone (an uncached stream over cellular); removing a song in another
Plex client and re-running the add without a sync; the Apple Music explicit/clean case.
Logs: `/var/folders/10/2969pd1j52q59dfxzzd_v3f80000gn/T/tmp.XJUNfILpoJ`, `/var/folders/10/2969pd1j52q59dfxzzd_v3f80000gn/T/tmp.a4QMZh6apZ`.

## iPhone SE — launch SQLite temp writes (`fix/launch-sqlite-temp-writes`)

| Check | Owed |
| --- | --- |
| Instruments File Activity on a cold launch, app process only: `tmp/etilqs_*` bytes in the first 30 s | Before (build `202611121446.6234`): 22.7 MB (`fetchTrackReferences` 13.2, `fetchArtists` 6.2, `fetchAlbums` 3.3). After: expect the `fetchTrackReferences`, `fetchArtists` and `fetchAlbums` files gone at launch, after a sync and after a background refresh (the Siri index rebuild now reads narrow rows); other sorted fetches (detail resolvers, search, Siri voice lookups) can still spill by design; record the number, the total launch writes (before 25–40 MB) and `Cache.db-wal` / `fsCachedData` / `SiriMediaIndexStore.saveToDisk` for what remains |
| Library, artist and album lists keep their order and the downloads screen lists the same tracks | Compare against the SE before the change; peak memory at launch has not risen (Instruments Allocations, first 30 s) |

## Disk writes by scenario (iPhone SE, 2026-11-12 and 13, build `202611121446.6234`, File Activity, app process)

| Event | App bytes written | Mostly |
| --- | --- | --- |
| Cold foreground launch (3 runs) | 27–30 MB, all within about 26 s | `etilqs_*` 23.95 MB in 16 files: `fetchTrackReferences` 14.43, `fetchArtists` 6.19, `fetchAlbums` 3.34 |
| Force Full Sync | 19.7 MB in about 7 s | `etilqs_*` 16.7 MB (artists 9.3, albums 5.0, references 2.4); Core Data 0.11 MB |
| Background refresh through the debug route (foreground process) | 16.0 MB in about 4 s | `etilqs_*` 14.3 MB |
| Download 9-track album | 4 tracks downloaded, 1.07 bytes written per byte kept; 5 promoted from the stream cache with no write; Core Data about 48 kB per track | audio |
| Remove that album's downloads | 2.74 MB | `etilqs_*` 2.4 MB |
| Streamed track | written once (3–7 MB transcodes) | stream cache |
| Idle or playing steady state | 0.03–0.7 MB/min | `Cache.db-wal`, frequency timeline saves |

One process logged 21 background refreshes in about 13 h. At 13–16 MB each (inferred from the debug-route run, not measured
for a refresh iOS delivered) that is roughly 270–340 MB a day before any launch. Not measured: an iOS-delivered refresh, a
cold background launch, lossless originals, a large download run. Evidence: `/tmp/se-disk/` and `/tmp/se-disk/round2/`.

## Disk writes after the launch-read fix (iPhone SE, 2026-11-13, build `202611130658.1672`)

| Event | Before | After | `etilqs_*` after |
| --- | --- | --- | --- |
| Cold launch, 60 s (3 runs) | 27–30 MB | 2.9–4.4 MB | 0 |
| Force Full Sync (after t=40 s) | 19.7 MB | 2.65 MB | 0 |
| Debug background refresh (after t=44 s) | 16.0 MB | 0.33 MB | 0 |

Largest remaining launch writers: `Cache.db*` 1.3–2.3 MB and `fsCachedData` 1.3–1.4 MB. Artists and Albums lists order
unchanged, a download target lists its tracks, `siriIndexRebuild` counts identical to the earlier build
(`artists=674 albums=1259 tracks=1000 playlists=51`), reconciliation track counts identical, no error lines. The measured
build predates `d2a6508f` (hidden snapshot read after each fetch), which does not change what is written. Still owed: a
refresh iOS delivers on its own and a cold background launch (not capturable with xctrace). Evidence: `/tmp/se-disk/round3/`.

## Cellular uncached Shortcut stream and Focus-hidden library (16 Pro, 2026-11-13, build `202611130729.7322`)

| Check | Result |
|---|---|
| Last used on Wi-Fi, app killed, Wi-Fi off (5G), Shortcut "Play Album" for an album never played on the phone | Passed: "Playing DISCOPUP in Ensemble.", `health=deferred`, `kind=directHTTP`, first byte 1244 ms, session start to playing 1.56 s. `interfaceSwitch(Wi-Fi->Cellular)` forced a refresh; `Connection refresh superseded … retrying once` twice; no `cannotFindHost` or `serverUnavailable` |
| Album only in a library hidden by an active Focus ("Libraries to Show" without it), cold Shortcut | Passed: nothing played and the intent never ran. Shortcuts showed its "Album" picker (the saved album no longer resolves) instead of an error dialog; no `Focus filter` log line. In the app, search found nothing and the Profile menu showed "Filtered by Focus" |
| Same Shortcut with the Focus off, before and after | Passed: played both times (`directHTTP`, then `cachedFile`) |

An album that also exists in a visible library plays under the Focus (the merged item resolves to the visible copy). The
Focus filter's five library rows are listed without their server names (Music ×3). Logs:
`$TMPDIR/tmp.uYXB8da3JG` (Focus), `$TMPDIR/tmp.18HeJ5MOAl` (cellular, `session-2026-11-13-074058.log`).

## Background refresh disk writes (debug log line, `f18b1424`)

Each refresh logs `Background refresh disk writes storageBytes=… logicalBytes=… startedInBackground=…` in debug builds.
Foreground debug route on the SE, build `202611130737.7322`: 3.27 MB storage, 3.17 MB logical (File Activity counted
0.33 MB of write calls for the same route; the counters differ and launch work may overlap). A refresh delivered by iOS to
the suspended app on the SE (07:59, `startedInBackground=true`): 0.36 MB storage, 1.95 MB logical. One sample; a
refresh that cold-launches the app, and the 16 Pro, are still owed (read the line from later sessions' logs).
