# Offline download follow-up

September 8, 2026. Starting commit `91c8841a`, physical iPhone 16 Pro on
iOS 27.0 (24A5430a), plus the dedicated iPad A16 simulator
`08CA3DD8-D174-40E9-A361-62B95671B969` on iOS 26.5 (23F77).

## Connection losses: missing download intent

Original-file downloads used the playback file URL without `download=1`.
Adding that flag eliminated the reproduced concurrent-transfer failures in two
four-track phone runs. The fix lives in the Plex URL builder and every direct
branch of the provider's download resolver. Playback URLs remain unchanged;
universal transcodes and two download workers remain supported.

The evidence isolates the request's download intent, not a failure in the
byte-range validator. It does not establish the internal PMS/iOS mechanism or
prove every possible connection loss has the same cause. The
[Python PlexAPI download implementation](https://github.com/pushingkarmaorg/python-plexapi/blob/master/tools/plex-download.py)
also uses `download=1` on file-part URLs. A live curl request with the flag
returned HTTP 206 and the requested 65,536 bytes.

| Phone experiment | Observation |
| --- | --- |
| Same-file transport matrix, two advertised local paths | 18/18 succeeded across ResumableDownload, raw AsyncBytes, and native file downloads, at concurrency 1 and 2 |
| Shared/default-cache/slow-progress variants on previously failing file | 9/9 succeeded; deliberately awaiting progress for 300 ms did not reproduce failure |
| Actual queue, four different tracks, two workers | Three early `-1005` failures; 3/4 completed in 45 seconds |
| Actual queue, one worker | 4/4 in about 13 seconds, no connection losses; existing partials limit throughput comparison |
| Repeat with two workers | Four `-1005` failures; 3/4 completed within the test window |
| Separate ephemeral sessions, fresh files | Still failed; one captured connection loss |
| Native file API through actual queue | Still failed on the first three tracks |
| Distinct client identities, fresh files | Still failed on the first three tracks |
| Existing transport plus `download=1`, fresh files | 4/4 in 11.9 seconds, zero connection losses |
| Production URL builder, deliberate pause/resume | 4/4 in 13.1 seconds including the pause, zero connection losses; two successful HTTP 206 resumes |

The final run retained 24,510,464 and 22,544,384 bytes across cancellation:
**47,054,848 bytes reused**. All four installed files, totaling 233,260,279 bytes,
were copied back and SHA-256 checked against fresh server downloads; all matched.
Expected cancellation errors are separate from transport failures in the evidence.

The slow local path took roughly 12–27 seconds per 40.6 MB transfer; the faster
path took 0.7–3.4 seconds depending on API/concurrency. The advertised remote
path was unreachable from the Mac. Neither cellular nor a remote phone path was
tested; Wi-Fi remained enabled for Device Hub access.

## Quality replacement behavior

- Changing the preference affects newly created downloads. Reconciliation no
  longer promotes existing rows or changes their pending requested quality.
- Existing cached files continue to count toward available tracks and storage
  while a replacement is pending, running, paused, or failed. Rows report the
  installed file's quality rather than the replacement's requested quality.
- The download manager offers **Cancel File Replacements**, restoring completed
  metadata for validated existing files while preserving manual pause and new
  work. It skips legacy paths whose quality cannot be inferred.
- Paused/offline queues no longer request unnecessary continued-processing
  grants. Manual Resume still requests a grant when work is eligible.

The phone UI cancelled 120 outstanding replacements without removing cached
files. On the final clean build, changing High → Original → High created no
replacement work; reconciliation logged `newPending=0`. Downloaded counts stayed
available and the manager showed 6.08 GB on disk. Previously completed upgrades
remain installed: this does not restore the original pre-investigation storage
footprint. No download target was removed during this follow-up.

## Offline persistence and acknowledgment recovery

A focused test ages a pending rating by 72 hours, migrates its CoreData store to
SQLite, removes/reopens that store, and recreates the replay coordinator. Twelve
offline drains make zero provider calls. Four transport failures after server
acceptance leave the record pending with zero permanent retries. Restoring
acknowledgment clears the row and leaves the accepted rating unchanged.

A separate provider test exposed and fixes duplicate playlist appends after a
lost acknowledgment. Replay reads authoritative server membership and appends
only missing tracks. Incomplete membership responses are rejected before any
append. The live playlist response used to check this contract reported all
243 items with `size=243`. Tests use a model server; fabricated mutations were
not sent to a real playlist.

This protects rating assignment and ordinary append replay; it is not a general
exactly-once guarantee. Concurrent external playlist writers can still race the
membership read, and non-idempotent operations such as creation/play-count
reporting need their own server-supported acknowledgment strategy.

The final signed simulator build launched offline at 07:55:03, relaunched offline
at 07:57:01, and reconnected at 07:57:51. Cached Downloads remained visible; health
probes, WebSocket startup, and startup sync deferred while offline. Reconnection
opened the three server WebSockets and completed startup sync at 07:58:01.
The existing simulator mutation queue was empty; lost-ack behavior is established
by the SQLite/provider tests above, not this UI run. Connectivity was simulated
at the app policy layer, not by disabling the physical radio.

## Network and power measurements

Stable Xcode 26.6 Power Profiler captured 60-second phone runs. In the fixed run,
CPU impact averaged 13.156 during seconds 10–55 and 0.892 during seconds 30–55,
after completion. Thermal state remained Nominal. These are model impact scores,
not CPU percentages, watts, or battery percentage consumed.

The fixed trace attributed 173,272,707 received bytes and 227,416 sent bytes to
Ensemble. That is less than the verified audio payload: attribution/sampling is
incomplete and must not be treated as total wire cost. The serial trace attributed
109,942,323 received bytes and 152,337 sent bytes, but its starting partials and
completed work differ. These traces do **not** establish a percentage energy or
bandwidth saving. The retained-byte measurement comes from the file transport,
not subtraction of profiler counters.

[Apple's Power Profiler guidance](https://developer.apple.com/videos/play/wwdc2025/226/)
explains that a connected Mac keeps device hardware awake and recommends on-device
capture for realistic background measurements. The phone was charging/connected.
A real 72-hour offline soak and untethered battery comparison remain unmeasured.
The next experiment should record matched on-device idle/offline/reconnect windows
with identical pending work, then repeat over 72 hours with a process termination
and a controlled lost response. Do not extrapolate this short session to three-day
battery life.

## Verification and reproducibility

- 73 focused Core tests, 31 API/transport tests, and 17 persistence tests passed.
- Final workspace builds passed for physical iPhone and exact simulator UUID.
  An initial unsigned simulator build trapped during CloudKit initialization;
  rebuilding with normal simulator signing resolved it without production edits.
- Final phone install and PID 67564 both identify bundle container
  `EF5C2E33-BCFC-49C4-89B7-8A0416556298`. The simulator installed executable hash
  matches its signed build. Incremental phone versions alone are insufficient
  provenance because Xcode retained the earlier build number.
- One-off transport/queue instrumentation was removed before the final builds;
  temporary credential-bearing Documents files were confirmed absent.
- Device Hub touch input stopped working late in testing; reopening Device Hub
  restored it and the final quality-picker interaction was directly observed.
  Nothing Playing was verified before sending Device Hub's Lock action.
  CoreDevice's lock query reports `passcodeRequired=false`, `unlockedSinceBoot=true`;
  those fields do not independently confirm the display's lock state.

[Sanitized artifacts](artifacts/2026-09-08-offline-download-followup/) include event
sequences, transfer matrices, file hashes, and power summaries. Run
`python3 docs/investigations/artifacts/2026-09-08-offline-download-followup/check.py`
to check the captured comparison. The optional queue instrumentation patch
requeues four existing fixture tracks, pauses/resumes, and pauses again; it must
only be applied to a deliberate test build with appropriate fixture IDs.
Raw traces, receipts, and private endpoint configuration remain under
`/tmp/ensemble-followup-20260908`; they are not committed.
