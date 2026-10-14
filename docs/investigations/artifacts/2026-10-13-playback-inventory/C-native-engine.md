# C. Native engine inventory (read-only)

Scope: `Packages/EnsembleCore/Sources/Services/`. Short names used in citations:
`Engine` = AudioPlaybackEngine.swift, `Service` = PlaybackService.swift, `Transport` = PlaybackTransportCoordinator.swift,
`Startup` = PlaybackStartupCoordinator.swift, `Launch` = PlaybackLaunchCoordinator.swift, `StateMachine` = PlaybackSessionStateMachine.swift,
`AudioSession` = PlaybackAudioSessionCoordinator.swift, `Prefetch` = PlaybackPrefetchController.swift, `Source` = PlaybackSource.swift,
`LocalFile` = PlaybackLocalFilePolicy.swift, `FileCache` = PlaybackResolvedFileCache.swift, `CacheIdentity` = PlaybackStreamCacheIdentity.swift,
`ArtifactCache` = PlaybackArtifactCache.swift, `Pipeline` = StreamingAudioPipeline.swift, `PCMBuffer` = StreamingPCMBuffer.swift,
`Automation` = AutomationSupport.swift.

Nothing was built, run or modified. All findings are from reading code; none were exercised at runtime.

Facts that frame everything below:

- `PlaybackService` is a plain `NSObject` class, not actor-isolated (Service:258); individual methods carry `@MainActor`. The package is tools-version 5.9 with no concurrency settings (Package.swift:1), so un-annotated `async` methods run off the main thread.
- `AudioPlaybackEngine` has no isolation annotation, no lock and no `Sendable` conformance (Engine:25). Only three methods are `@MainActor` (Engine:1023, 1048, 1178). Everything else is main-thread by convention only.
- `PlaybackService` is the only production owner of the engine (Service:985, 1378); the only other reference is `Tests/AudioPlaybackEngineStreamingTests.swift`.

---

## 1. Per-file summary

Stored-state counts are mutable stored properties (approximate for the two large files).

| File | Lines | Actual responsibility | Mutable stored state | Created/owned by | Called by |
|---|---|---|---|---|---|
| AudioPlaybackEngine.swift | 2,551 | AVAudioEngine graph: two player-node decks + one streaming source node, gapless FIFO, SmartMix crossfade execution, AUSoundIsolation, wall-clock progress, route-change self-recovery, encoder-delay parsing | ~48 (incl. 9 callback slots, Engine:34-35, 222-238) | `Service.setupPlayer` (Service:1378), held in `audioEngine` (Service:985); destroyed in `cleanup` (Service:6948-6949) | Service only |
| PlaybackTransportCoordinator.swift | 422 | Decide and build a `PlaybackSource` for a track; dedupe in-flight resolutions; cache stream decisions; own prefetch download pipelines until the engine adopts them | 3 dictionaries + `NSLock` (Transport:26-33) | Service lazy property (Service:1148-1198) | Service (resolve 5142, 5153; evict 4920, 5104, 5269, 5693; clear 3430, 6956; discard 4647, 5409, 5415; take 5796, 5836; cancel 6629) |
| PlaybackStartupCoordinator.swift | 113 | Launch-restore gate (`pending/restoring/ready/failed`) and a pure "what to restore" decision | 1 (Startup:34) | Service init (Service:1332) | Service (2674, 7046, 7082-7158) |
| PlaybackLaunchCoordinator.swift | 112 | Sequence "visualizer plan → loadAndPlay → recovery seek → prefetch" through closures back into the service; static visualizer priority policy | 0 (closure bag, Launch:26-34) | Service lazy property (Service:1199-1225) | Service (4892; `visualizerPlan` via Service:1227) |
| PlaybackSessionStateMachine.swift | 110 | Stateless namespace of pure helpers: request struct, retry predicate, error classification, cancellation test, seek-time validation. Not a state machine | 0 | n/a (caseless enum, StateMachine:4) | Service (4800, 4882, 4901-4966, 5108, 5677), Transport (98, 101), Prefetch (125) |
| PlaybackAudioSessionCoordinator.swift | 205 | AVAudioSession category/activation and interruption/route notification subscription; no-op on macOS | 3 (AudioSession:14-16) | Service init (Service:1331) | Service (2067, 2090, 2101, 2110, 2118, 2129, 5723) |
| PlaybackPrefetchController.swift | 248 | Mixed: pure gapless/SmartMix timing predicates, two retry/defer memos, pass-throughs to `PlaybackResolvedFileCache`, stream-cache trim | 2 tuples (Prefetch:14-15) | Service init (Service:1328) | Service (4222, 4606-4689, 5349, 5401-5422, 5507, 5594, 5687, 6915) |
| PlaybackSource.swift | 85 | Value types: `PlaybackSource` (4 cases) and `PlaybackSourceMetadata` | 0 | Transport (Transport:182-346), Service (4859) | Engine (1024), Launch (89), Service |
| PlaybackLocalFilePolicy.swift | 88 | Static local-file checks: container sniffing, `.m4a`→`.mp3` alias creation, invalid-payload test, truncation thresholds | 0 (but writes/deletes files, LocalFile:18-26) | n/a | Service (1154, 1157, 4871-4874, 5286, 5492-5495) |
| PlaybackResolvedFileCache.swift | 110 | LRU map trackID→file URL plus an in-flight prefetch set | 3 (FileCache:8-10) | Service init (Service:1333) | Service directly (3445, 5465, 5471, 6556, 6955) and through Prefetch (153-217) |
| PlaybackStreamCacheIdentity.swift | 45 | Cache directory path and file-name encode/match for track identities | 0 | n/a | Engine (1084-1085), ArtifactCache (49, 63, 216), Prefetch (221) |
| PlaybackArtifactCache.swift | 303 | On-disk manifest store for completed stream downloads: lookup, record, trim to 1 GiB budget | 1 instance + 1 static set, static `NSLock` (ArtifactCache:39-46) | `shared` singleton (ArtifactCache:37), injected into Service/Transport/Prefetch (Service:1097, 1197, 1328) | Transport (195, 400), Engine (1082), Pipeline (584), Prefetch (243-246) |
| StreamingAudioPipeline.swift (surface only) | 705 | One HTTP download → growing cache file → decoder → PCM ring buffer; also resolves to a finished file URL | ~36 behind `stateLock` (Pipeline:196-222) | Engine (1091) or Transport (397) | Engine (render 1144; start 1255; cancel 1285), Transport (407, 413) |

---

## 2. Native engine command surface

All are synchronous unless marked. "Main (convention)" means the method touches unguarded engine state and AVAudioEngine nodes and has no annotation.

### 2a. Commands (17)

| # | Method | Engine line | Parameters | async / throws | Threading | Service call sites |
|---|---|---|---|---|---|---|
| 1 | `setup()` | 245 | none | throws | Main (convention); registers config-change observer (282) | 1380 |
| 2 | `load(fileURL:trackId:playbackGeneration:)` | 964 | URL, String, UInt64 = 0 | throws | Main (convention) | 6041 (restore pre-buffer; passes no generation, so 0) |
| 3 | `load(source:trackId:playbackGeneration:preparedPipeline:)` | 1024 | `PlaybackSource`, String, UInt64 = 0, `StreamingAudioPipeline?` | async throws | `@MainActor`; suspends until first format for streams (1115) | 5792, 5832 |
| 4 | `play(from:)` | 1779 | TimeInterval = 0 | throws | Main (convention) | 5856 |
| 5 | `pause()` | 1857 | none | no | Main (convention) | 1550, 2351, 2354, 3537, 3726, 3772, 4826, 4996, 5006, 5134, 6537, 6841 |
| 6 | `resume()` | 1881 | none | throws | Main (convention) | 3308, 3353, 6888 |
| 7 | `stop()` | 1913 | none | no | Main (convention) | 3357, 3876, 4734, 4769, 5731, 5748, 5799, 5806, 5813, 5839, 5878, 5888, 6244, 6252, 6842, 6948 |
| 8 | `seek(to:)` | 1935 | TimeInterval | throws (`streamingSeekUnavailable` for streams, 1938) | Main (convention) | 3912, 6052 |
| 9 | `adoptPlaybackGeneration(_:)` | 1773 | UInt64 | no | Main (convention) | 3307, 3352, 6887 |
| 10 | `scheduleNext(fileURL:trackId:)` | 1367 | URL, String | throws | Main (convention) | 5624, 5662 (inside `@MainActor` helper 5372) |
| 11 | `scheduleSmartMixNext(fileURL:trackId:plan:)` | 1401 | URL, String, `SmartMixPlan` | throws | Main (convention); starts the incoming deck immediately (1462) | 5608 |
| 12 | `acceptSmartMixIncomingTrack()` | 1496 | none | no | Main (convention) | 3628 |
| 13 | `cancelSmartMixTransition(continueIncoming:)` | 1502 | Bool = false | no | Main (convention) | 3895, 4216, 4300, 4339 |
| 14 | `clearScheduledFiles()` | 1685 | none | no (swallows `engine.start` failure, 1753) | Main (convention) — but called off-main, see §7 | 3144, 3536, 3725, 3771, 3875, 4230, 4340, 5436, 5444, 5763, 6553, 6645 |
| 15 | `removeScheduledTrack(_:)` | 1670 | String | no | Main (convention) | 1486 (unreachable, see §7) |
| 16 | `setIsolationEnabled(_:)` | 777 | Bool | throws | Main (convention); first enable stops and rewires the graph (796-863) | 3995 |
| 17 | `prepareForRouteChange()` | 433 | none | no | Main (convention) | 2476 |

Not called by the service: `startStreamingPipeline(...)` (Engine:1179, `@MainActor async throws`) is internal to `loadStreamingSource` (Engine:1115) and used directly by tests.

### 2b. Synchronous queries the service reads (20)

| Query | Engine line | Service use |
|---|---|---|
| `currentTime()` (has a side effect: updates durable position, 2008) | 1997 | 1685, 5847 |
| `currentTimeSubject.value` | 180 | 2358, 3354 |
| `isCurrentProgress(_:)` | 1766 | 1510 |
| `currentTrackId` | 75 | 1706, 2357, 3295, 3305, 3394, 3945, 5227, 6017 |
| `playbackRequestGeneration` | 77 | 5799, 5806, 5839, 5878 |
| `fileDuration` | 79 | 978, 6046 |
| `progressRevision` | 179 | 7035 |
| `isTrackScheduled(_:)` | 1328 | 5381, 5460, 5510, 5561 |
| `scheduledTrackIds` | 1333 | 4677, 5330, 6640, 6914 |
| `scheduledTrackIdsInOrder` | 1338 | 1526, 4221, 5402, 5443 |
| `isSmartMixTransitionActive` | 1342 | 1527, 1711, 3615, 4215, 5327, 5380, 5550 |
| `smartMixIncomingTrackId` | 1346 | 1514, 3616 |
| `smartMixTransitionElapsed` | 1350 | 3626 |
| `smartMixSkipThreshold` | 1355 | 3627 |
| `hasPromotedSmartMixTransition` | 1359 | 1513, 3895, 4217, 4300, 4339 |
| `isStreamingSourceActive` | 94 | 1487 |
| `currentPlaybackFileURL` | 95 | 5159, 5228 |
| `currentPlaybackFileIsComplete` | 96 | 5244 |
| `currentPlaybackSampleRate` | 97 | 5258 |
| `isRunningForDiagnostics` | 92 | 4753, 5717 |

Also read as constants: `instrumentalIsolationPreferredIOBufferDuration`, `standardPreferredIOBufferDuration` (Engine:67-68; Service:3990-3991).

The query count matters for the contract: the service pulls engine state 20 different ways instead of receiving it in events. Most would have to become event payload or reducer-held state.

---

## 3. Native engine event surface

Ten outbound channels: nine closure slots and one Combine subject. No delegate protocol, no async streams, no outbound notifications. The engine also consumes one notification internally.

"Token" column: `gen` = the engine's `playbackRequestGeneration` at the moment the closure fires (not at the moment the work was scheduled).

| Channel | Engine decl / fire sites | Payload | Fires on | Token carried | Service handler |
|---|---|---|---|---|---|
| `onPlaybackComplete` | 222; fired 2294, 2353, 2308, and synchronously inside commands at 1732, 1805, 1958 | gen | Main | gen only, no track id | 1387-1405 (sync gen check, then `Task @MainActor` → `handleQueueExhausted` 1739) |
| `onTrackAdvance` | 224; fired 2284, 2346 | newTrackId, gen | Main | gen + track id | 1407-1412 (extra `main.async` hop, gen check) → `handleEngineTrackAdvance` 1600 |
| `onSmartMixPromote` | 226; fired 1597 | newTrackId, gen | Main | gen + track id | 1414-1419 → `handleSmartMixPromotion` 1665 |
| `onSmartMixTransitionActiveChanged` | 228; fired 1481, 1524, 1632 | Bool, gen | Main | gen | 1421-1428 |
| `onFirstAudibleRender` | 230; fired 1150 (stream, hop from render thread) and 1841 (file, synchronous inside `play`) | trackId, gen | Main | gen + track id | 1430-1445 (moves `.loading/.buffering` → `.playing`) |
| `onBufferedProgress` | 232; fired 1221 | trackId, gen, 0…1 | Decoder queue → main hop (1218) | gen + track id + pipeline identity check (1220) | 1458-1469 |
| `onStreamingFileComplete` | 234; fired 1101 | URL, `PlaybackArtifactKey`, duration?, gen | URLSession delegate queue, no hop (Engine:1100-1106; Pipeline:523) | gen passed but ignored by the handler | 1471-1477 (`Task @MainActor`, caches URL by `key.trackIdentity`) |
| `onStreamingBufferPressureChanged` | 34; fired 2062 (from 1111, 1290, 2074) | Bool | Main | none | 1447-1451 (sync, no checks) |
| `onStreamingRebufferingChanged` | 35; fired 2078, 2087 | Bool, gen | Main (10 Hz timer) | gen | 1452-1456 (sync) |
| `onError` | 238; fired 503, 557, 1249, 2083 | Error, trackId? (always `nil`), gen | Main | gen | 1479-1501 |
| `currentTimeSubject` | 180; sent 2118 | `Progress{time, trackID, generation, revision}` (171-176) | Main; sink adds `.receive(on: main)` hop | generation + revision + track id; validated by `isCurrentProgress` (1766) | 1504-1540 |

Plus synchronous `throws` from commands 1-4, 6, 8, 10, 11, 16 (§2a), which are the only way load/play/resume/seek failures are reported.

### How each required signal is reported today

- **Progress / time.** A 10 Hz `DispatchSourceTimer` on the main queue (Engine:2041-2042). For files it is a wall-clock estimate from a captured base, not the render clock (2049-2052). For streams it is `consumedFrames / sampleRate` from the ring buffer (2067). Published through `currentTimeSubject` (2118). The service sink drops ticks unless `playbackState == .playing`, generations match, revision matches and track id matches (Service:1508-1510, 1519). The same sink is the service's heartbeat: it also runs engine/UI reconciliation, the gapless trigger, the end-transition lease, snapshot persistence and Plex progress reporting (Service:1512-1539).
- **Natural end.** `onPlaybackComplete(gen)`. File: the `scheduleSegment` completion handler hops to main and calls `handleSegmentComplete`; with an empty FIFO it fires completion (Engine:2286-2294). Stream: two triggers, both guarded by `streamingCompletionNotified` — the render block seeing `read == 0 && isComplete` (1154-1158) and the timer seeing `position >= fileDuration` (2069-2071). The event carries no track id.
- **Gapless transition to a pre-scheduled item.** `onTrackAdvance(newTrackId, gen)` from `handleSegmentComplete` / `handleScheduledFileComplete` when `scheduledFiles` is non-empty (Engine:2256-2285, 2325-2347). The engine has already swapped `currentTrackId`, duration and time base before the callback. The service also has a polling backstop: every progress tick compares `engine.currentTrackId` to its own track and synthesises an advance (Service:1705-1718).
- **SmartMix/crossfade.** `onSmartMixTransitionActiveChanged(true)` at start (1481), `onSmartMixPromote(trackId)` at the midpoint (1550-1552, 1597), `…ActiveChanged(false)` at finish or cancel (1524, 1632). Backstop poll in the progress sink (Service:1512-1517).
- **Stall / buffer underrun.** Streams only. The timer polls `RenderProgress.isRebuffering` (Engine:2075) and fires `onStreamingRebufferingChanged(true/false)` (2078, 2087). After 30 s (Engine:38) it fires `onError(.streamingUnderrun)` (2080-2083). A separate low-reserve hysteresis (3 s / 8 s, Engine:36-37, 2074) fires `onStreamingBufferPressureChanged`, which the service uses only to throttle other network work (Service:1447-1451). File-backed playback has no stall signal.
- **Errors.** Asynchronous: `onError` for route-recovery failure (503, 557), pipeline failure after startup (1249, skips `NSURLErrorCancelled` at 1237) and underrun timeout (2083). The service routes streaming errors to `recoverCurrentStream` (Service:1487-1492, 1546) and everything else to `.failed` (1494-1498). Synchronous: thrown from commands. `streamingSeekUnavailable` is control flow, not a failure (Engine:1938 → Service:3920-3934 restarts the stream at the target time).
- **Route / config changes.** Three separate paths, none of them an engine event:
  1. `AVAudioSession.routeChangeNotification` → AudioSession:47-55 → `Service.handleAudioSessionRouteChange` (2452) → `engine.prepareForRouteChange()` (2476). iOS-family only (AudioSession:36).
  2. `AVAudioEngineConfigurationChange` → engine-internal observer (Engine:282-290) → `handleConfigurationChange` (462). The engine restarts itself and reschedules; success is silent, failure goes to `onError`.
  3. `AVAudioSession.interruptionNotification` → AudioSession:37-45 → `Service.handleAudioSessionInterruption` (2406).

---

## 4. Gapless and SmartMix scheduling

**Who decides.** The service decides what and when; the engine only executes.

- Trigger: every progress tick calls `scheduleGaplessIfNeeded` (Service:1521, 5326), which fires when nothing is scheduled, no request is in flight and ≤ 20 s remain (Prefetch:59-68). Also triggered after launch (Launch:110), after each advance (Service:1659, 1699) and after queue invalidation (4231-4233).
- `prefetchUpcomingItems(depth: 2)` (Service:5386) only ever prepares the first upcoming index (5408-5414). It resolves or downloads the file (5480-5485), probes for truncation (5491-5500), then picks SmartMix or plain gapless.
- SmartMix choice: enabled + current file cached + `shouldUseSmartMix` (Prefetch:70-84) → analyse both files → `SmartMixPlanner.plan` (Service:5566) → if not yet time, record a deferral (5589-5601; Prefetch:105-111) and return; otherwise `engine.scheduleSmartMixNext` (5608).
- Final guard before any schedule call: still the next upcoming track, no SmartMix active, not already scheduled (Service:5372-5384).

**How the engine pre-schedules.**

- Gapless: `scheduleNext` appends a `scheduleSegment` to the active `AVAudioPlayerNode` FIFO, trimmed to encoder-delay bounds, without bumping `scheduleGeneration` (Engine:1367-1399). On the current segment's completion the engine swaps its own current-track fields and fires `onTrackAdvance` (2256-2285).
- SmartMix: `scheduleSmartMixNext` is "start now", not "schedule" — it starts the second deck immediately (1446-1462), clears the gapless FIFO tracking (1431) and runs a 50 ms fade timer (1528-1539). Midpoint promotes the incoming track to current (1582-1599); end swaps `activePlaybackDeck` (1617). It silently falls back to `scheduleNext` when nothing is playing, formats differ or the start offset is past the end (1403-1427).
- Gapless is file-to-file only. `scheduleNext` writes to the player node, but a streaming current track renders through the source node and never starts the player node (1781-1793, 1887-1894); stream end fires `onPlaybackComplete` without consulting `scheduledFiles` (2298-2309). A streamed track therefore always ends with a full reload of the next item.

**State split.**

| Held in engine | Held in service / coordinators |
|---|---|
| `scheduledFiles` FIFO with open `AVAudioFile`s (Engine:123) | Queue, index, repeat mode, SmartMix preference |
| `scheduleGeneration` (117) | `gaplessScheduleRequestTask` (Service:5331) |
| `smartMixTransition`, `activePlaybackDeck`, fade timer (165-167) | SmartMix deferral and failed-prefetch memos (Prefetch:14-15) |
| Current file, content bounds, time base (73-110, 204) | Resolved file URLs + in-flight set (FileCache:8-10) |
| | Prepared download pipelines (Transport:33) |

**What happens to scheduled items.**

| Trigger | Behaviour | Citation |
|---|---|---|
| Skip next / previous / jump | Service calls `clearScheduledFiles()` then `pause()`, then a full load. `clearScheduledFiles` cancels SmartMix, stops the node to flush the FIFO, re-anchors the current track and bumps the generation | Service:3144, 3536-3537, 3725-3726, 3771-3772; Engine:1685-1762 |
| Skip during SmartMix | If elapsed < plan threshold, accept the incoming track in place; otherwise normal skip | Service:3613-3635; Engine:1496-1500 |
| Seek (file) | SmartMix cancelled (kept if already promoted); node stopped; current rescheduled from target; all `scheduledFiles` rescheduled under the new generation | Engine:1936, 1947-1978 |
| Seek (stream) | Throws; service restarts the stream at the target time, which clears the schedule on load | Engine:1938; Service:3920-3934, 5763 |
| Queue edit | `invalidateGaplessSchedule`: cancel SmartMix, compare scheduled ids to expected upcoming ids, clear and re-prefetch only if they differ | Service:4212-4236; Prefetch:135-151 |
| Repeat-mode change | SmartMix cancelled; schedule untouched | Service:4300 |
| SmartMix toggled off | Cancel transition, clear schedule, re-prefetch | Service:4339-4341 |
| Quality change | Clear schedule, evict cached files except current | Service:6548-6560 |
| Download finished for a scheduled track | Clear and re-prefetch only if a scheduled id changed | Service:6640-6648 |
| Network transition | Scheduled items are kept; only unscheduled upcoming URLs are evicted and re-resolved; stream decisions are kept | Service:6909-6936 |
| Route/config change | SmartMix cancelled (kept if promoted); current and all scheduled files rescheduled | Engine:463-465, 521-537 |
| First isolation enable | Same reschedule as route change | Engine:796-845 |
| New load | `scheduledFiles.removeAll()`; active deck reset to primary | Engine:972, 1001, 1073 |

---

## 5. Stream resolution and startup, in order

**Request setup**

1. `Service.playCurrentQueueItem` (4701): bump `playbackGenerationCounter` (4719), begin background task (4725).
2. Apple Music branch exits to the MusicKit path after `audioEngine.stop()` (4733-4747). Otherwise stop MusicKit and configure the session (4748-4780; AudioSession:71).
3. `prepareAudioEngineForPlaybackIfNeeded` (4782 → 1576): reuse, create (`setupPlayer` 1377) or recreate (`recreatePlayer` 1564).
4. `resolveTrackForPlaybackIfNeeded` (4788), supersession check (4789-4798).
5. `PlaybackSessionStateMachine.buildRequest` (4800 → StateMachine:26); recovery seek is kept only if > 1 s and clamped to duration − 2 s (StateMachine:99-109).
6. Publish `.loading`, `engine.pause()` (4819-4830).

**Source decision** (attempt loop, max 2, 0.5 s before attempt 2: 4842-4850)

7. Resolved-file cache hit → `.cachedFile` (4854-4860). Otherwise `Service.resolvePlaybackSource` (5141) → `Transport.resolvePlaybackSource` (53), deduped per track + floored start time (55-58, 350-353) → `resolvePlaybackSourceImpl` (160):
   1. Network state and cellular permission (166-174).
   2. Downloaded local file: exists, mp3-alias fix-up, payload sanity (177-192; LocalFile:8-33, 55-74).
   3. Completed artifact in the stream cache, only when start time is 0 → `.cachedFile` (194-202; ArtifactCache:81-110).
   4. Offline with no local file → `.offline` / `.corruptLocalFile` (204-207).
   5. Local file wins when streaming is not possible, data is constrained, or streaming quality is not preferred over the download (209-218).
   6. `ensureServerConnection` (229), else `.serverUnavailable` (232).
   7. `streamDecision` (235 → 269): cached per track for start 0 (274-276); one retry after `refreshConnection` (283-289).
   8. `assembleStreamResolution` (238) → `handleStreamResolution` (297):
      - `.downloadedFile` → `.cachedFile` (305-306)
      - `.directStream` → `.localFile` if file URL, else `.directHTTP` with `isSeekable: true`, `startTime: 0` (307-328)
      - `.progressiveTranscode` → `.transcodedHTTP` with `isSeekable: false`, mp3 (329-346)
   9. One retry after `refreshConnection` (250-262); on any failure fall back to the local file if one exists (263-266).
8. File sources are probed for truncation; a truncated file is evicted and the source re-resolved (Service:4869-4879, 5265; LocalFile:76-79).

**Engine load**

9. Supersession check (4882), then `Launch.completeLaunch` (4892 → Launch:82): visualizer plan for file sources (89-101), then `loadAndPlay` (103) → `Service.loadAndPlaySource` (5698).
10. `AudioSession.activateForPlayback` (5723 → AudioSession:149; one retry after 0.5 s at 163); on iOS 18+ restore the non-mixable category (5736-5755).
11. `engine.clearScheduledFiles()` (5763); set initial buffered progress (5776; Source:55-71).
12. **Automation failure injection**: `PlaybackAutomationFailure.check(stage: "startup", …)` (Service:5785, 5825; Automation:21-39). DEBUG only; throws `URLError(.secureConnectionFailed)` up to `…_COUNT` times after an optional `…_DELAY_SECONDS` (max 10 s) for a track matching `…_TRACK`.
13. `Transport.takePreparedPipeline` (5796, 5836 → Transport:369): hands over a prefetch pipeline whose artifact key matches.
14. `engine.load(source:…)` (5832 → Engine:1024):
    - File: `load(fileURL:)` (964) stops the engine, reconnects the player node at the file's format (978-979), reads content bounds (990 → 2373), schedules the whole content (1008).
    - Stream: `loadStreamingSource` (1049) adopts or creates a pipeline (1076-1109), raises buffer pressure (1111), awaits `startStreamingPipeline` (1115 → 1179) which resumes on `onFormatReady` (1228) or throws on a pre-format failure (1251) after `pipeline.start()` (1255; Pipeline:310, 277), then creates and attaches the `AVAudioSourceNode` (1142-1164).
15. Post-await generation check; a superseded request stops the engine only if the engine still holds that generation (5838-5842).
16. If handoff suppression is active, stop here in `.buffering` without playing (5780-5820). If `shouldStartPlayback` is false, stop here in `.paused` (5846-5855).
17. `engine.play()` (5856 → Engine:1779). Stream: `engine.start()`, start timer (1781-1793). File: stop node, reschedule, `engine.start()`, `node.play()` (1816-1838).
18. State becomes `.buffering` for streams, `.playing` for files (5860).

**First audible render**

19. File: `onFirstAudibleRender` fires synchronously inside `play()` before any audio is rendered (Engine:1839-1842).
20. Stream: first render call that returns frames hops to main and fires `onFirstAudibleRender` (Engine:1145-1151) → service moves to `.playing`, resets the failure counter, ends the skip transition (Service:1430-1445).

**After load**

21. Recovery seek for file sources only (Launch:105-108 → Service:3893 → Engine:1935). Stream sources carry the offset in metadata (Engine:1132).
22. `prefetchNext` (Launch:110 → Service:5296).

**Retry and recovery paths**

| Failure | Path | Citation |
|---|---|---|
| Cancelled or superseded | Exit quietly | Service:4901-4911 |
| Timed out / connection lost / not connected / cannot connect, attempt 1 | Evict track, `refreshConnection`, loop once | StateMachine:19-24, 44-49; Service:4916-4934 |
| CoreAudio open failure on a local file | Recreate engine, replay with `forcingFreshItem` | Service:4946-4964, 5012-5021 |
| TLS failure (includes the injected failure) | `handleTLSPlaybackFailure`: n × 0.5 s backoff, evict, `refreshConnection`, rebuild upcoming queue, replay; circuit breaker on consecutive failures | StateMachine:61-63; Service:5061-5128 |
| Other connection failure | Server health check, then `.failed` | Service:4975-4998 |
| Anything else | `.failed(message)` | Service:4999-5008 |
| Stream fails after startup | `onError` → `recoverCurrentStream` → `retryCurrentTrack("stream-interrupted")` → replay at current time; swaps to a local download if one appeared | Engine:1231-1250; Service:1546-1560, 5023-5056 |
| Rebuffering for 30 s | `onError(.streamingUnderrun)` → same recovery | Engine:2080-2083 |
| Prefetch download fails | One retry after `refreshConnection` + 0.5 s; then a 30 s (recoverable) or permanent memo for that track pair | Transport:82-107; Prefetch:124-130; Service:5675-5695 |

**Other automation injection points**

- `ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_STAGE=prefetch`: Transport:87-91, only when the resolved source is not already a file.
- `ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK` / `_SECONDS`: Pipeline:610-626, called from the URLSession data callback (Pipeline:672). DEBUG only; one `Thread.sleep` (max 20 s) per pipeline after the first byte.

---

## 6. What each coordinator would become

(a) reducer decision logic, (b) effect handler, (c) engine-adapter internal, (d) delete.

| File | Verdict | Justification |
|---|---|---|
| PlaybackTransportCoordinator | (b) | It is the "resolve source" and "prefetch to file" effect; its three dictionaries are effect-handler caches. The source-preference rules (Transport:166-226) are pure given network/file inputs and could be lifted to (a) later. `takePreparedPipeline` (369) is the one seam into the engine adapter. |
| PlaybackStartupCoordinator | (a) | A four-state gate and one pure function over a snapshot (Startup:33-102); both are reducer state and reducer logic. |
| PlaybackLaunchCoordinator | (d) | `completeLaunch` is three closure calls back into the service (Launch:103-110); the reducer's effect sequencing replaces it. Keep `visualizerPlan` (42-80) as a pure helper for the visualizer effect. |
| PlaybackSessionStateMachine | (a) | Already pure and stateless (StateMachine:4); retry and failure classification are exactly reducer decisions. The name is misleading — it holds no state. |
| PlaybackAudioSessionCoordinator | (b) | Performs session side effects and is the source of interruption/route events (AudioSession:32-56, 71-190). Shared by both engines (mixable vs long-form, 84-97), so it sits beside the adapters, not inside the native one. |
| PlaybackPrefetchController | split (a) + (b) + (d) | Timing predicates are pure → (a) (Prefetch:21-84, 135-151). The two memos (14-15) become reducer state. Cache pass-throughs (153-217) add nothing → (d). `cleanupStreamCacheFiles` (219-247) is disk work → (b). |
| PlaybackSource | keep (shared type) | It is the payload of the `load` effect; only the native engine understands the HTTP cases. |
| PlaybackLocalFilePolicy | (b) helper, thresholds (a) | Sniffing and alias creation touch the file system (LocalFile:8-74) and belong to the resolve effect; the truncation thresholds (76-87) are pure. |
| PlaybackResolvedFileCache | (b) state | An LRU dictionary plus an in-flight set with no lock (FileCache:8-10); naturally owned by the resolve/prefetch effect handler. Could be reducer state if file URLs are allowed there. |
| PlaybackStreamCacheIdentity | (c) | File-naming helper used by the engine, pipeline and artifact cache. |
| PlaybackArtifactCache | (b) infrastructure | Disk store behind the resolve effect and the pipeline; no playback decisions. |

---

## 7. Concurrency hazards

**Engine isolation**

1. The engine is unguarded and mostly un-annotated (Engine:25), yet the service touches it from a non-isolated async method. `prefetchUpcomingItems` (Service:5386) is not `@MainActor`; it reads `audioEngine` (5392) and calls `engine.clearScheduledFiles()` (5436, 5444), `isTrackScheduled` (5460, 5510, 5561), `scheduledTrackIdsInOrder` (5443) and `isSmartMixTransitionActive` (5550) off the main thread. `clearScheduledFiles` stops a player node and mutates `scheduledFiles` and `scheduleGeneration` (Engine:1685-1762) while main-thread completion handlers read them. This is the most serious finding.
2. `onStreamingFileComplete` is read and invoked on the URLSession delegate queue (Engine:1100-1106; Pipeline:523).
3. For an adopted prefetch pipeline, the engine assigns `onFirstByte`, `onBufferedProgress`, `onFormatReady`, `onFailure` on main (Engine:1200-1254) while that pipeline's download is already invoking those unsynchronised properties on its own queues (Pipeline:186-193, 474).

**Render thread**

4. The source-node render block (Engine:1142-1161) takes locks on the audio thread: `stateLock` (`NSLock`) twice per call via `render` and `isComplete` (Pipeline:404-409, 232-236) plus a third time at Engine:1153, and the ring buffer's `NSCondition` (PCMBuffer:156). The decoder thread takes the same condition in `writeBlocking` (PCMBuffer:97).
5. The same block allocates by calling `DispatchQueue.main.async` (Engine:1147, 1155), and the end-of-stream branch re-enqueues a main block on every render quantum until main reacts (1154-1158).
6. The comment at Engine:187-198 says progress avoids the render lock via a dedicated queue. The timer actually runs on `.main` (2041), `timeUpdateQueue` is used only for the SmartMix timer (1530), and `currentTime()` does read `lastRenderTime` on main (2016-2017) from service calls (Service:1685, 5847) and from pause/seek/clear (Engine:1712, 1797, 2141).

**Locks and `@unchecked Sendable`**

7. `PlaybackArtifactCache` is `@unchecked Sendable` (ArtifactCache:36) behind one process-wide static `NSLock` (39). Under that lock it scans the directory, decodes manifests and opens an `AVAudioFile` (150, 206, 230-250, 282). `trim` is called on the main actor (Service:4673; Prefetch:246), so main can block behind disk work.
8. `PlaybackTransportCoordinator` holds its `NSLock` while cancelling pipelines (Transport:118, 131, 147, 374) and while creating one (392-410). Cancel runs `Pipeline.fail`, which resumes continuations, fires `onFailure` and takes the artifact-cache lock (Pipeline:562-590). Order is consistently transport → pipeline → artifact; no inversion found in the files read.
9. Resolution dedupe is check-then-insert across two lock acquisitions (Transport:56-66); two callers can both start a task.
10. `PlaybackAutomationFailure.State` is `@unchecked Sendable` with a lock (Automation:6-17); DEBUG only, benign.
11. `startStreamingPipeline` uses a local `NSLock` to make continuation resume one-shot (Engine:1188-1199); benign.

**Events that can arrive after their track was replaced**

12. The token on events is the engine's generation at fire time, and `adoptPlaybackGeneration` overwrites it on every resume (Engine:1773-1776; Service:3307, 3352, 6887). It identifies "latest service request", not the source that produced the event. Per-source staleness relies on a second, private counter (`scheduleGeneration`, Engine:117) and a third (`progressRevision`, 179). A single session id would replace all three.
13. `onPlaybackComplete` has no track id and is also fired synchronously inside `play`, `seek` and `clearScheduledFiles` (Engine:1732, 1805, 1958), i.e. re-entrantly within a service call such as Service:5763. Today the skip-transition flag absorbs it (Service:1754-1757).
14. `onStreamingBufferPressureChanged` carries no token and the handler has no guard (Engine:34, 2062; Service:1447-1451).
15. `onStreamingFileComplete` passes a generation the handler ignores (Service:1471). Probably intended, since it caches by track identity, but it is an unguarded late event.
16. `onTrackAdvance` and `onSmartMixPromote` take a second `main.async` hop in the service (Service:1408, 1415), so they are processed after the engine has already changed `currentTrackId`; the progress-sink reconciler can observe the mismatch first and synthesise the same advance (1518, 1705-1718). `handleEngineTrackAdvance` de-duplicates by index (1622-1625).
17. Pre-buffer `load(fileURL:)` passes no generation (Service:6041 → Engine:967 default 0); events are dropped until a later `adoptPlaybackGeneration`.
18. `stop()` resets the generation to 0 but leaves `currentTrackId`, `currentFile` and `fileDuration` populated (Engine:1913-1932). The service uses `currentTrackId` as an "is loaded" test (Service:3295, 3394, 3945, 6017).
19. `removeScheduledTrack` is effectively dead and would misbehave if reached: every `onError` call passes `nil` for the track id (Engine:503, 557, 1249, 2083), so Service:1482-1486 never runs. The method only edits the tracking array; the audio stays in the node FIFO, and the completion handler does not match by track id as its comment claims (Engine:1667-1675 vs 2314-2355).
20. Completion handlers use the legacy `scheduleSegment` callback (Engine:1008-1017), which reports data consumed rather than played out, so "ended" and "advanced" can lead the audible boundary slightly.

---

## 8. Proposed normalized `EngineEvent`

Every event travels in an envelope tagged with the reducer-issued session id. That id replaces `playbackRequestGeneration`, `scheduleGeneration` and `progressRevision` as the staleness check.

```swift
struct EngineEventEnvelope {
    let session: PlaybackSessionID   // issued by the reducer with the load effect
    let event: EngineEvent
}

enum EngineEvent {
    /// Source attached and ready to play; duration and seekability now known.
    case prepared(item: ItemID, duration: TimeInterval?, isSeekable: Bool)
    /// Audio is reaching the output for this item.
    case started(item: ItemID)
    /// Periodic position; `timeline` changes on seek/resume/advance.
    case progress(item: ItemID, position: TimeInterval, timeline: UInt64)
    /// Fraction of the item available without network.
    case buffered(item: ItemID, fraction: Double)
    /// Engine is (not) starved for data while asked to play.
    case stalled(Bool)
    /// A pre-scheduled item became current without a reload.
    case advanced(to: ItemID, via: AdvanceKind)        // .gapless | .crossfade
    /// A crossfade overlap began or ended.
    case transitionActive(Bool)
    /// The current item finished and nothing was scheduled after it.
    case ended(item: ItemID)
    /// The engine rebuilt its output; position is where it resumed.
    case outputReconfigured(position: TimeInterval, isPlaying: Bool)
    /// Unrecoverable for this session; reducer decides retry.
    case failed(EngineFailure, item: ItemID?, position: TimeInterval?)
}
```

| Case | Replaces |
|---|---|
| `prepared` | Return of `load(source:)` (Engine:1024) plus pulls of `fileDuration`, `currentTrackId`; the thrown `streamingSeekUnavailable` becomes `isSeekable` known up front |
| `started` | `onFirstAudibleRender` (Engine:230) |
| `progress` | `currentTimeSubject` (180) and `isCurrentProgress` (1766) |
| `buffered` | `onBufferedProgress` (232); file sources emit 1.0 once (today: Source:55-58) |
| `stalled` | `onStreamingRebufferingChanged` (35) |
| `advanced(.gapless)` | `onTrackAdvance` (224) and the reconciliation poll (Service:1705-1718) |
| `advanced(.crossfade)` | `onSmartMixPromote` (226) and its poll (Service:1512-1517) |
| `transitionActive` | `onSmartMixTransitionActiveChanged` (228) and pulls of `isSmartMixTransitionActive` |
| `ended` | `onPlaybackComplete` (222), now with an item id |
| `outputReconfigured` | New: `handleConfigurationChange` success is silent today (Engine:462-559) |
| `failed` | `onError` (238) and throws from `load/play/resume/seek`; `.streamingUnderrun` and pipeline failures become `EngineFailure` cases |

Deliberately left out of the shared enum, as native-only side channels:

- `onStreamingBufferPressureChanged` (Engine:34) — a network-throttling hint, not playback state.
- `onStreamingFileComplete` (Engine:234) — belongs to the resolve/cache effect handler.
- Scheduled-item bookkeeping (`scheduledTrackIds…`) — the reducer should know what it scheduled; add `case scheduled(item:)` / `case unscheduled(item:)` only if the adapter is allowed to drop items on its own.

---

## 9. Open questions

1. **Off-main engine access (hazard 1).** Is `prefetchUpcomingItems` meant to be main-isolated? The contract needs one isolation rule for the adapter; the reducer step should not inherit this.
2. **Who owns pre-scheduling in the new contract?** Today the service decides timing with a 20 s lead and the engine starts SmartMix immediately on request. Should the reducer emit "schedule next" / "begin crossfade" effects at the right moment, or hand the engine a plan with a start time? MusicKit cannot crossfade on command, so this affects whether `advanced`/`transitionActive` are common or native-only.
3. **Gapless from a streamed track.** It is not possible today (§4). Is that accepted behaviour to preserve, or a gap to record on the watchlist?
4. **Progress cadence through the reducer.** The 10 Hz tick currently drives scheduling, persistence, reporting and reconciliation (Service:1504-1540). Should progress bypass the reducer as a side stream, with the reducer receiving only coarse or threshold events?
5. **`onPlaybackComplete` fired synchronously inside commands** (Engine:1732, 1805, 1958). Should the adapter always deliver events asynchronously so a command can never re-enter the reducer?
6. **Seeking a direct stream.** `.directHTTP` is built with `isSeekable: true` and `startTime: 0` (Transport:312-327), yet the engine refuses every streaming seek (Engine:1937-1939) and the restart path applies the offset only via metadata (Engine:1132) or a file seek (Launch:105). I did not trace `makeStreamDecision` to confirm what a direct-stream restart at t > 0 returns.
7. **Stream end by metadata duration.** The timer ends a stream when `position >= fileDuration` from metadata (Engine:2069-2071). If metadata is shorter than the real audio, the tail is cut. Is that intended as a guard against over-long transcodes?
8. **`stop()` leaving `currentTrackId` set (hazard 18).** Intentional, or should "nothing loaded" be an explicit state/event in the adapter?
9. **Dead `removeScheduledTrack` path (hazard 19).** Delete with the contract change, or was a per-item scheduling failure event intended? `scheduleNext` already throws synchronously.
10. **Completion while paused.** `handleSegmentComplete` drops a completion when `wasPlaying` is false (Engine:2251-2254) and nothing re-arms it. I could not determine from reading whether a pause landing in the final buffer can strand the track at its end.
11. **Route handling split.** The engine self-recovers on configuration change while the service separately runs `PlaybackHandoffCoordinator` logic on the session notifications (Service:2406-2476; not in this task's file list). Which side owns "resume after route change" under the reducer?
12. **macOS.** Interruption and route notifications are compiled out (AudioSession:36-56), so macOS relies solely on the engine's own configuration-change recovery. `outputReconfigured` would be the only route signal there.
