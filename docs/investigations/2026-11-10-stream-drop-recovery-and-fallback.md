# Stream drop recovery and transcode fallback

Date: 2026-11-10. Design only, awaiting Felicity's approval. No Swift changed.

## Answer

- Buffering is not the weakness. The app downloads each track at full speed into
  a file, often far ahead of playback.
- The weakness is what happens on a drop: the app throws that download away,
  pauses, and reloads. For an original-quality track, the reload is an MP3
  transcode, so quality drops silently.
- One cause is ours. Plex keeps one direct-play session per client. When the
  next track's prefetch requests its file, Plex ends the current track's
  download. The Plex server log confirms this for every drop in the iPhone SE tests.
- Smallest fix: do not request a second original file while one is downloading.
  Then keep playing the buffered audio through a real drop and resume the
  download with a byte range.
- Gapless and SmartMix already run on Apple's file player (`AVAudioFile` +
  `AVAudioPlayerNode`). Only the start of a track uses custom streaming code. Keep
  that split, and give its network layer the same standard HTTP resume the offline
  downloader already uses.

## 1. Current behaviour

Every remote stream goes through one `StreamingAudioPipeline`. Each pipeline
opens its own `URLSession` (`StreamingAudioPipeline.swift:289`) and runs a single
data task with `waitsForConnectivity = true` (`:181`). Bytes go to a growing file
(`:459-480`). A decoder feeds a 20 s PCM ring (`:160`, `:416-420`). The decoder
blocks when the ring is full, but the download keeps going.

What any network error after startup does today:

1. `didCompleteWithError` → `fail()` (`StreamingAudioPipeline.swift:698-703`).
   `fail` closes the file with an error, so the decoder stops at once, even with
   unread bytes on disk (`:77-79`). It also deletes the partial file (`:584`).
2. The engine reports `onError` (`AudioPlaybackEngine.swift:1252-1270`).
3. `handleEngineFailure` (`PlaybackService+Session.swift:458-473`) calls
   `recoverCurrentStream` (`:91-122`). That pauses the engine, sets buffering, and
   reloads from the playhead through `retryCurrentTrack`
   (`PlaybackService+Loading.swift:498-553`). The reload is limited to 2 attempts
   until 5 s of progress (`PlaybackService.swift:471-472`, reset at
   `PlaybackService+Session.swift:298-301`). After that the item fails and is skipped.
4. A reload from a non-zero time skips the direct path. The decision becomes a
   transcode (`PlexAPIClient+Playback.swift:69,90-95`; `PlaybackTransportCoordinator.swift:280-282`).

| Stream kind | Connection drop / stall | Wi-Fi ↔ cellular | Server failover | Long pause |
|---|---|---|---|---|
| Direct file (`/library/parts`) | Steps 1-4. Buffered audio is discarded. The reload is an MP3 transcode, not the original. | The playback service only rebuilds upcoming URLs (`PlaybackService+Routing.swift:541-580,593-619`). The current download waits for its own task to fail. A dead Wi-Fi socket can take up to the default 60 s request timeout. | The reload's decision call reselects the endpoint. In the 2026-08-17 log this took 16 s in buffering. | If the stream fails while paused, a flag reloads it on Play (`PlaybackService+Session.swift:459-462`). The full-speed download has usually finished by then. |
| Universal transcode | Same as above; the reload uses an offset transcode. That has no length, so the short-transcode check cannot judge it (`PlaybackArtifactCache.swift:273-290`). | Same | Same | Same |
| Stream-cache hit | Played as a local file (`PlaybackTransportCoordinator.swift:203-211`); unaffected. | n/a | n/a | n/a |
| Prefetched successor | Downloaded to a file (`PlaybackTransportCoordinator.swift:395-423`). Retried once after a connection refresh (`:82-107`), then backed off for 30 s (`PlaybackPrefetchController.swift:123-129`). The track then streams normally when reached. | Re-resolved on transition | Same | Unaffected |
| Gapless handoff | Plays from the prefetched file through the existing `AVAudioPlayerNode` scheduling; unaffected by the network. | n/a | n/a | n/a |

Other findings:

- **Slot held through a stream-retry reload** (ON_DECK, suspected). This is now
  confirmed in the code. `stallRecoveryTask` stays set for the whole reload,
  including the decision call (`PlaybackService+Session.swift:112-122`). While it
  is set, a new stream failure is ignored (`:92`, `:471`), and Pause treats it as a
  pending retry (`PlaybackService+Routing.swift:328-334`). Hypothesis: a stream that
  fails again during a slow reload is dropped silently. It then waits for the
  30 s rebuffer timeout (`AudioPlaybackEngine.swift:2129-2133`).
- **The prefetch damage check uses metadata duration**
  (`PlaybackService+Loading.swift:964`). The stream-cache duration check also
  compares against metadata (`PlaybackArtifactCache.swift:280`).
- **Direct stream request** (`PlexAPIClient+Playback.swift:23-26`). It carries
  only the token and `X-Plex-Client-Identifier`, with no per-stream session identifier.

## 2. How often it happens

Read-only scan of 130 exported session logs in iCloud Drive Downloads (2026-03-26
to 2026-11-01). Script: `scan.py` in the design session's scratchpad.

- 18 logs come from builds with the current pipeline (since 2026-08-10).
- They contain 3 stream failures after startup, all NSURLErrorDomain -1005:
  - 2026-08-11, track 10068, at 418 s of 458 s. Timeline reports kept advancing,
    and offline downloads to the same server were running.
  - 2026-08-17, track 14901, high-quality transcode, at 63.6 s. A real
    connection loss. The reload's decision and endpoint failover kept it in
    buffering for 17 s; a decoder underrun then caused a second retry.
  - 2026-10-29, track 9021, original FLAC, in the car over Bluetooth. A real
    loss: the WebSocket dropped in the same millisecond, and no bytes had arrived
    for 4.6 s. Only 1.3 s was buffered; the user pressed Next.
- 9 "stopped producing decoded frames" retries in 2 logs (Mac 2026-08-10, iPad
  2026-09-06). These are decoder starvation, not connection loss, so they are out
  of scope here.
- Older pipeline: 2 lost connections and 7 TLS failures.
- None of the real logs has a rebuffer timeout or a failure skip. None has a
  network transition within 30 s before a drop.
- iPhone SE test archive (117 agent runs on 2026-11-10): 6 drops after startup.
  All were direct originals (WAV 8731 ×5, FLAC 14293 ×1). In each, the next
  track's direct download started 0-1.1 s earlier. With a successor queued, 2 of
  4 runs dropped; with 8731 alone, 0 of 6. At each drop about 20 s was buffered
  (`bufferedFrames` 714k-882k) and bytes were flowing (`lastByte=0.00s`). That is
  a reset, not a stall.

What the logs cannot show:

- They are sessions Felicity chose to export, so they cannot give a rate per hour.
- They cannot show drops in sessions she did not export.
- They cannot show whether she was on Wi-Fi or cellular, unless the state changed.
- They cannot show audible gaps that never raised an error.
- PMS keeps about 10 hours of logs, so none of her real drops can be matched
  on the server.

## 3. Reproduction: confirmed, and not a network fault

The Plex Media Server log on this Mac (`~/Library/Logs/Plex Media Server/`)
records, for every SE drop:

```
01:02:41.830 Request: GET /library/parts/10448/…/file.wav      (successor prefetch)
01:02:41.831 Streaming Resource: Terminated session 0x17420b8d8:B4581410-… with reason Client stopped playback.
01:02:41.858 Session 0x17420b8d8 terminated                   (phone logs -1005 at 41.889)
```

- `B4581410-…` is the app's client identifier. PMS logs
  `Client [B4581410-…] reporting timeline`.
- PMS creates one "AdHoc dp session" per client for direct-play parts. Any new
  part request from that client ends the previous one.
- This also explains the ping-pong. The retry of 8731 ended the 8732 prefetch
  (`00:30:41.766`), and the next prefetch ended the retry (`00:30:42.359`).
- In the SE run that did not drop (01:14), streaming quality was not Original.
  Each transcode has its own session ID, so they do not collide.

It did not reproduce from the Mac with curl:

- Two overlapping ranged downloads of both WAV parts, rate-limited to 5-8 MB/s:
  13 transfers completed.
- Tried with the owner token, with the `videogorl` token, with a shared client
  identifier, and with app-like headers.
- PMS created no ad-hoc session for them. Hypothesis: PMS creates one only for
  a client registered as a player through timeline reports. I did not send
  timeline reports, because they write play state.

The server (`Accept-Ranges: bytes`, strong `ETag`, `Keep-Alive`) honours byte
ranges. It ignores `If-Range`: a wrong tag still returns 206. So a client must
check the ETag and `Content-Range` on the 206 itself, as
`ResumableDownload.swift:80-88` already does.

Hypothesis, unconfirmed: with Original quality, away from home, most started
tracks still have their download running when the successor prefetch starts at
first audio (`PlaybackService+Session.swift:420`). Each of those would be cut,
then resume as an MP3 transcode. This matches "I notice it a lot". On fast home
Wi-Fi the current file usually finishes first. Offline downloads also call
`getStreamURL` with the same client identifier
(`PlexMusicSourceSyncProvider.swift:1654-1680`), so they may collide too.

## 4. Options

### 4a. Inside the current design (smallest first)

| Option | Removes / adds | Lines | Risk |
|---|---|---|---|
| **A. One direct download per server.** Start the successor's direct original only after the current one completes; offline downloads of originals wait too, if PMS shows they collide. | Removes the cause of every SE drop and the retry ping-pong. | ~40 | The successor starts a little later. It still has the rest of the current track to download. |
| A′. Send a unique `X-Plex-Session-Identifier` with each direct request. | Avoids serializing. | ~10 | Unverified. A shared user may hit stream limits or show twice in Now Playing. |
| **B. Keep playing through a drop (direct).** On a network error, keep the file, decoder and PCM ring. Re-request `Range: bytes=<received>-` from the current endpoint (cached decision, so a LAN-to-remote switch works). Require 206 with the same ETag and total; otherwise reload as today. Buffering shows only when the reserve runs out, through the existing rebuffer path (`AudioPlaybackEngine.swift:2123-2133`). | Removes the discard (`StreamingAudioPipeline.swift:584`), the pause, and the silent downgrade to MP3. The reserve becomes everything on disk, often the whole track. | ~150 | Bytes must be appended only after the checks pass. Reuse `ResumableDownload.validContentRange`. |
| **C. React to path changes.** On an interface switch or reconnect, restart B's ranged request at once on the new path. Set a ~15 s request timeout for stream sessions. | Removes up to 60 s of waiting on a dead Wi-Fi socket. | ~40 | Interface switches can only be proven on the phone. |
| **D. Retry budget and slot.** For network errors, replace "2 attempts until 5 s of progress" with the existing 30 s no-audio limit. Release `stallRecoveryTask` once the reload's source has started. | Stops a good track being skipped during a real network switch: today two failed reloads within a switch skip it, as in the 2.3 s SE ping-pong. Settles the ON_DECK item. | ~30 | Invalid audio and HTTP errors must still fail at once. |
| E. Transcode splice. Start an offset transcode at the end of the decoded audio, then drop the leading partial second and MP3 priming in PCM. | Removes the transcode reload gap. | ~150 | PMS offsets are whole seconds, and MP3 priming varies: possible audible glitch. Transcodes are small (~8 MB) and finish fast, so drops are rarer. **Defer.** Until then, transcodes play the reserve first, then reload at the playhead as today. |
| `multipathServiceType = .handover` | — | ~5 | Reject. It needs the Multipath entitlement, is iOS-only, and works only against an MPTCP server; PMS uses plain TCP. It also cannot make a LAN address reachable from cellular. |

**F. Downward-only transcode fallback for damaged originals.** It belongs at
the point where B gives up on media, not on network errors.

- Damage must come from the media itself:
  - a decoder error on bytes with a valid audio signature, or
  - a complete file that decodes to under half the length its own container
    declares (FLAC STREAMINFO, WAV data chunk).
- Metadata duration never counts as damage. Replace the checks at
  `PlaybackService+Loading.swift:964` and `PlaybackArtifactCache.swift:280` for
  direct originals.
- The fallback, once per item:
  - a forced transcode with `directStream=0` and `directStreamAudio=0`,
  - at the lower of 320 kbps and the configured quality,
  - with a cache key that includes the quality and the forcing flag,
  - at the playhead offset when the damage shows mid-track. Such a stream has no
    length, so only decoder errors judge it.
- A transcode never falls back to anything. HTTP 4xx (Plex 11700) is not media
  evidence, so the item fails.
- Prefetch runs the same media check before scheduling, closing the bypass noted
  on `fix/playback-recovery-stream`.
- Reuse that branch (60993cbc, ~1,280 lines with tests) by rebasing it onto B,
  not rewriting it.

### 4b. Native and hybrid paths

Why the app owns streaming today:

- AVPlayer cannot play PMS's chunked MP3 transcode (CFHTTP -16845), and it misreads
  its duration (no Xing/LAME header). See `.claude/skills/plex-api/media-streaming.md`.
- The engine replaced AVQueuePlayer for gapless scheduling with encoder-delay
  trimming, two-deck SmartMix (tempo, high-pass EQ, volume), AUSoundIsolation, and
  frame-accurate time (`AudioPlaybackEngine.swift:6-24`).
- The visualizer reads live PCM until analysis finishes.
- A completed download becomes a cache artifact, and Downloads can adopt it.

What is custom: `StreamingAudioPipeline` (705 lines), `StreamingAudioDecoder`
(403), `StreamingPCMBuffer` (225), roughly 250 streaming lines in
`AudioPlaybackEngine` (estimate), and about 60 lines of service recovery. About
1,650 lines in all. The decoder itself is Apple's `AudioFileStream` and
`AVAudioConverter`.

| Hybrid | Deletes | Regresses |
|---|---|---|
| H1. AVPlayer/AVQueuePlayer per track, two players for crossfade | ~1,650 lines, but adds a third engine adapter (~600, estimate). Rate and volume ramps cover part of SmartMix. | Transcodes would need HLS. PMS serves HLS: AAC, 1 s segments, verified with curl. Losses: SmartMix high-pass EQ and sound isolation (an `MTAudioProcessingTap` is unsupported on HLS, per Apple DTS); live-PCM visualizer on HLS; crossfade between a stream and a downloaded file in one graph; and the stream cache and Downloads adoption. AVQueuePlayer is gapless only for "gapless" files: AAC with priming info, MP3 with a LAME header, PCM/FLAC usually. There are iOS 17 gap reports, and PMS MP3 lacks the header. It also breaks plan §4.3 ("no added engines"). |
| H2. AVPlayer with `AVAssetResourceLoader` cache | Same as H1 | Same as H1, plus a custom range loader: custom machinery again. |
| H3. Platform downloads the whole file (download task with resume data), then the engine plays only files | Decoder, PCM ring, growing file and streaming source node: ~1,500 lines. One playback path; gapless and SmartMix untouched. | Start time becomes the full download: FLAC 18 MB ≈ 4.5 s, WAV 50 MB ≈ 12 s at the SE's 4 MB/s, versus ~0.9 s today. Seeking waits too. |
| **H0. Today's split, with its network layer repaired (A-D)** | The discard, reload and downgrade paths (~80 lines) | None |

Libraries and other players:

- **SFBAudioEngine** (MIT): AVAudioEngine-based, with a gapless player node and
  many decoders. Its HTTP input source was removed, so it is a local-file engine.
- **AudioStreaming** (dimitris-c): AVAudioEngine streaming with a gapless queue.
  It has no two-deck crossfade and no persistent cache. It was assessed and
  rejected in `streaming-cache-and-download-reuse.md`.
- **StreamingKit**: unmaintained.
- **AudioKit**: DSP only, no HTTP.
- **Finamp**: uses just_audio, which is AVQueuePlayer on iOS. FLAC gapless issues
  are reported.
- **Plexamp and foobar2000 mobile**: closed custom engines. Plexamp users report
  glitches between transcoded tracks on iOS.
- **Symfonium**: Android-only.

No package does HTTP progressive start, gapless, crossfade and resume together on iOS.

**Recommendation: H0.** It already is the hybrid Felicity asked for:

- Apple's player does gapless and SmartMix from files.
- Apple's `URLSession` does the transfer.
- The app keeps only the progressive start of the current track.

Make that start use standard HTTP resume. Reconsider H3 only if Felicity would
trade 4-12 s starts on lossless for one playback path.

## 5. Recommended plan

| Step | Work | Evidence needed |
|---|---|---|
| **a** | A: serialize direct downloads per server. | Unit test on the gate. One simulator run of 8731→8732, using the existing stream-delay injection so 8731 is still downloading. Pass when the PMS log shows no `Client stopped playback` for the in-flight part. Device smoke owed. |
| **b** | D: time-based network retry budget, and release the slot after the reload starts. | Unit tests only. |
| **c** | B: ranged resume for direct streams, and play the reserve first for transcodes. Add a DEBUG-only one-time drop injection beside `ENSEMBLE_AUTOMATION_STREAM_DELAY_*`. | Pipeline tests with `URLProtocol` stubs: a mid-body drop, a 206 with the same ETag, a changed ETag, and a 200. One simulator run with injection, where audio keeps advancing and state never shows buffering. Device: owed. |
| **c2** | Same change on the phone. | **Device required:** Wi-Fi → cellular mid-track on the iPhone 16 Pro, remote endpoint. |
| **d** | C: restart on path change; 15 s stream request timeout. | Unit test on the transition trigger. **Device required** for the real switch; do it in the same session as c2. |
| **e** | F: downward-only fallback, rebased from `fix/playback-recovery-stream`. | Unit tests with the saved damaged bytes. They are still present: 23 files in the earlier session's `scratchpad/fb/`. One simulator run on 11631. Device smoke owed for 11631. |
| later | E: transcode splice, only if c2 shows audible reload gaps on transcodes. | Device |

Each step is one worker. Order: a, b, c, d, e. Steps a and b fix the drops that
are observed now. c and d cover real network loss.

## 6. Open questions for Felicity

1. **Is streaming quality set to Original, and do drops mostly happen away from home?**
   The answer shows whether step a explains most of what you hear.
   Recommendation: check, but do step a either way.
2. **Serialize downloads (A) or add a session identifier per stream (A′)?**
   Recommendation: A. It does not depend on undocumented PMS behaviour.
3. **Do offline downloads of originals also wait while a stream is downloading?**
   Recommendation: yes, if the PMS log in step a shows they end the stream.
4. **Keep the engine and repair its network layer (H0), rather than adopting
   AVPlayer (H1) or downloading whole files first (H3)?** Recommendation: H0.
   H1 loses SmartMix EQ, sound isolation and the cache, and adds an engine. H3
   costs 4-12 s starts on lossless.
5. **Defer the transcode splice (E)?** Recommendation: defer.
6. **Should a damaged original that PMS answers with HTTP 400 (11700) fail rather
   than fall back?** Recommendation: fail. It is not media evidence, and PMS
   cannot convert it either.

Sources: [Apple DTS on taps and HLS](https://developer.apple.com/forums/thread/45966),
[AVQueuePlayer gapless](https://developer.apple.com/forums/thread/111413),
[SFBAudioEngine HTTP discussion](https://github.com/sbooth/SFBAudioEngine/discussions/206),
[AudioStreaming](https://github.com/dimitris-c/AudioStreaming),
[Plexamp transcoded gapless on iOS](https://forums.plex.tv/t/plexamp-not-true-gapless-on-ios-with-transcoded-opus/613762).

## Decisions (Felicity, 2026-11-10)

Steps a to e are approved. Her streaming quality is Original, and drops happen
mostly away from home, sometimes at home.

1. Step a waits for one direct download to finish before starting the next;
   no per-stream session tagging.
2. Offline downloads of originals wait behind a stream download only if the
   Plex log in step a shows they end the stream too. The offline download
   mechanism itself does not change.
3. A damaged original that Plex refuses with HTTP 400 fails; it does not fall
   back.
4. The engine split stays; only its network handling is repaired.
5. Joining a new transcode onto the buffered end is deferred unless the phone
   test shows audible gaps.

## Step e as built (2026-11-10)

- Damage is raised by the stream pipeline for a direct original only: a decoder error, bytes that are not
  audio, or decoded audio under half of what the file's own container states (11631 decodes 2:14 of a
  declared 4:39). A transcode, a network error and an HTTP status never raise it, so they never fall back.
  The stream's metadata-duration check no longer applies to an original.
- The fallback starts at the playhead, not at 0. Replaying heard audio is worse than the alternative, and
  an offset transcode has no length for the short-transcode check, so only decoder errors judge it. A
  fallback that starts from the beginning (damage found before any audio) is judged by that check as before.
- A prefetched original is decoded start to end before it is scheduled, and takes the same decision.
- Saved real bytes: 11631 ends at 2:14 and its transcode is as short (the fallback has nothing past 2:14, so
  the item fails and is skipped); 14291, 14292 and 14300 have a damaged original (decodes 2:27, 0:01 and
  0:08) and a complete transcode (the fallback plays on). 11700's zeroed header is damage; Plex answers
  its transcode with HTTP 400 and the item fails.

