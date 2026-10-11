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

## Shared prefetch implementation

The approved ownership change now uses one `StreamingAudioPipeline` for both
prefetch and active streaming. Transport owns an unclaimed pipeline matched by
full artifact identity (source fingerprint, quality, delivery, and seek offset).
The engine atomically takes it before decoding; transport eviction thereafter
cannot cancel it. Queue replacement discards only unclaimed streams. Pruning
uses the current queue and successor in one synchronous MainActor snapshot,
preventing an older prefetch task from canceling a newer successor.

Prefetch starts compressed-byte downloading without a decoder or PCM ring.
Adoption starts the decoder against the same growing file. Network completion
and decoder completion are distinct: the pipeline validates and registers the
completed artifact once before waking file consumers, while rendering uses
decoder EOF. SmartMix and gapless file scheduling still require complete files.

`ProgressiveStreamLoader` and its unused AVAssetResourceLoader bridge were
removed. Fresh streams also use unique partial paths. Active partial paths are
protected from automatic artifact trimming until completion or cancellation;
a completed artifact cannot be removed by a late cancellation.

SmartMix verification exposed a duplicate scheduling path: a prefetch during an
active mix could schedule the same incoming song on the outgoing deck. Stopping
that deck at handoff fired a current-generation completion and skipped the
incoming song. Both the scheduling guard and engine refuse gapless scheduling
during an active mix, preserving the incoming segment's own completion.

## Shared-pipeline verification

Shared-pipeline verification build SHA-256 begins `523f8087`, version
`202610111140.5179`. The final queue-pruning correction was rebuilt as `4e42f98d`
and verified on the first simulator. Installed executables matched their built
binaries on both iOS 26.5 simulators;
version alone was insufficient because incremental builds reused the version.
No unit/integration suites were added or run.

On `08CA3DD8-D174-40E9-A361-62B95671B969`:

- Earlier integration build: an uncached high-quality prefetch for track 6944
  started at 11:44:16, then playback adopted its 90,105 bytes at 11:44:22 and
  rendered in 63 ms. The artificial 20-second network pause caused buffering;
  the same download completed and playback resumed at 11:44:37. Original-quality
  adoption also occurred while Ensemble was backgrounded, before network EOF.
- Final build: medium-quality 6943 prefetch remained intact across outgoing
  6940's artifact completion at 11:54:15. With Ensemble backgrounded at 11:54:32,
  actual outgoing completion at 11:54:34 advanced to the completed incoming file
  and reached playing at 11:54:34.671. Each track logged one download start.
- Final build: low-quality 6943 was adopted with 8,185 bytes at 11:55:52.907.
  The decoder waited for more bytes; the same download completed at 11:56:02.967
  and rendering began at 11:56:03.005. No replacement request was started.
- Queue replacement at 11:58:20 canceled the delayed, unclaimed medium-quality
  6944 prefetch before its 20-second delay ended. Track 6939 reached playing at
  11:58:21; afterward there was no completed medium artifact, unregistered
  partial file, stale retry, or playback failure for 6944.

- Final ownership build: delayed 6944 started at 12:03:06; queue replacement at
  12:03:13 reached rendering on 6939 in 133 ms. After the delay expired, there
  was no 6944 completion, retry, medium-quality artifact, or unregistered audio
  partial. Playback was paused and the simulator verified `Shutdown`.

On `F0465DE7-086B-4FD2-AB91-193D4567031A` with build `523f8087`:

- Completed-file SmartMix into track 6735 started at 11:54:41, promoted at
  11:54:46, and completed deck handoff at 11:54:51. The incoming track continued
  from 25 to 55 seconds, more than 35 seconds beyond handoff, without premature
  advancement or duplicate gapless scheduling.
- Uncached original-quality track 6941 reached audio rendering in 310 ms. Current
  and prefetched direct-file streams each logged one successful download.
- Playback finished paused; temporary launch overrides were removed and the
  simulator was verified shut down.

These are simulator/render-state results, not physical-device audibility or
proof of the historical TLS failure's origin. Fresh endpoint probes verified
both direct-file and decision-then-transcode paths before editing.
