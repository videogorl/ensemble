# Fixed audio graph stability

**Date:** 2026-08-28  
**Scope:** `AudioPlaybackEngine`, streamed/file source changes, route changes, and `AUSoundIsolation`  
**Conclusion:** A fixed processing graph with a source mixer is the right architecture and is sufficient for the observed `AVAudioEngine.connect` crash class, provided that “fixed” means no track-driven reconnection downstream of that mixer and the engine is fully stopped before a streaming source node is detached. It is not a reason to replace the decoder, cache, or playback service. The implementation also restores streaming route recovery without rebuilding the graph. Ensemble's instrumental model configuration remains a separate risk because it relies on undocumented Audio Unit properties.

## Why the current graph crashed

The retained session shows the exact risky sequence: a 48 kHz streamed track was playing with isolation active, `pause()` left the engine paused, and Next selected a cached 44.1 kHz file. The crash report then aborts on the main thread in `AVAudioEngineGraph::_Connect` / `-[AVAudioEngine connect:to:format:]`. This matches the source:

- Streaming pause calls `engine.pause()`, which deliberately retains prepared graph resources ([source](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L1838-L1860)). Apple documents that `pause()` does not deallocate resources allocated by `prepare`, whereas `stop()` releases them ([`AVAudioEngine`](https://developer.apple.com/documentation/avfaudio/avaudioengine)).
- File load first cancels and detaches the streaming node, then `buildGraph` disconnects and reconnects every player, effect, deck mixer, and isolation connection using the new file format ([source](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L972-L1014), [teardown](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L1293-L1303), [graph rebuild](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L298-L338)).
- Apple allows runtime graph mutation with limitations and specifically says reconnections should remain upstream of a mixer. The current rebuild crosses the mixer and rewrites the isolation-to-main-mixer path ([`AVAudioEngine`](https://developer.apple.com/documentation/avfaudio/avaudioengine)).

The decoder is not implicated by the crashing stack. It already produces linear PCM in the stream's native sample rate ([source](../../Packages/EnsembleCore/Sources/Services/StreamingAudioDecoder.swift#L128-L147)); the failure occurs later while AVFAudio reconnects the graph.

## Architecture that closes the crash class

```text
file player ---------\
                      source mixer -> time pitch -> EQ --\
stream source node --/                                  \
                                                           deck mixer -> isolation -> main mixer -> output
SmartMix player -------------> time pitch -> EQ ---------/
```

Use these invariants:

1. Build the processing chain from the source mixer's output through isolation once per engine topology. Give it one stereo processing format that the isolation unit has successfully accepted. Track loads must not call the current broad `buildGraph(format:)`.
2. Keep the file player connected. `AVAudioPlayerNode` can sample-rate-convert scheduled file segments, and Apple recommends a mixer as the format-conversion boundary ([`AVAudioPlayerNode`](https://developer.apple.com/documentation/avfaudio/avaudioplayernode), [`AVAudioMixerNode`](https://developer.apple.com/documentation/avfaudio/avaudiomixernode)).
3. Connect each `AVAudioSourceNode` only to the source mixer. Mixers accept any input sample rate and channel count and perform the required sample-rate and channel conversion. A source node initialized with its decoded PCM format also supports linear PCM conversion between its render block and output connection ([`AVAudioSourceNode.init(format:renderBlock:)`](https://developer.apple.com/documentation/avfaudio/avaudiosourcenode/init%28format%3Arenderblock%3A%29)).
4. Before canceling, disconnecting, or detaching the current streaming source, call `engine.stop()` unconditionally. This releases prepared resources and makes source replacement independent of whether the prior user action happened to pause or stop the engine. The existing source object can remain per-stream; a permanent source node plus another conversion layer is unnecessary unless stopped upstream replacement itself later fails physical stress testing.
5. Keep isolation connected after creation and toggle only public bypass/parameter state. Its first insertion may be one deliberate `stop` / build / restart operation; it must not be combined with a track-format rebuild. Eager construction is optional, not required for this crash fix.

This is the smallest stable boundary: Apple explicitly supports source mutation upstream of a mixer, the mixer owns conversion, and the format-sensitive time effects/isolation chain no longer changes when a 44.1, 48, mono, stereo, file, or streamed source arrives.

## Route changes need a separate correction

A fixed graph should normally survive output-only hardware changes. Apple says configuration changes stop the engine but leave nodes attached and connected; the app only needs to reestablish connections whose formats must change. It also says the default main-mixer-to-output connection automatically tracks the output format on restart when the app has not explicitly set that connection ([`AVAudioEngineConfigurationChangeNotification`](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification), [`mainMixerNode`](https://developer.apple.com/documentation/avfaudio/avaudioengine/mainmixernode)). Ensemble uses that default output connection.

Route recovery now captures the playhead, restarts the unchanged graph, and restores source-specific playback state. File playback is rescheduled; streaming retains its source node and pipeline. No route event reconnects the processing chain.

## Residual Sound Isolation risk

The Audio Unit subtype and its wet/dry and voice-selection parameters are public API on supported systems ([subtype](https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation), [sound selection](https://developer.apple.com/documentation/audiotoolbox/kausoundisolationparam_soundtoisolate), [wet/dry](https://developer.apple.com/documentation/audiotoolbox/kausoundisolationparam_wetdrymixpercent)). The installed Xcode 26.5 SDK publishes only voice and high-quality-voice sound types. Ensemble additionally supplies system-file paths through property IDs `30000`, `40000`, and `50000`, and private tuning parameters `0x17626` / `0x17627` to obtain instrumental behavior ([source](../../Packages/EnsembleCore/Sources/Services/AudioPlaybackEngine.swift#L664-L675)). Those values and file locations have no public compatibility contract.

That is a residual feature risk, not evidence that the fixed graph is insufficient. Contain it by checking every format/property/parameter `OSStatus`; only mark the model loaded after success; and on any failure leave the AU bypassed and play dry audio. Also treat `setPreferredIOBufferDuration` as a preference, not a guarantee: Apple says the actual duration may differ and must be queried ([Apple](https://developer.apple.com/documentation/avfaudio/avaudiosession/setpreferrediobufferduration%28_%3A%29)). In the crash session, the 128 ms request resolved to 23.2 ms, confirming that the preference is not a stability mechanism.

## Verification matrix

The focused physical-device pass used build `202608280900.0719` on the iPhone 16 Pro running iOS 27.0. With Ensemble backgrounded and the phone locked, system Previous changed an active Plex stream into its completed cached file, then changed to the cached prior track. Logs recorded `sourceDetached kind=stream engineStopped=true`, file attachment, and downstream revision `1` with `downstreamMutation=false`; the process remained alive and no new crash report appeared. A paused lock-screen skip also remained paused. Bluetooth -> iPhone Speaker -> Bluetooth route changes produced two configuration-change records without downstream mutation. Instrumental Mode's first-insertion path was not reached through Device Hub, so that remains residual physical-device coverage.

The full matrix below remains the optional extended stress pass rather than evidence claimed by this focused run.

Run this on the physical iPhone with isolation both bypassed and active:

| Axis | Required cases |
|---|---|
| Source transition | stream -> cached file, cached file -> stream, stream -> stream, file -> file |
| Format | 44.1 -> 48 kHz, 48 -> 44.1 kHz, mono -> stereo, stereo -> mono |
| Trigger | manual Next/Previous, natural boundary, paused source replacement, repeat, failed/cancelled stream retry |
| Mixing | gapless FIFO and SmartMix eligible/ineligible boundaries |
| Route | speaker, Bluetooth A2DP, AirPlay; route change during file playback, stream playback, pause, and load |
| Stress | at least 100 alternating source/format transitions with no downstream reconnect log, abort, silence, or incorrect playhead |
| Isolation fallback | supported model, missing/rejected private model property, unavailable component; dry playback must remain usable |

Acceptance is current-build process proof plus continuous audio/state evidence. The key diagnostic invariant is simple: after setup (and at most one stopped isolation insertion), no track or route event disconnects `timePitch`, EQ, deck mixer, isolation, or main mixer.
