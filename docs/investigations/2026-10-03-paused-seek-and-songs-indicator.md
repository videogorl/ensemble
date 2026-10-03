# Paused transcode seek and Songs indicator fix

Implemented in the existing `t3code/bug-bash-investigation` worktree, starting
from clean `087214ca71e7854c693c44570bb927c8bca1cc88`. Concurrent-process
inspection found computer-use helpers with read-only repository access, not
another editor. No additional worktree, agent, physical-phone control, push,
merge, deployment, or network/security configuration change was made.

## Reproduction and ownership

Reviewed `2026-10-02-physical-device-checkpoint.md` and the independent audit
at `/Users/felicity/Documents/Codex/2026-10-01/task-5/physical-checkpoint-independent-audit-2026-10-03.md`.

On the unchanged HEAD, iPhone 17 Pro / iOS 26.5 simulator
`F0465DE7-086B-4FD2-AB91-193D4567031A` reproduced:

- Caramel / Sleep Token, Minibar library 3 / 16303, high quality, active
  `transcodedHTTP`: pause, then tap the real waveform to seek to 157.67 seconds.
  Logs at 09:48:05 show `paused → loading → buffering → playing` without a
  resume command. `PlaybackService.seek` restarts through `playCurrentQueueItem`,
  then `PlaybackLaunchCoordinator` and `loadAndPlaySource` unconditionally start
  the loaded engine.
- Songs' visible Caramel row retained its duration rather than acquiring the
  speaker while the miniplayer and logs showed Caramel playing. The physical
  evidence additionally shows the previous row retaining the speaker. Songs
  holds NowPlayingViewModel as a plain reference and did not subscribe to track
  changes. Native MediaTrackList already compares source-scoped playback
  identities and reconfigures visible cells when its parent supplies a new ID.

The baseline built and installed binary hashes matched; PID 37163's executable
was the explicitly installed simulator bundle. Initial accessibility capture
timed out on the full library; a temporary Songs filter reduced the tree and
allowed UUID-pinned agent-device interaction. Screenshots and accepted journey
logs, rather than input acknowledgments alone, establish the results.

## Changes

- Carry seek playback intent through the existing launch and retry paths. A
  paused reload loads the engine without calling play, finishes paused, clears
  transition protection, and saves the prepared position. Repeated seeks during
  loading retain that intent; generation checks reject superseded work. Existing
  connection refresh/TLS security behavior remains intact, with paused intent
  and position forwarded through its retry.
- Initialize the streaming engine's durable clock from the existing source
  start offset before playback. Runtime checking found a zero playhead after
  the first paused-load implementation; the extended engine regression failed
  on both clock assertions before this correction and passed afterward.
- Songs reuses `nowPlayingTrackListObservation`, with narrow current-track and
  recent-playlist projections. All compact/large-screen, indexed/flat hosts
  receive the source-scoped ID. No broad Now Playing observation, engine
  replacement, persistence/schema change, or cleanup reversal was introduced.

## Verification

Before playback edits, curl verified exact Minibar library 3 / Caramel identity
using locally read credentials, unique sessions, and decision-before-start:
direct part range `206` / 65,536 bytes; universal decision `200` and stream `200`
at offsets 0 and 155 (9,365,011 and 4,548,490 bytes respectively). Credentials
were passed privately and excluded from exported evidence. The worktree has no
`.env`; the existing primary checkout's `.env` was used, as in the supplied audit.

- 47 focused Core tests passed: PlaybackLaunchCoordinatorTests,
  PlaybackHandoffCoordinatorTests, AudioPlaybackEngineStreamingTests, and
  PlaybackTransportCoordinatorTests. Added one table-driven launch-intent
  regression for paused/playing transcode and cached-file reloads, and extended
  the existing engine start-offset test to cover loaded-but-not-playing clocks.
- 23 existing generation/prefetch tests and 3 existing Songs/native-row/source
  identity UI tests passed. UI package compilation covers macOS code; there was
  no direct macOS UI run.
- Debug build passed using `Ensemble.xcworkspace`, exact simulator UUID, and
  task-specific `/tmp/ensemble-seek-speaker-20261003/DerivedData`.
- Runtime: active paused transcode seek finishes paused at 157 seconds with Play
  visible; another paused seek to 117 seconds also finishes paused. Explicit
  Play then renders from that prepared source. A playing seek to 184 seconds
  resumes normal buffering/playing. These stream journeys have no first-render
  event before explicit resume on paused reloads.
- Runtime: Songs shows the current speaker and clears it when Next empties the
  queue. Selecting Robot Zombie Attack then 3 Letters Back moves the speaker;
  selecting the second account's same-server/library/7278 copy moves it again,
  leaving only the selected source's row marked. That second-account playback
  used its scoped cached file, not an uncached second-account network stream.
  Robot Zombie Attack / 6758 also loaded/rendered via `directHTTP` at Original.
- After final retry forwarding edits, the final source was rebuilt, reinstalled,
  and the active paused Caramel transcode seek and current speaker were checked
  again. Final binary SHA-256:
  `1570da691527bfad86e5cae5fdce58e373c9a756739f83253e1e408af2c82e7f`.
  Built/installed versions matched `0.4.0 / 202610030939.0872`; PID 65397 matched
  the installed bundle executable. Hash proof distinguishes incremental builds
  that shared the generated version string.

Evidence is under `/tmp/ensemble-seek-speaker-20261003/`: safe endpoint results,
build/test logs, baseline and final session logs, artifact proof, and screenshots
`final-paused-seek.png`, `final-speaker-moved.png`,
`final-speaker-account-switched.png`, and `final-speaker-cleared.png`.

No remaining implementation blocker. Physical-device retesting, old supported
OS/2 GB hardware, background/locked playback, system remote commands, and fault
injection through TLS/local-open recovery remain unverified. The physical phone
was not accessed. Simulator playback was left paused, its original Songs filter
was restored, and the simulator was shut down; test playback selection/queue was
not restored to the original simulator selection.
