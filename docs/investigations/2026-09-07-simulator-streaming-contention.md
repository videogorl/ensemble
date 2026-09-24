# Simulator experiment: streaming starvation and recovery

September 7, 2026. Follow-up to the [offline/network log audit](2026-09-07-offline-network-performance.md).
No production behavior was changed. Temporary DEBUG instrumentation was removed
after the measurements.

## Result

The simulator reproduced two deeper failure mechanisms:

1. A download plus incremental sync sharing a limited connection with playback
   caused substantial zero-filled audio, without triggering the existing
   underrun recovery log. The same bandwidth was sufficient for playback alone.
2. A single transient delivery gap caused Ensemble to rebuild a still-running
   HTTP 200 stream. A direct HTTP client retained its connection through the
   same gap and continued receiving data.

This establishes mechanisms that can explain the iPad report. It does not prove
that these were the exact conditions on the original device, nor establish that
the original probe storm caused its stalls.

## Environment and controls

- Dedicated clone of the existing iPad (A16) simulator; original simulator left
  untouched. UUID `08CA3DD8-D174-40E9-A361-62B95671B969`, iOS 26.5 / 23F77.
  The historical problem was on an iPad running iOS 27; this is not an OS-version
  reproduction or a physical-radio/battery test.
- Workspace build from `f9293afc`, with an opt-in temporary instrumentation
  patch. Explicit build/install/process checks and executable SHA-256 comparison
  established artifact freshness. Original source was restored afterward.
- Same Plex server, track `13827` ("Downstairs"), high quality requested at
  320 kbps, progressive MP3 transcode, starting at zero, single-track queue.
- A localhost TLS CONNECT proxy forwarded encrypted traffic without replacing
  certificates or decrypting payloads. It imposed a shared downstream limit of
  **48,000 bytes/second**, including TLS overhead, across the app's proxied work.
  The Mac's global networking configuration was not changed.
- App data was restored from a private copy of the cloned container before each
  trial. Stream cache and restored playback snapshot were cleared. An initial
  cached warmup was explicitly rejected; accepted runs logged uncached streaming.
- After startup settled, **quiet** mode stopped periodic sync, WebSockets,
  downloads, and idle artifact work. Audible playback still used the production
  playback service, engine, decoder, and HTTP pipeline.
- **Busy/normal-work** mode retained normal services and explicitly started
  incremental sync plus an album download ("The Maybe Man", same server).
  Thus this represents a supported concurrent workload, not every ordinary
  foreground session. Single-track queues excluded next-track preloading from
  both conditions. Isolating sync from downloads would require another comparison.
- Playback ran for 45 seconds after preparation. A one-second sampler recorded
  pipeline diagnostics. A second instrumentation pass counted requested and
  unavailable PCM frames inside the buffer's existing render lock. No buffer
  sizes, retry thresholds, or production decisions were modified.

## Playback measurements

| Condition | First audio render | Zero-filled frames, expressed as audio time | Full underrun events / restarts |
| --- | --- | --- | --- |
| Quiet, unrestricted proxy | 306 ms | Not instrumented in this pass | 0 / 0 |
| Sync + album download, unrestricted | 968 ms | Not instrumented in this pass | 0 / 0 |
| Quiet, 48 KB/s shared limit | 881 ms | **0.000 s of 44.789 s rendered** | 0 / 0 |
| Sync + album download, same 48 KB/s limit | 1,968 ms | **12.159 s of 44.160 s rendered (27.53%)** | **0 / 0** |
| Quiet, same limit plus one four-second gap | 902 ms; restart 2,285 ms | See per-segment evidence | 1 / 1 |
| Repeat of the single-gap case | 916 ms; restart 2,559 ms | See per-segment evidence | 1 / 1 |

The counted durations end at the last diagnostic sample, rather than an exact
45-second boundary. Missing time is the sum of frames the renderer filled with
zeros, not one continuous pause, and not an assertion that the agent heard audio.
It includes any startup render callbacks; the quiet control nevertheless had
zero missing frames.

A preceding limited-bandwidth pair, before cumulative counters were added,
also showed zero empty-buffer samples for quiet playback versus 19/45 samples
with an empty buffer in the busy case. Startup was 977 versus 2,544 ms. Treat
these as individual trial observations, not statistically established latency
distributions.

There were **zero endpoint probe starts during the measured playback windows**.
Each app launch had 19 pre-measurement probe starts. Consequently, concurrent
traffic can reproduce starvation without a probe storm. In the unrestricted
busy trial, approximately 88.8 MB traversed the proxy during the assigned run,
confirming bulk download traffic participated in the experiment. The limited
busy trials retained one active download attempt.

## Direct HTTP comparison

The initial discovery probe used a different address for the same PMS. For the
final controls, the proxy captured the destination of the largest playback
tunnel; its `/identity` response matched the target server. Direct controls
used that exact endpoint, track, high-quality transcode parameters, and a fresh
transcode session after calling the decision endpoint.

| Direct HTTP condition | First payload bytes | Data received | Largest observed receive gap |
| --- | --- | --- | --- |
| Exact endpoint, unrestricted | 152 ms | Complete 10,315,076 bytes in 2.601 s | 97 ms |
| Exact endpoint, 48 KB/s | 745 ms | 2,142,655 bytes in 45.018 s | 514 ms |
| Exact endpoint, same limit + one four-second gap | 754 ms | 1,954,246 bytes in 45.019 s | **4.224 s** |

The limited controls used curl's intentional 45-second deadline, returning exit
28; they are partial observation windows, not completed-file validations. Both
received HTTP 200 and used one stream request through the observation interval.
The single-gap control continued receiving after the imposed gap without an
application-directed reconnect. Its TTFB is not equivalent to the app's first
audio render, which also includes preparation and decoding.

The gap was imposed once, two seconds into the measurement, with normal paced
delivery afterward. This tests a transient stall on an otherwise adequate link,
not permanent bandwidth below the audio's required rate.

## What the code and evidence explain

### Missing short-gap telemetry

`StreamingPCMBuffer.read(into:frameCount:)` fills unavailable frames with zeros.
`StreamingRenderHealth.observe` resets its missing-frame streak whenever a
callback receives all requested frames. Frequent smaller gaps can therefore
produce extensive silence without crossing the consecutive missing-frame
threshold. The busy counted run directly demonstrates that blind spot.

The ordinary playback state remained playing between these gaps. "No underrun
log" is not sufficient evidence of glitch-free streaming. This does not
invalidate the original offline file-playback observations; that is a different
source path.

### Recovery amplifies a longer gap

In the first single-gap trial, the engine logged its underrun at 19:31:16.063:
HTTP 200, task running, 2.78 seconds since both the last byte and last PCM,
73,721 bytes received, empty buffer. It immediately entered
`retryCurrentTrack(stream-interrupted)` and created a fresh playback attempt.
First audio returned 2.285 seconds later. The repeated trial followed the same
pattern. The direct HTTP control shows the connection could survive the gap;
it does not prove that simply retaining the stream would eliminate audible
waiting or solve sustained bandwidth shortage.

### Existing download sensitivity does not reserve bandwidth

`OfflineDownloadService.currentDownloadWorkMode` selects interactive playback
mode, and `DownloadQueueCoordinator` reduces work/cadence. That still leaves an
active transfer able to compete with audio. The controlled comparison makes
traffic admission and prioritization a stronger next target than globally
lengthening timeouts or increasing a buffer constant.

## Recommended next changes and checks

1. Expose cumulative missing-render frames and low-buffer duration in bounded
   diagnostics. Do not rely solely on consecutive-underrun events.
2. Feed streaming buffer health into the existing download/background-work
   policy. Yield discretionary work while audible playback lacks a reserve;
   resume after recovery with hysteresis. Do not disable downloads on every
   healthy connection or let the worker's own retries defeat the pause.
3. Distinguish recoverable starvation from transport failure. Keep a live stream
   through bounded rebuffering; only rebuild after failure or a bounded lack of
   progress. Verify media time and system Now Playing remain correct while
   output waits.
4. Repeat this matrix after the smallest owning fixes, including low/high
   bandwidth and the single gap. Separate sync-only and download-only if needed
   to quantify their individual contributions. Then validate the affected
   physical iPad/OS and realistic radio conditions.

The prior health/failover and pending-mutation findings remain separate work.
This experiment did not run a three-day simulator soak, pending-mutation replay,
or energy profiling. Server request logs were inspected alongside the trials;
an initial metadata request took approximately 31 seconds on PMS itself and a
subsequent request took 487 ms. That is a separate live-server outlier, not an
established cause of the historical stalls or these deliberately shaped runs.

## Artifacts and cleanup

- [Measurements](artifacts/2026-09-07-streaming-simulator/measurements.json)
- [Focused evidence](artifacts/2026-09-07-streaming-simulator/evidence.txt)
- [Temporary instrumentation patch](artifacts/2026-09-07-streaming-simulator/instrumentation.patch)
- Full local experiment files, proxy/runner/control scripts, session logs,
  receive timing records, and build provenance: `/tmp/ensemble-network-audit/`.
  Private credential/endpoint files and cloned application data are not committed.

The instrumentation patch documents the measured build; it is not applied to
production. The original app source was restored and rebuilt. Simulator work
was serialized, with playback paused before each trial ended.
The clean app was reinstalled, the isolated simulator shut down, and the local
proxy stopped after testing.
