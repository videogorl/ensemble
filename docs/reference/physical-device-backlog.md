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

### Customizable Now Playing secondary actions, 2026-10-13 feature commit

Builds and SE/macOS/iPad evidence are in
[the feature verification note](../investigations/2026-10-13-now-playing-secondary-actions.md).
The final iOS app is built and installed, but the phone remained passcode-locked.

- Open AirPlay from the overflow and from its pinned native button; cancel
  without changing the route. The Mac picker opened; neither simulator path
  showed a picker, so iOS presentation remains unproven.
- Verify Apple Music availability in the real app (capability logic is covered
  by focused tests; simulator row checks used Plex).
- Verify a controlled iCloud layout round trip between two physical clients,
  including sync OFF. SE displayed actual local push and remote pull statuses,
  and coordinator tests cover gating, but those do not prove full convergence.
- Exercise the guarded visible AirPlay fallback if the native internal button
  is unavailable; normal runtime used an intact native picker hierarchy.


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

## iPad Pro and Apple Watch

Nothing yet. Their checklist sections start with steps 5 and 6.
