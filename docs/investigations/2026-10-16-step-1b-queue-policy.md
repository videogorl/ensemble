# Step 1b: one rule for what follows the current item

Re-architecture step 1b, per [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
and the approved [design note](../reference/playback-state-machine-design.md).
Code commit `3e063453`, started from `dc155583`. Simulator-checked, not
verified: the physical iPhone items are in the device backlog.

## What changed

`EnsembleQueuePolicy.advance` in EnsembleDomain decides what follows the
current item: repeat the current item, play an item (possibly wrapped), hand
over to autoplay, end the queue, or report unavailable items. Every advance
path now asks it:

- iPhone, playing: natural end (`handleQueueExhausted`), `next()`, SmartMix
  Next, and the Apple Music boundary (`advanceAfterAppleMusicSegment`), through
  one executor, `performQueueAdvance`.
- iPhone, paused: Next while paused.
- Watch: Next and natural end.

Behaviour changes, all approved in the design note:

| Rule | Before | Now |
|---|---|---|
| G1 natural end at the last item, repeat off | Stop; the mini player cleared | Stay on the last item, paused at 0:00, queue kept |
| G2 Next at the last item, repeat off | Stop while playing; nothing while paused | Autoplay item if on, else as G1 |
| G3 Next at the last item, Repeat One | Stop (iPhone), restart (watch) | Wrap to the first item |
| Q2 Repeat All at an Apple Music boundary | Could start a station and truncate the whole queue | Wraps first; a wrap never starts a station |
| Q5 changing repeat | Already-scheduled gapless successor still played | Schedule re-checked and replaced |
| Q6 reorder while shuffled | Lost when shuffle turned off | Moved item keeps its new neighbour |
| Q7 SmartMix Next at the end with autoplay on | Fetched autoplay, then nothing until the watchdog | Same as any Next at the end |
| D2 history after Previous | Next gapless advance dropped its history entry | Recorded |

Removed: `completionQueueIndex`, `nextQueueIndexAfterCompletion`,
`autoplayAdvanceIndex`, `shouldStartAppleMusicAutoplay`,
`findNextPlayableTrackIndex`, `PlaybackQueueController.nextPlayableIndex`, the
`isNavigatingBackward` flag, and the tests that pinned them. The removed tests
are replaced by one table test (`testQueueAdvanceTable`) and one reorder test
in EnsembleDomain, and a rewritten station-decision test in Core.

Not done in 1b, by design: storing a `PlaybackQueue` value in the service. The
queue fields are still `@Published` service properties read by the UI; moving
them into one value lands with the snapshot in 1e. Holding the unshuffled
order as IDs moves to 1d with persistence: shuffle drops already-played items
from the live queue, so the original order still has to hold those items.
The other G rows (G4 to G22 except G9) belong to 1c and 1d. G9 already held:
a remove or move re-checks the gapless schedule.

## Checks

- `swift test` in EnsembleDomain (new table), EnsembleCore playback groups
  (158 tests), and EnsembleWatchCore (33): all pass.
- Builds through `scripts/build_serial.py`: iOS Simulator, watchOS Simulator,
  macOS arm64, all succeeded.

### Simulator

Simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1` (iPhone 17 Pro, iOS 26.5),
signed-in Plex library. Prepared with `scripts/prepare_runtime.py`, run
directory `/tmp/ensemble-step1b-sim`, source `3e063453` with a clean tree,
build `0.4.0 (202610161337.3063)`, executable hash and PID path matched, same
PID throughout. Driven with `agent-device` pinned to the UUID. Shut down
afterwards and confirmed `Shutdown`.

| Check | Result | Evidence |
|---|---|---|
| G2 Next on the last item, repeat and autoplay off | pass | Paladin Strait stayed current, paused, 0:00; log `next()-endOfQueue` |
| G3 Next on the last item under Repeat One | pass | REDLIGHTS played; log `caller: next()-wrap` |
| Natural end mid-queue | pass | `GAPLESS_ADVANCE` REDLIGHTS to Paladin Strait |
| Q5 Repeat All to Repeat One with the wrap scheduled | pass | REDLIGHTS scheduled 13:44:16, schedule cleared on the change 13:44:24, `handleQueueExhausted-repeatOne` at the end |
| G1 natural end on the last item, repeat off | pass | Paladin Strait paused at 0:00, queue kept |
| Natural end under Repeat All | pass | `handleQueueExhausted-wrap` (here the queue was one item because shuffle was on by mistake; the wrap to itself was correct for that queue) |
| D2 Previous then gapless advance | pass | History lists Ripe & Ruin and Intro after Previous and `GAPLESS_ADVANCE` Ripe & Ruin to Tessellate |
| Q6 reorder while shuffled, then shuffle off | pass | Taro dragged directly after the current track stayed there with shuffle off; album order otherwise intact |

Not run on the simulator: Q2 and the Apple Music boundary (no Apple Music on
this simulator), Q7 (SmartMix Next at the end of the queue), and the watch
changes. These are in the device backlog.

Observed, unchanged by this step: turning shuffle on drops already-played
items from the live queue (`EnsembleQueuePolicy.shuffledQueue`), so a Repeat
All wrap while shuffled starts from the current item.
