# Physical device backlog

Checks the simulator could not prove, kept until they are run on real
hardware. See [`rearchitecture-plan.md`](rearchitecture-plan.md) section 7.

- Add an item when a step's acceptance check cannot run, or runs only partly,
  on a simulator. Name the commit it applies to.
- Run items on the iPhone 16 Pro through Device Hub unless another device is
  named. Prove the installed build first.
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
The iPhone 16 Pro, Mac, iPad and Watch items below remain independent checks.

## iPhone 16 Pro

The items below for steps 0 to 2 are deferred by Felicity's choice on
2026-11-02. They are not passed and not verified, and they stay here until
they run on the phone. On 2026-11-01 none could run: Computer Use was not
available to the agent, and the Xcode MCP listed only simulators, not the
iPhone (paired, Wi-Fi tunnel connected). Running them needs Computer Use for
Device Hub, or the phone on a cable so the Xcode MCP can reach it.

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

### Playback position fixes, branch `fix/playback-position-sync` at `9ee8cf42` or later

Proven on macOS with a real AVAudioEngine (`AudioPlaybackEnginePositionTests`),
not on the phone or AirPlay.

- AirPlay then interruption (`9aaf9815`): switch to AirPlay, let several tracks
  advance gaplessly, then trigger an interruption (call or Siri). The paused
  scrubber and the resumed position match the current track, not the track
  that was playing at the switch.
- Pause and resume after gapless advances (`ae391278`): after a few gapless
  tracks, pause and resume. The scrubber continues from the paused time, and a
  later AirPlay switch logs a `render=` close to `observed=` and never
  `Ignoring render clock`. Repeat once with the phone locked.
- Relaunch and resume (`62e82bac`): force-quit while paused mid-queue,
  relaunch, play, and let the track end into a gapless advance. The lock screen,
  scrubber, and `ITEM_CHANGED ... via gapless` follow the new track, and no
  `dropped native ... outside a session` line appears.
- Early segment end (`9ee8cf42`, diagnostic only): keep AirPlay playing a
  stream-cached queue. If a track ends early, read the `Segment ended early`
  line for the playhead, duration, frame counts, and file size.

### Sweep fixes on the same branch, after `dbec02b4`

Engine and service paths are covered by EnsembleCore tests on macOS; none ran
on the phone. Name each commit by its subject until it has a hash here.

- Paused Next then Previous, then Play ("Unload the current item when the
  engine stops"): sound plays and the scrubber moves. After a Plex track hands
  off to Apple Music, the duration shown is the Apple Music track's.
- Apple Music pause while buffering ("Rebind Apple Music events when a pause
  starts a new session"): press Play on a paused Apple Music track and pause
  again before it starts; then resume, once in the app and once from Control
  Center. The scrubber and Lock Screen move, and the next track advances. Not
  covered by any automated test.
- Relaunch, then Next within 3 seconds ("Pre-buffer a restored queue at the
  current paused playhead"): with a paused restored queue, press Next right
  after launch, wait 5 seconds, press Play. The new track starts at 0:00.
- Autoplay off while an autoplay track plays ("Keep the queue index on the
  current item after removals"): the playing row stays highlighted and Next
  goes to the following non-autoplay item, or ends the queue.
- SmartMix cancel ("Stop a cancelled SmartMix crossfade from ending the
  track"): during the first half of a crossfade, reorder Up Next or turn
  SmartMix off. The outgoing track keeps playing to its end and then advances.
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

- Steps 2c and 2d, at `cf4e8d19` or later: launch, a toast, the Downloads
  sheet, the Autoplay and SmartMix toggles, and an album's blurred header
  backdrop. The simulator could not finish the 2d pass because host audio
  hung (step note).
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
- G17: in Airplane Mode, a track already streamed in full plays and is not
  greyed out; an Apple Music track is greyed out and skipped.
- G18: pause an uncached Plex stream, switch from Wi-Fi to cellular (or wait
  until the server drops the connection), press Play; it continues from the
  same position without a long buffering wait.
- Watch: queue, track, and shuffle state still mirror after the snapshot
  change.

### Step 1d session lifecycle, at `2544a52a` or later

See [the step note](../investigations/2026-10-17-step-1d-session-lifecycle.md).

- Phone call during a load: the load finishes, then pauses; it resumes only
  if iOS sends the should-resume hint, and stays paused while locked otherwise
  (G14).
- Bluetooth disconnect during a load: ends paused.
- Lock Screen while a track loads after Next: shows playing; a track that
  loads while paused shows paused.
- A failed track while locked skips once; a second failure halts with the
  error on the Lock Screen (G11, G15).
- Apple Music item that fails to start: skipped once (G11).
- Pause during a load from the Lock Screen: stays paused.

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

- End of queue: natural end and Next on the last item leave it paused at 0:00
  with the queue kept; Lock Screen shows the paused item.
- Next on the last item under Repeat One wraps to the first item, also from
  the Lock Screen.
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

- Lock Screen: play and scrub. (Artwork, title, pause, and Next passed on
  2026-10-26.)
- Control Center: media tile, pause, play, next.
- Background playback: natural track change while locked.
- Offline playback: downloaded track in Airplane Mode; blocked track toasts.
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
- Step 6c panes on a physical iPad (not run): native `NavigationSplitView`
  now serves every iPad, including iPadOS 17; Artists, Genres and Playlists
  show detail in the next column, rotation and Split View resizing keep the
  selection, and full-width kinds push. Also the iPhone tab flow after the
  shell removal, and the built Mac app (launch, ten sidebar switches, switch
  time against the 299 ms baseline).

## iPad Pro and Apple Watch

- Watch, step 1b at `3e063453`: Next on the last track wraps under Repeat One
  and Repeat All; with repeat off, Next and a natural end leave the last track
  paused at the start.

The iPad and watch checklist sections start with steps 5 and 6.
