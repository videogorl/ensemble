# Playback And Queue Policy

- `PlaybackService` owns one provider-neutral logical queue, current index,
  sections, history, shuffle, repeat, and autoplay. Transport adapters and pure
  collaborators never publish a second live queue.
- On iOS/iPadOS 18+, Apple Music and Plex may coexist in logical order. Finite
  Apple items use disposable MusicKit transport segments; Plex uses Ensemble's
  engine. Automatic advance, explicit navigation, restoration, and mutations
  may cross the boundary without replacing the logical queue. Earlier OS
  versions remain Plex-only.
- Apple Music PCM is never decoded, exported, analyzed, mixed, crossfaded, or
  overlapped with Plex audio. Provider boundaries use public MusicKit and audio
  session APIs and leave exactly one active audio owner.
- Stop, Pause, replacement, and newer playback generations invalidate stale
  asynchronous transport work. A stale callback must never advance, stop, seek,
  report, or replace a newer request; every logical item advances at most once.
- MusicKit owns Apple audio rendering, route behavior, and its native station
  queue. Ensemble owns logical sequencing and provider-neutral Now Playing and
  remote command availability.
- Ensemble mirrors Repeat One to MusicKit for the active Apple item so native
  playback owns the loop. Repeat All remains Ensemble-owned across providers.
- Regular Play starts at the requested item with shuffle off. Shuffle preserves
  original order, keeps the current item when toggled, excludes autoplay and
  already-played candidates, and restores original order when disabled.
- Up Next, Continue Playing, Autoplay, and History remain distinct. Manual queue
  mutations protect the queue from direct app-UI replacement until confirmed;
  background/system recovery never presents confirmation UI.
- SmartMix is an opt-in, device-local Plex-only enhancement. It uses the existing
  two-deck model and must gracefully fall back to ordinary gapless playback when
  analysis, device state, queue shape, route, or scheduling is unsuitable.
- Local/stream selection follows connectivity and requested quality. Offline or
  streaming-disallowed playback is local-only; Low Data Mode prefers a valid
  local file. Otherwise stream only when requested quality exceeds the known
  local-file quality, with local fallback after a failed higher-quality stream.
- Direct file streams and universal transcode are both valid Plex paths. Network
  playback starts incrementally rather than waiting for a complete temp file.
  URL ingestion writes an append-only cache file independently from decoder/PCM
  backpressure. Only compatible original containers bypass Plex's decision;
  unsupported originals request a Plex MP3 transcode.
  Starvation or stream failure restarts from the visible playhead; cancellation
  caused by a newer command does not trigger recovery.
- Clean offset-zero playback completions remain in purgeable `Library/Caches`
  under a byte-budgeted LRU. Reuse requires exact source revision and requested
  quality; Original additionally requires direct delivery. These artifacts are
  local-playable for replay, offline use, and arbitrary seek. Failed, cancelled,
  truncated, and offset-started artifacts never become completed cache entries.
- Materialize the immediate upcoming Plex track to disk early, but do not add it
  to the audio-engine schedule until the normal transition window. Queue depth
  must not multiply whole-track memory use.
- Device-offline queues keep downloaded Plex items and allow MusicKit to resolve
  its own asset availability. Known-unavailable Plex servers may be skipped;
  unknown health may not erase the queue.
- Playback resolution, reporting, scrobbling, Now Playing identifiers, and
  restoration remain source-exact. Missing/malformed source ownership fails
  closed. Siri fuzzy recovery may search enabled sources but never use an ID to
  infer an owner or cross an explicitly supplied source.
- Only direct app-UI playback starts donate to system media. Siri, shortcuts,
  remote commands, autoplay, restoration, and recovery are non-donating.
- Watch-local playback uses native `AVPlayer` and its own exact-source queue.
  Compatible originals stream directly; unsupported originals use Plex's MP3
  transcode, materialized into a purgeable 256 MiB Watch LRU before playback.
  Phone Apple Music is remote-control-only on Watch.
