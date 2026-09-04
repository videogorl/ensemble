# Apple Music and Ensemble playback engine review

Reviewed 2026-09-04 against `8e40f111` on `develop`. This is a source and public-API review, not a device reproduction or performance measurement. Production code is unchanged.

## Recommendation

Keep `ApplicationMusicPlayer` for Apple Music and `AudioPlaybackEngine` for Ensemble's file/HTTP playback. Improve their shared control boundary before considering another engine. The current split is appropriate; duplicated queue policy, inconsistent event handling, and unsafe native render work are the stronger targets.

`PlaybackService` already owns the logical queue. `AppleMusicPlaybackController` adapts MusicKit; `AudioPlaybackEngine` owns decoding/rendering and native gapless/SmartMix. `PlaybackHandoffCoordinator` handles interruptions/routes, `PlaybackAudioSessionCoordinator` manages session configuration, and `PlaybackNowPlayingBridge` owns Ensemble's system-media writes. Preserve those owners.

Apple documents app-scoped playback through [ApplicationMusicPlayer](https://developer.apple.com/documentation/musickit/applicationmusicplayer) and opaque [PlayParameters](https://developer.apple.com/documentation/musickit/playparameters). No public MusicKit PCM-output interface was identified. Routing subscription audio through Ensemble's decoder/DSP is therefore not a supported unification path established by this review.

## Findings, in priority order

### 1. Share queue-completion policy: Repeat All currently diverges

**Confirmed in source.** Native [handleQueueExhausted](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L1733) checks playable successors, Repeat One, Repeat All, and autoplay. Apple's [advanceAfterAppleMusicSegment](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L6249) calculates `currentQueueIndex + 1`, attempts autoplay, and otherwise stops if there is no next item. It never checks Repeat All.

Example: with autoplay off and Repeat All on, an Apple Music item at the end of the logical queue takes the stop branch; native completion takes the wrap branch. Apple completion also bypasses the native next-playable selection policy. This has not been reproduced on a device in this review.

**Smallest useful change:** share the next-item/repeat/autoplay decision inside the existing queue owner. Preserve MusicKit-native Repeat One and station behavior. Distinguish natural completion from an explicit skip; a skip must not accidentally repeat the current item. Do not blindly route everything through the native exhaustion handler, which also contains native recovery and suppression rules.

### 2. Remove blocking work from the native audio callback

**Confirmed implementation risk; audible impact unmeasured.** The [AVAudioSourceNode callback](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L1147) calls [pipeline.render](../../Packages/EnsembleCore/Sources/Services/StreamingAudioPipeline.swift#L300), which takes `NSLock`, then [StreamingPCMBuffer.read](../../Packages/EnsembleCore/Sources/Services/StreamingPCMBuffer.swift#L133), which takes `NSCondition`. Reading `pipeline.isComplete` takes another lock. The producer holds the buffer condition while copying samples; the renderer also queues main-thread closures for events, including repeated EOF notifications before the main thread handles completion.

Apple's [source-node sample](https://developer.apple.com/documentation/avfaudio/building-a-signal-generator) requires real-time rendering to avoid locks, allocations, file I/O, and runtime interactions. These operations introduce contention and scheduling risk exactly where playback needs predictable deadlines.

**Change:** retain bounded buffering and decoder backpressure, but make the render-facing read and status exchange nonblocking, using a proven single-producer/single-consumer design or a measured native scheduled-buffer alternative. Deliver completion/underrun notifications outside the render callback, once per generation. Copy contiguous buffer spans instead of per-sample modulo loops. This needs focused concurrency and underrun validation; removing synchronization without replacing its guarantees would be incorrect.

### 3. Separate displayed progress from actual audio completion

**Confirmed behavior; premature audible completion remains a risk.** [startTimeUpdates](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L2045) estimates time from a wall clock and calls `handleStreamingComplete` when it reaches metadata duration. It does not require decoder EOF or an empty PCM buffer. An underestimated duration or output/startup delay can therefore advance the queue with audio still pending.

The existing [testKnownDurationStreamingSourceCompletesAtDuration](../../Packages/EnsembleCore/Tests/AudioPlaybackEngineStreamingTests.swift#L214) explicitly enforces timer completion, using a 0.2-second metadata duration. It does not prove the audio drained.

**Change:** base streaming completion on decoder EOF plus consumed audio, accounting for the output pipeline where possible. Keep wall-clock estimation for presentation and a bounded recovery watchdog, not unconditional success. Preserve the fixed processing graph and avoid periodic calls that take AVAudioNode render locks.

### 4. Normalize progress events, not just transport commands

**Confirmed asymmetry.** Native completion/error callbacks carry a playback generation, but [currentTimeSubject](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L190) carries only a number. Its [subscriber](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L1514) receives asynchronously on main and checks only whether playback is playing. An already-enqueued old-engine sample has no generation/queue-item check, unlike Apple Music time callbacks. Contamination during a switch is a source-level race risk, not a reproduced incident here.

Native time handling also calls `persistPlaybackSnapshotIfNeeded`; [Apple time handling](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L6361) does not. Lifecycle saves can still preserve Apple progress, but the regular 15-second checkpoint is native-only.

**Change:** feed both adapters into one generation-checked progress handler, including queue-occurrence identity and finite-time validation. Share checkpointing; retain provider-specific reporting and visualization. Apple explicitly documents that [playbackTime can be NaN](https://developer.apple.com/documentation/musickit/musicplayer/playbacktime), so invalid time must not become a rewind/end signal. Also synchronize native `timeBase`/durable-position access: copying a struct across the main and timer queues is not itself a synchronization guarantee.

### 5. Make MusicKit polling follow playback lifetime

**Confirmed unnecessary work.** The controller starts a [250 ms task loop in init](../../Packages/EnsembleCore/Sources/Services/AppleMusicPlaybackController.swift#L421). [stop](../../Packages/EnsembleCore/Sources/Services/AppleMusicPlaybackController.swift#L773) clears the active generation but does not cancel the task. Once created, the retained controller keeps waking while the process runs, including during native playback. With no Apple queue each wake returns early, so battery savings must not be overstated.

The controller already observes [MusicKit queue and state](../../Packages/EnsembleCore/Sources/Services/AppleMusicPlaybackController.swift#L1286), consistent with Apple's observable [Queue](https://developer.apple.com/documentation/musickit/applicationmusicplayer/queue-swift.class) and [State](https://developer.apple.com/documentation/musickit/musicplayer/state-swift.class).

**Change:** stop the monitor when inactive and restart it when Apple playback needs it. Keep state/queue observations alive for external resume. Sample progress while playing and retain only the bounded end confirmation needed by measured platform behavior. Native state observation does not promise periodic time updates or an unambiguous reason for every pause; do not simply delete the current boundary safeguards.

### 6. Prepare the next item without claiming its audio session early

**Confirmed startup work; improvement requires measurement.** Every finite Apple start performs [catalog/library resolution](../../Packages/EnsembleCore/Sources/Services/AppleMusicPlaybackController.swift#L609), followed by queue assignment, preparation, and play. Native prefetch [returns for an upcoming Apple item](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L5449). Apple's successful start path does not schedule the usual native successor prefetch.

**Change:** resolve only the next item's metadata/playable object ahead of the boundary, reuse successful resolution within the current queue generation, and invalidate on queue/source changes. Reuse existing native file/transport caches for the opposite direction, separating file preparation from scheduling audio. Keep this bounded; do not preload an entire mixed queue.

Crucially, [MusicPlayer.prepareToPlay](https://developer.apple.com/documentation/musickit/musicplayer/preparetoplay()) interrupts active nonmixable sessions. Calling it while native music plays is an ownership-changing operation, not harmless prefetch. Audio activation and queue replacement belong to the deliberate handoff.

Small cleanup: [playCurrentAppleMusicSegment](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L6150) maps the entire remaining queue just to select one item. Read the current queue item directly. The one-item finite queue is intentional under the current [known-issues contract](../../.claude/skills/known-issues/SKILL.md); changing to long Apple segments requires separate approval and locked-device evidence.

## Engine alternatives

| Approach | Assessment |
| --- | --- |
| Keep both engines; share queue decisions and event validation | Recommended. Fixes demonstrated divergence without discarding native DSP, caching, or MusicKit behavior. |
| A small common transport interface | Useful only where it removes existing duplicate dispatch. Limit it to actual common operations/events; keep station queues and native DSP capability-specific. A generic plugin registry or third queue/state machine adds no value here. |
| AVPlayer/AVQueuePlayer for ordinary Plex playback | Worth a bounded comparison if custom streaming remains costly. Apple supplies file/URL/HLS playback and [stall management](https://developer.apple.com/documentation/avfoundation/avplayer/automaticallywaitstominimizestalling), but matching Ensemble's codec, caching, gapless, seek, and SmartMix behavior must be proven. Adding it alongside both engines increases handoff combinations. No efficiency win is established yet. |
| MPNowPlayingSession as a universal wrapper | Not applicable: its [initializer takes AVPlayer instances](https://developer.apple.com/documentation/mediaplayer/mpnowplayingsession/init(players:)), not MusicKit players or AVAudioEngine. |
| SystemMusicPlayer or silent audio to maintain execution | Do not introduce. The current app-scoped queue and finite background lease are deliberate; neither alternative establishes reliable ownership of Ensemble's mixed queue. |

The current Apple-to-native path deliberately activates a mixable session, then restores nonmixable configuration before native loading ([source](../../Packages/EnsembleCore/Sources/Services/PlaybackService.swift#L5704)). Preserve that sequence until an exact OS/route comparison proves a replacement. A common Swift interface cannot remove the operating system's session/remote-command boundary.

## Delivery and verification

Start with shared completion policy, generation-safe progress/checkpointing, and monitor lifecycle. Separately fix the native render boundary and completion clock. Evaluate bounded pre-resolution after those foundations; postpone an AVPlayer migration until measurements justify it.

Existing coverage was inspected, not executed: `PlaybackServiceTests`, `AppleMusicPlaybackOperationCoordinatorTests`, `AudioPlaybackEngineStreamingTests`, and the buffer/pipeline test files. Pure policy tests cannot exercise the iOS-only MusicKit controller. No current-build phone, AirPlay, energy, or audible-continuity result is claimed.

For implementation, extend the smallest existing regression coverage, then verify a fresh physical build across Apple→Apple, Apple→Plex, Plex→Apple, and Plex→Plex; natural end, Next, Previous, Repeat One/All, paused skip, and rapid skip/cancel. Include uncached/cached native audio, locked/background operation, interruptions, Bluetooth, and phone-owned AirPlay. Measure audible handoff delay, unintended/double advances, timer wakeups, underruns, and peak memory. Preserve a recoverable paused boundary when the OS cannot complete a background handoff.
