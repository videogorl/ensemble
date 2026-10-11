# Playback startup and prefetch recovery

The supplied October 11 session showed the next track failing prefetch with
`NSURLErrorDomain -1200` at 10:15:08, the current track ending at 10:15:18, and
the next track's engine load failing at 10:15:24. The queue advanced correctly;
there was no recorded interruption or background-task expiration at that point.
The origin of the intermittent TLS failure remains unresolved.

## Delivered correction

- Engine startup errors propagate through `PlaybackLaunchCoordinator` into the
  existing request recovery policy. They no longer stop at a Boolean failure.
- Classification unwraps known playback/Plex error wrappers. Cancellation and
  explicit certificate errors are not included in the new download retry set.
- Eligible file-materialization failures evict stale decisions/loaders, refresh
  the connection, and make one fresh attempt. Failed speculative work receives
  a 30-second cooldown; nonretryable failures wait until the track pair changes.
- TLS startup recovery retains position, generation checks, and background-task
  protection. It invalidates upcoming URLs without awaiting future downloads
  before retrying the current song. Its existing three-failure limit remains.
- Prefetch cleanup checks that its request still belongs to the outgoing track
  before evicting transport state. A stale prefetch failure cannot perform that
  cleanup after its track becomes current.

The existing mini-player failure banner and Retry action remain the user-facing
terminal recovery path. No security validation is bypassed.

## Runtime verification

Debug build `202610111104.3570` was built from `Ensemble.xcworkspace` and explicitly
installed on each verification simulator. Installed executable paths and process
IDs were checked. The DEBUG failure hook is documented in
[agent-runtime-testing.md](../reference/agent-runtime-testing.md); injected TLS
errors exercise recovery after source resolution, not actual TLS handshakes.

On iOS 26.5 simulator `08CA3DD8-D174-40E9-A361-62B95671B969`:

- Track 6943: one injected startup failure at 11:11:17 recovered the same track,
  received live stream bytes, and reached audio rendering at 11:11:22.
- Track 6940: three injected startup failures stopped at the retry limit at
  11:12:48. The rendered banner showed Retry. Tapping it started the same track
  and reached audio rendering at 11:13:31.
- Track 6945: one injected prefetch failure at 11:15:31 recovered while track
  6939 continued playing; the completed file was cached at 11:15:37. After seeking
  near the end of the outgoing song, its actual completion advanced to the
  cached successor at 11:16:52–53.
- With Settings foregrounded and Ensemble logged in the background, track 6939
  ended at 11:19:02 and cached track 6945 reached playing at 11:19:03.
- During a ten-second injected startup delay for track 6939, selecting track
  6945 at 11:23:15 started it successfully. After the delay elapsed, no stale
  retry or stop displaced the new track.

Both iOS 26.5 lanes finished paused. All three simulator UUIDs listed here were
verified `Shutdown`. The cooldown after exhausting both prefetch attempts was
reviewed in code but was not separately exercised at runtime.

On iOS 26.5 simulator `F0465DE7-086B-4FD2-AB91-193D4567031A`, uncached high-quality
track 6942 reached audio rendering in 4.391 seconds. Pause/resume preserved
progress. A foreground completion after seeking advanced to prefetched track
6735, reaching rendering in 149 ms. The lane finished paused and shut down.

iOS 27 simulator `AAD6D5F8-634F-4216-843F-54E9833FB52F` stalled during installation
and basic system commands. It was shut down; no app result is claimed for that
runtime. No unit/integration suites were added or run. Existing launch tests
received only mechanical throwing-call adjustments.

Fresh Plex probes separately returned valid HTTPS, HTTP 200, and audio for three
high-quality requests on reachable local endpoints. The advertised remote
endpoint still timed out. These probes do not identify the historical failed
endpoint or establish the cause of the phone's TLS failure.

## Remaining design decision

Incomplete prefetch reuse is a separate ownership change. Today prefetch's
`ProgressiveStreamLoader` downloads a complete file, while active playback's
`StreamingAudioPipeline` creates another request, writer, decoder, and PCM ring.
A proposed shared pipeline would prepare the upcoming stream once and transfer
it to the engine at handoff, removing the duplicate native prefetch downloader
and request. Completed files would continue to serve SmartMix and cache replay.

That design needs explicit ownership transfer, cancellation/queue/quality/seek
guards, startup readiness, and error delivery before and after acquisition.
SmartMix still requires completed-file analysis. Do not represent a growing file
as a completed `cachedFile`: native file loading can see premature EOF, and a
second writer can replace the file. This architecture step awaits approval.
