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

## iPhone 16 Pro

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

- Plex to Apple Music, Apple Music to Apple Music, and Apple Music to Plex,
  with Next and with natural completion, locked and unlocked.
- System Previous on an Apple Music item: the first restarts, a second within
  three seconds goes back (inferred by the adapter).
- Pause and resume from Control Center on an Apple Music item: the app follows.
- Apple Music autoplay station: items advance, the queue mirrors upcoming
  items, and a station Previous does not add a duplicate (D5).
- A track that follows a skip scrobbles in Plex once past 90 percent (D3),
  with scrobbling enabled.
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

- Lock Screen: artwork, title, pause, play, next, scrub.
- Control Center: media tile, pause, play, next.
- Background playback: natural track change while locked.
- Offline playback: downloaded track in Airplane Mode; blocked track toasts.
- Siri media request, and Siri affinity and add.
- App Shortcuts: all five listed; Play Album runs.
- Focus filter offered in Settings.
- Spotlight result opens the item.

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

## iPad Pro and Apple Watch

- Watch, step 1b at `3e063453`: Next on the last track wraps under Repeat One
  and Repeat All; with repeat off, Next and a natural end leave the last track
  paused at the start.

The iPad and watch checklist sections start with steps 5 and 6.
