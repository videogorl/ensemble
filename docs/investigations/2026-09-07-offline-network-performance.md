# Offline and poor-network session audit

Investigated September 7, 2026. Diagnosis only; no production changes.

Inputs: Craft blocks `005EF20B-DEE5-481E-9DE5-1DD02290CCBF` (session questions) and
`62550860-9662-4F1A-A8FA-6B739D21A91D` (Network system questions), plus the two named
logs in `~/Library/Mobile Documents/com~apple~CloudDocs/Downloads/`.

## Evidence boundaries

- `session-2026-09-04-113711.log`: 15,483 lines, device iPhone12,8, iOS 26.6,
  recorded source `8e40f111f0d23712ed9a04b5ae59643768047053`.
- `session-2026-09-06-182425.log`: 4,015 lines, iPad13,9, iOS 27,
  build `202609021306.6050`, source commit unknown. This is a poor-network session,
  not a second continuous device-offline interval.
- Current checkout inspected at `c6bfb491`. The main lyrics, artifact queue,
  mutation, health, failover, and WebSocket owners are unchanged from the first
  log's source. Playback has subsequent changes; the iPad's exact source cannot
  be inferred from its build number.
- Ordinary lines carry time of day, not dates. Embedded UTC dates establish the
  multi-day span, including September 7 near line 12132. The first log records
  offline at line 428, 21:56:22, and online again at line 14276, 18:39:48.
  Do not manufacture continuous daily measurements from the gaps.
- These are application logs, not energy, CPU, memory, packet, or server-history
  traces. Counts below are recorded events, not battery estimates. No live
  playback reproduction or PMS mutation was performed.

## Three-day offline result

The core offline listening and queued-change path worked well in this recording.

| Recorded behavior | Result |
| --- | --- |
| Explicit file-backed first-audible events during offline interval | 21; median 448 ms, range 218–671 ms |
| SmartMix deck handoffs completed | 89 |
| Playback failed-state transitions / PCM underruns | 0 / 0 |
| Enqueued changes | 92 scrobbles, 3 playlist additions |
| Successful replay messages after reconnect | 92 scrobbles, 3 playlist additions |
| Replay timing | Drain starts 18:39:48.660; last success 18:39:58.457 |
| Endpoint probe starts / API failover attempts while device offline | 0 / 0 |

The log shows cached lyrics used 113 times across the session. Periodic sync and
network monitoring stop on background transitions. One waiting audio download
resumes after reconnect and stores a 5,172,077-byte file at 18:39:59.944.
No playback failure in the log is reassuring but does not prove absence of
unlogged glitches, memory growth, or a later crash.

## Improvements, in priority order

### 1. Stop network-dependent artifact repair at its scheduler while offline

The offline interval contains 4,391 transient lyrics pre-cache failures across
533 track keys, with some attempted 11 times. There are 4,435 locally blocked
Plex request messages. These are explicitly skipped requests, not 4,435 radio
transmissions. The lyrics failures and blocked requests alone occupy roughly
57% of the whole log.

Thirteen sweeps each enumerate 3,178 completed downloads while offline
(lines 496–13535). `OfflineDownloadService.runDownloadHealing()` always calls
`reconcileCompletedDownloadArtifacts()`, which re-enqueues every completed file.
The artifact worker waits for foreground idle time but has no network gate.
`LyricsService.fetchAndCacheLyrics()` also lacks the offline guard present in
the interactive lyrics path. Transient failure deliberately leaves the artifact
unresolved, so subsequent healing sweeps revisit it.

Suspend the existing network artifact queue until connectivity and the relevant
source allow work, retaining unfinished work for recovery. Keep local frequency
sidecar generation independently eligible. Gate before per-file preparation,
not just at the final HTTP call. Coalesce redundant healing requests and avoid
full-library reconciliation on every brief foreground activation. Preserve the
rule that transport failure must not become a durable "no lyrics" result.

Also avoid requesting continued background processing solely because paused
work exists: 22 one-track requests were submitted during the offline interval.
`handleAppDidEnterBackground()` requests execution before applying network
policy. Request it only for runnable transfers, and finish/cancel it when policy
prevents progress. A submitted request does not prove the OS executed it.

### 2. Share server recovery and enforce failed-endpoint cooldowns

The iPad log contains 526 endpoint probe starts in approximately 13 minutes,
including 182 in the 18:25 minute. It records 99 selection starts: 85 with
`context=unknown`, 14 with `context=local`; 99 API failover attempts and 14
in-flight selection reuse messages. Thus repeated request recovery, not merely
the periodic health timer, is the larger problem.

Current contributing paths:

- `ServerHealthChecker` and individual API clients own separate
  `ConnectionFailoverManager` instances, so their in-flight work/cooldowns are
  not shared across those owners.
- `PlexAPIClient.attemptFailover()` omits network context, taking `.unknown`.
- `filterByRecentTransportFailures()` returns all endpoints again when every
  candidate is cooling down. The iPad log records this escape nine times.
- Playback's `SyncCoordinator.refreshConnection()` reaches
  `ServerConnectionController.refreshConnections()`, which loops every server,
  including servers unrelated to the failing track.

Reuse one recovery selection per account/server and network generation, pass
the real path context, and scope playback recovery to the track's server.
When all endpoints fail, defer ordinary retries until a bounded backoff expires;
permit one explicit user retry or meaningful path change to bypass it.
Stage the last working endpoint before fanning out alternatives. Preserve both
valid direct-file and universal-transcode paths.

Do not wait *only* for cellular/Wi-Fi changes: a server can recover while the
phone stays on the same Wi-Fi. Combine path changes, actual request outcomes,
explicit retry, and bounded retry only while useful work is waiting. Avoid
all-endpoint sweeps for every request or every path callback. Increasing every
timeout would prolong these overlapping failures without fixing their owner.

### 3. Make WebSocket availability truthful

The notification mechanism inspected here is Plex WebSockets, not a webhook
receiver. The iPad does receive 39 activity events, so notifications are not
universally broken. It also records 13 scheduled reconnects. The offline phone
shows no reconnect loop after the offline transition and reconnects both enabled
servers when Wi-Fi returns.

However, `PlexWebSocketCoordinator.setupAndStartManager()` inserts a server into
`connectedServerKeys` immediately after `manager.start()`. That only launches
the socket; `WebSocketSessionDelegate.didOpen` logs the real handshake but does
not publish it to the coordinator. Transport close/error likewise does not
directly remove this optimistic connected entry. "WebSocket active" can
therefore relax polling to four hours without a working notification connection.

Publish established/closed state from the existing delegate, clear it on loss,
and base per-server fallback polling on that state. Keep the existing reconnect
backoff/circuit breaker. Do not add another heartbeat/probe loop by default.
The account UI separately renders `connectionState` and `syncStatus`; label a
previous sync failure as such instead of presenting it as a contradictory
current connection verdict. Give server recovery an explicit Retry action.

### 4. Protect pending changes when reconnect is incomplete

All 95 logged changes reported successful replay. There is no logged failed
replay in this session. This proves the observed replay path, not independently
verified server history or final CoreData queue deletion.

Current `MutationCoordinator.drainQueue()` has several robustness gaps:

- Replay returns only Bool, discarding transport versus permanent-error detail.
  Any failure consumes the three-attempt budget and can mark a row failed.
- Five consecutive failures stop the entire queue, potentially blocking another
  reachable server. A failed earlier mutation can also be followed by a later
  dependent mutation on the same playlist.
- Connectivity is checked only before draining. The loop does not stop explicitly
  on path loss/cancellation; backoff uses `try? Task.sleep`.
- Triggers are connectivity, foreground, optimistic playlist add, and manual
  retry. Recovery of a server on unchanged Wi-Fi does not itself trigger replay.
- Each row re-fetches the whole pending list to check membership. Successful
  deletion uses `try?`, so a persistence failure could leave an acknowledged
  action queued for replay. Do not claim exactly-once delivery.

Retain transport failures as pending, pause that server's ordered work, continue
independent reachable servers, and resume on verified server recovery with
bounded backoff. Preserve per-playlist ordering and distinct scrobble events.
Propagate persistence failure instead of silently treating queue removal as
done. Add a drain summary with acknowledged/remaining/failed counts and elapsed
time. An ID-specific current-row lookup can replace repeated whole-queue fetches
without losing source-removal protection.

Scrobble payloads retain track/source, but no play timestamp; repository creation
time is not passed through `PendingMutationRecord` or the replay API. Successful
replay must not be described as proof that original listening dates survived.
Verify Plex's historical-event support before promising that contract.

### 5. Rebuffer without immediately rebuilding a live stream

"Downstairs" has four PCM underruns. Each reports a running HTTP 200 stream,
zero buffered PCM, and 1.78–4.31 seconds since the last received byte. This
supports delivery starvation rather than a missing track or universal-transcode
incompatibility. Its first start took 4.4 seconds; later starts took 6.6, 10.0,
and 15.3 seconds. Medium quality was selected but still encountered starvation
and subsequent connection/timeout failures. These are playback failures; this
log does not establish a process crash.

The engine promotes about a second of missing render frames into its error
recovery path. Prefer a bounded buffering state that retains an otherwise live
pipeline and resumes after a useful PCM reserve accumulates. Rebuild/fail over
only after a real transport failure or a bounded no-progress timeout. Prioritize
audible playback over next-track preloading, bulk downloads, artwork, and
recovery probes. Measure startup delay versus rebuffer count on the exact bad
network before selecting thresholds; bytes alone do not distinguish weak Wi-Fi,
server stalls, and contention.

## Low Data Mode, native APIs, and remaining Craft questions

Low Data Mode is explicitly detected at 18:33:08.723, after the reported 18:32
settings change. The transfer is cancelled at 18:33:09.859 and recovery records
become paused. This is consistent with the current `isConstrained` download
policy, though the old log lacks a reason-coded policy transition. Another 51
endpoint probes start after detection, so this did not suppress general recovery.

No new package is needed. Ensemble already uses `NWPathMonitor`, `URLSession`,
and `URLSessionWebSocketTask`. Apply native constrained/expensive-network policy
to discretionary transfers and retain user-directed playback policy separately.
Apple documents `allowsConstrainedNetworkAccess=false` plus
`waitsForConnectivity=true` for deferring discretionary work. Waiting applies
to connection establishment; it does not fix an established stream dropping.
Sources: [Low Data Mode policy](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowsconstrainednetworkaccess),
[waiting for connectivity](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity),
[path monitoring](https://developer.apple.com/documentation/network/nwpathmonitor).

The iPad log has no identified audio-share start/success/failure event. Current
`ShareActions` already shows preparation/failure toasts, but its preparation
toast depends only on `localFilePath != nil`, while the service may still need
network data for a quality mismatch. Use actual resolved work to show persistent,
cancellable progress and an error, with start/end diagnostics. A bounded
background execution window can protect an explicitly initiated export; it
does not explain or fix missing progress UI. The reported background task banner
after force-close cannot be diagnosed conclusively from this app-only log.

## Focused validation for implementation

1. Offline artifact queue with many unresolved lyrics: no provider calls while
   offline, local sidecars still eligible, pending work resumes once eligible.
2. Concurrent failures for one server: shared selection; no new sweep during
   cooldown; explicit retry/path change permits one; other servers unaffected.
3. Socket handshake failure/close: never falsely counts as available and restores
   fallback sync eligibility.
4. Pending mutations: transport loss preserves rows/retry budget and ordering,
   another server drains, unchanged-Wi-Fi server recovery resumes, deletion
   failure is visible.
5. Rate-limited live stream: buffering preserves position/pipeline; recovery is
   bounded and nonessential requests do not compete. Validate physical playback
   separately from unit checks.

For baseline counts, the audit ran Python over each named file using exact event
substrings, splitting the first log at `NetworkMonitor: State changed to Offline`
and its following `State changed to Online`. Probe counts require both
`ConnectionTest` and `Testing...`, avoiding double-counting completion messages.
First-audible timing uses `event=firstAudibleRender` and its `elapsedMs` field.
No production test/build was needed for this documentation-only audit.
