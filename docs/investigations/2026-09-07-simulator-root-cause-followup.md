# Simulator root-cause follow-up

September 7, 2026. Extends the [offline log audit](2026-09-07-offline-network-performance.md)
and [first streaming experiment](2026-09-07-simulator-streaming-contention.md).

## Findings

Three owning behaviors are now supported by simulator evidence:

1. Incremental sync can starve streaming playback on an otherwise adequate link.
   Its full artist comparison overlaps the starvation even when nothing changed.
2. Streaming underrun recovery rebuilds a live connection, while the streaming
   playback clock advances through missing audio. Retaining the connection alone
   would leave a clock/content mismatch.
3. Pending-mutation replay spends its permanent-failure budget on transport
   errors. Restoring transport does not automatically recover those failed rows.

These are reproduced mechanisms, not proof of the original iPad's exact network
conditions. The earlier combined-workload result must not be attributed solely
to downloads or probes.

## Controlled workload isolation

Used the same dedicated iPad A16 simulator, UUID
`08CA3DD8-D174-40E9-A361-62B95671B969`, iOS 26.5 / 23F77. Builds came from
`460433fd`, with temporary instrumentation. Built and installed executable hashes
matched; each runner recorded its PID executable path. Full app source was
restored afterward.

The same uncached Downstairs track, single-track queue, requested 320 kbps
progressive MP3, private baseline app container, and shared encrypted downstream
limit of 48,000 bytes/second were reused. Quiet setup stopped periodic sync,
WebSockets, download/sidecar work, and the foreground idle scheduler. Each
workload was then explicitly enabled in isolation. No global network settings
changed. Counts below cover the playback window, excluding startup probes.

| Workload | First audio render | Missing audio time | Probe starts | Full underruns / restarts |
| --- | ---: | ---: | ---: | ---: |
| Playback alone | 1,222 ms | 0.000 s | 0 | 0 / 0 |
| Album download only | 1,021 ms | 0.000 s | 0 | 0 / 0 |
| Incremental sync only | 1,682 ms | 0.844 s | 0 | 0 / 0 |
| Incremental sync repeat | 2,193 ms | 0.789 s | 0 | 0 / 0 |
| Forced health probes only | 911 ms | 0.000 s | 152 | 0 / 0 |

Missing audio means cumulative PCM frames filled with zeros, not an assertion
that the agent heard sound. Runs lasted about 45 seconds; counter samples end
before the final pause. The sync repeat ran after compilation had completed,
removing concurrent build activity as an explanation for its result.

Probe stress explicitly invalidated health caches and called the production
health checker eight times, with a three-second pause after each completed run.
It is a stress condition, not a reproduction of the historical event schedule.
It does not measure radio wakeups or energy cost.

The download-only run launched one production download attempt. Its download
queue continued status polling and was cancelled at the window's end. This is
not a sustained bulk-download saturation test and does not establish that all
active downloads are harmless. It did not reproduce the earlier combined
workload's 12.159 seconds of missing audio. Other foreground work was disabled
here, unlike that earlier combined trial. The difference remains unallocated.

### The sync work doing the competing

`PlexMusicSourceSyncProvider` calls `getArtists(sectionKey:)` during incremental
sync. `PlexAPIClient+Library` implements that as a paged full artist inventory.
The reason is legitimate: Plex artist metadata can change without advancing
section or artist timestamps.

In both sync trials, the playback library's 215-artist comparison took about
13.1 seconds and found **zero changed artists**. Other libraries' comparisons
also ran; a 111-artist comparison took about 7.2 seconds. PCM starvation occurred
during the early comparison interval, with closely matching last-byte and
last-decoded-PCM ages. This supports network supply starvation rather than a
separate decoder backlog.

Keep the metadata-correctness behavior. The next targeted change should admit
this discretionary work according to playback buffer reserve, with recovery
hysteresis. Do not broadly remove the comparison or treat an incomplete result
as an empty catalog. Exact byte attribution by URLSession task was not captured:
the proxy counts encrypted connection traffic, which cannot safely be equated
to individual HTTP requests. The workload isolation and app phase logs provide
attribution at the workload level.

## Recovery and playback clock

A second build added one-second playback-position samples. Both recovery trials
used the same four-second downstream gap, beginning two seconds after playback
measurement started. The sole decision change in `retain` mode skipped the
underrun error callback; actual transport errors were unchanged.

| Recovery behavior | Initial first audio | Restarts | Observation |
| --- | ---: | ---: | --- |
| Production callback | 901 ms | 1 | Restart first audio took another 2,500 ms |
| Experimental retained stream | 870 ms | 0 | Same pipeline resumed bytes and PCM; 2.401 s total missing audio |

Both hit the underrun at an empty buffer, HTTP 200, task running, 2.77 seconds
since the last byte and PCM. The retained pipeline subsequently refilled its
20-second buffer, without a new first-audio journey.

At 20:11:34.179, the retained pipeline had requested 2,017,076 frames and filled
105,880 missing frames with zeros at 44,100 Hz: **45.740 seconds of render time,
43.338 seconds of actual PCM consumption**. At 20:11:34.234, the published
playback position was **45.802 seconds**. The roughly 2.4-second difference
tracks the missing audio, allowing for the 55 ms sample offset.

`AudioPlaybackEngine.startTimeUpdates` advances streaming progress from wall
clock time. `PlaybackService.retryCurrentTrack` uses that published position to
choose a recovery seek. A complete fix therefore needs bounded rebuffering and
content-consumption-aware position accounting, including Now Playing and end-of-
track decisions. Merely suppressing the error callback is not a production fix:
it leaves the clock mismatch and lacks bounded handling for persistent stalls.
System Now Playing accuracy was not independently tested here.

## Interrupted pending replay

The running simulator exercised production `MutationCoordinator`, its CoreData
repository, provider routing, and Plex API requests. A temporary URLProtocol
intercepted only two fabricated rating keys. One returned HTTP 200; the other
returned `URLError.networkConnectionLost` (-1005), including the API's failover
retry. No fabricated rating request reached PMS.

The app's existing offline simulation was enabled before enqueue, then disabled
to trigger reconnect. Subsequent drain calls were deliberately requested by the
harness to test the three-attempt budget; this was not a timing reproduction of
three naturally occurring reconnections.

| Phase | Stored rows | Pending count | Unacknowledged row |
| --- | ---: | ---: | --- |
| Offline enqueue | 2 | 2 | Pending, zero retries |
| First drain, interrupted after one acknowledgment | 1 | 1 | Pending, retry 1 |
| Second failed drain | 1 | 1 | Pending, retry 2 |
| Third failed drain | 1 | 0 | **Failed, retry 3** |
| Transport restored; drain requested | 1 | 0 | **Still failed, no replay** |
| Explicit reset-to-retry and drain | 0 | 0 | Acknowledged and removed |

The successfully acknowledged row was not replayed again. The other row was
preserved, but excluded from automatic pending replay until explicitly reset.
The owning defect is that `replayMutation` reduces errors to Bool and
`drainQueue` increments the same failure budget for transport and permanent
errors. Fix classification at that boundary, preserve transport-blocked work,
and coalesce recovery drains. A pending count of zero does not currently prove
that all stored changes were uploaded.

This validates local replay/persistence behavior with controlled responses. It
does not validate PMS-side mutation convergence, acknowledgment loss after a
real server commit, process-relaunch recovery, multiple failing servers, or a
three-day soak.

## Next implementation order

1. Preserve transport-blocked pending mutations without exhausting the semantic
   failure budget; keep successful acknowledgment as the deletion condition.
2. Make streaming progress reflect consumed media during starvation, then use
   bounded rebuffering for a live stream before rebuilding it.
3. Use the existing work owners to defer discretionary sync and download work
   while playback lacks reserve; rerun the constrained workload comparisons.
4. Retain cumulative missing-frame diagnostics so short repeated gaps cannot
   hide behind a zero-underrun count.

These experiments do not prove battery savings. Physical radio/energy and the
original iPad's iOS 27 behavior remain separate validation.

## Evidence and cleanup

- [Measurements](artifacts/2026-09-07-root-cause-simulator/measurements.json)
- [Focused logs](artifacts/2026-09-07-root-cause-simulator/evidence.txt)
- [Temporary instrumentation](artifacts/2026-09-07-root-cause-simulator/instrumentation.patch)
- Local runners, proxy, raw logs, private app baseline, and provenance:
  `/tmp/ensemble-network-audit/`.

The saved patch includes all experiment modes; the isolated-workload build
preceded the clock sampler, mutation harness, and optional callback suppression.
Build hashes for both passes are saved alongside the measurements. Instrumentation
was removed from app source after the experiments. No production fix is included.

The restored-source app rebuilt successfully and was reinstalled; the dedicated
simulator was shut down and the proxy stopped. Playback was paused at the end
of each audio trial. The original simulator and global network settings were
not changed.

The [gap-free check](artifacts/2026-09-07-root-cause-simulator/check_gap_free.py)
passed for the quiet control and failed as expected for both sync trials and
the retained-stream trial. It requires completed instrumentation and actual PCM
counters, so a missing log cannot produce a false pass. Example after repeating
a run with the saved local runner and instrumented build:

```sh
python3 /tmp/ensemble-network-audit/run.py isolate-sync sync 48000 0
python3 docs/investigations/artifacts/2026-09-07-root-cause-simulator/check_gap_free.py /tmp/ensemble-network-audit/isolate-sync/session.log
```

The saved baseline currently fails that check with 37,230 missing frames. All
four mutation phase assertions matched the table above. No package test suite
was needed for the documentation-only delivery.
