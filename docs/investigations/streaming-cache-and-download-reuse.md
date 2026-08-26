# Streaming cache and download reuse

Research date: 2026-08-26

## Recommendation

Keep the growing-file plus signalled decoder-reader design. It is the smallest design that simultaneously:

- keeps `URLSession` ingestion independent from decoder/PCM backpressure;
- bounds memory for original or lossless tracks;
- produces a complete file that can survive replay; and
- allows a verified completed artifact to be promoted into the existing offline-download store.

There is no Apple API or current Swift package that removes this coordination without either waiting for the entire download, moving playback to `AVPlayer`, requiring HTTP byte-range support, or buffering whole tracks in memory.

The coordinator itself should be small and built from Apple primitives: `URLSessionDataTask` for incremental transport, separate `FileHandle`s for the writer and reader, `NSCondition` for byte-availability/EOF signalling, the existing `AudioFileStream` plus `AVAudioConverter` decoder, and `FileManager` for cache placement and atomic installation. The custom part is only the state that connects those APIs; it is not a replacement networking, decoding, or file-I/O stack.

## Current Ensemble behavior

- `StreamingAudioPipeline` and `ProgressiveStreamLoader` write uniquely suffixed files under `tmp/EnsembleStreamCache`.
- Cleanup keeps only the current track, the next two, the previous one, scheduled tracks, and active loaders. `PlaybackResolvedFileCache` separately remembers at most 10 resolved file URLs in memory.
- `PlaybackTransportCoordinator` can reuse a completed `ProgressiveStreamLoader`, but the live `StreamingAudioPipeline` completion callback is not connected to either cache. Its completed file may remain briefly because of filename-based cleanup, but it is not a durable replay hit.
- Partial and complete pipeline files have the same naming shape and no persisted quality/completeness record. Offline files instead live in `DownloadManager.downloadsDirectory` and are indexed by `OfflineDownloadService`/`DownloadManager`.

This means the intended “complete cache files remain useful for analysis and replay” behavior is only partially implemented today.

## Plex and Apple format compatibility

The design fits Plex's two audio delivery shapes, but they must keep different seek semantics:

- A direct `/library/parts/...` response is the original container and codec. Live PMS checks on 2026-08-26 returned `206 Partial Content`, `Accept-Ranges: bytes`, a concrete `Content-Length`, and the expected MIME type for FLAC, MP3, AAC-in-MP4, ALAC-in-MP4, and PCM/WAV samples. The growing file can preserve the original bytes, and a completed file can use ordinary local seeking. During growth, however, a time seek should still use an HTTP range or restart rather than guess a byte offset for VBR/compressed media.
- A universal `/music/:/transcode/universal/start.mp3` response is PMS-produced MP3. It requires the matching `decision` request first and returns a chunked response with no byte ranges or content length. It is therefore a natural append-only spool; seeking ahead must start a new transcode with `offset`, and any offset-started result is a fragment that cannot become a complete cache/download artifact.

Apple explicitly recommends Audio File Stream Services for network audio and documents streamed parsing for MP3, ADTS AAC, AIFF/AIFC, CAF, MPEG-4 (`.m4a`/`.mp4`), and WAVE. Current Audio Toolbox also exposes `kAudioFileFLACType`. A macOS 26.5 diagnostic using the same `AudioFileStreamOpen` plus `AVAudioConverter` primitives recognized and created converters for the five live PMS samples above. This is useful confirmation of the design, not a substitute for the required iOS 15 physical-device format matrix: current Ensemble tests exercise MP3 and M4A only, and its decoder supplies explicit hints only for MP3/M4A/AAC.

Practical consequences:

- Preserve Plex's actual container/codec and MIME type in completed-cache metadata; an extension alone is not sufficient. In particular, raw ADTS `.aac` requires `kAudioFileAAC_ADTSType`, while the current decoder treats `.aac` as M4A.
- MP3, AAC/M4A, and ALAC/M4A are the safest direct overlap with Apple's documented codecs. WAV/AIFF PCM are compatible but can consume the cache budget quickly. FLAC is supported by current Audio Toolbox, but needs one focused iOS deployment-range test before Ensemble advertises direct FLAC as guaranteed.
- Container headers can delay first packets: the live diagnostic needed about 360 KiB for its FLAC sample and 623 KiB for its AAC/M4A sample, versus 32 KiB for the tested MP3, ALAC/M4A, and WAV files. This is normal parser/header behavior, so prefetch watermarks should be based on “decoder produced packets,” not a fixed byte count.
- OGG/Vorbis, Opus, WMA, and other Plex-library formats are not declared in Ensemble's client profile and are outside the current decoder contract. Non-original playback should let PMS transcode them to MP3. Current original-quality routing bypasses the decision endpoint whenever a part key exists, so the implementation must gate direct originals on tested decoder/container support and otherwise request a transcode; do not cache an undecodable original merely because Plex can store it.
- An MP4/M4A whose `moov` metadata is at the end may not produce packets until most or all of the file arrives. The live samples were streamable near the front, but that property belongs to each file, not the codec. Use the parser's ready/first-packet signal for startup and fall back to PMS transcode for pathological direct originals rather than assuming every M4A is fast-start optimized.

Sources: [Plex Direct Play, Direct Stream, and Transcoding](https://support.plex.tv/articles/200250387-streaming-media-direct-play-and-direct-stream/), [Apple Audio File Stream Services guidance and streamed formats](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MultimediaPG/UsingAudio/UsingAudio.html), [Apple `AudioFileStreamOpen`](https://developer.apple.com/documentation/audiotoolbox/audiofilestreamopen(_:_:_:_:_:)), and [Apple Audio File Types](https://developer.apple.com/documentation/audiotoolbox/1576497-audio-file-types).

Use three file states with separate ownership:

1. **In-flight spool**: a unique partial file, owned by the active pipeline. Delete it on cancellation/failure and sweep abandoned partials at launch.
2. **Completed playback cache**: an immutable, reproducible file in `Library/Caches`, keyed by stable source/track plus the delivered media variant. Do not delete it when the track or queue finishes; retain it under a byte-budgeted LRU policy until storage pressure, explicit invalidation, or an OS purge.
3. **Offline download**: a durable, user-requested artifact owned and indexed by `OfflineDownloadService`/`DownloadManager`. Cache eviction must never touch it.

If a download is requested and a completed playback artifact exactly matches the requested source identity and acceptable quality, let the download owner validate it, copy it to a temporary destination beside the durable download, and atomically rename it before recording completion. Do not let the playback cache create or mutate download records. A transcoded playback file must not satisfy an `original` request merely because it is complete.

## Why the native shortcuts do not replace the spool

| Primitive | What Apple provides | Consequence for Ensemble |
| --- | --- | --- |
| `URLSessionDataTask` | Incremental response data is delivered to `urlSession(_:dataTask:didReceive:)`. | This is the appropriate network source for progressive decode, but Ensemble must write the chunks somewhere and coordinate the consumer. [Apple: `URLSessionDataDelegate`](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate) |
| `URLSession.AsyncBytes` | An `AsyncSequence<UInt8>` that processes a response while transfer is underway. It is available on Ensemble's full deployment range: iOS 15, macOS 12, and watchOS 8 or later. | It can replace delegate syntax, but it does not create a file or provide independent writer and reader cursors. Iterating it in the decoder path would preserve the same coupling; iterating it in a separate writer still needs the growing-file signal. The existing data delegate also provides useful chunk-sized `Data` values. [Apple: `bytes(for:delegate:)`](https://developer.apple.com/documentation/foundation/urlsession/bytes(for:delegate:)) |
| `URLSessionDownloadTask` | Foundation writes to a temporary file, reports byte counts, and provides the file URL only in `didFinishDownloadingTo` after success. The app must move it before that callback returns. | Excellent for a conventional offline download, but it cannot feed the decoder progressively. Waiting for completion would turn every play into a full-track download-before-play. [Apple: `URLSessionDownloadTask`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask) |
| `URLCache` | A memory/disk map from requests to whole `CachedURLResponse` values, governed by HTTP cache semantics. A cached response exposes its body as one `Data` value. The per-response cache callback applies to data/upload tasks, not background or ephemeral sessions. | It does not expose an append-only file or a progressive byte reader. It is also a poor stable identity layer for tokenized/transcode URLs and range requests. [Apple: accessing cached data](https://developer.apple.com/documentation/foundation/accessing-cached-data), [Apple: `CachedURLResponse`](https://developer.apple.com/documentation/foundation/cachedurlresponse) |
| `AVPlayer` / `AVQueuePlayer` | Native remote-file and HLS playback, decoding, buffering, seeking, stall recovery, and queueing. `preferredForwardBufferDuration` can express a desired current-item buffer. | This is the one native API that could remove the custom network-to-PCM path, but only by replacing Ensemble's `AVAudioEngine` playback owner and its two-deck SmartMix, time-pitch, EQ, and sound-isolation graph. It also does not expose its transient cache as a file that Ensemble can validate or adopt into Downloads. It remains the right native choice for Watch, where those engine-owned features are absent. [Apple: `AVPlayer`](https://developer.apple.com/documentation/avfoundation/avplayer), [Apple: `preferredForwardBufferDuration`](https://developer.apple.com/documentation/avfoundation/avplayeritem/preferredforwardbufferduration) |
| `AVAssetResourceLoaderDelegate` | Lets an `AVURLAsset` ask an app delegate for requested byte ranges; the delegate supplies data incrementally with `respond(with:)`. | It is an integration point for an `AVPlayer`-based custom cache, not a cache implementation. Ensemble would still own range fetching, partial-file indexing, cancellation, and persistence, while also replacing its player. The API is unavailable on watchOS. [Apple: resource-loader delegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate), [Apple: loading-data request](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest) |
| `AVAssetDownloadURLSession`, `AVAssetCache`, and `AVAssetDownloadStorageManager` | Background HLS persistence, inspection of offline AVAsset renditions, and expiration/priority-based automatic purging for downloaded AVAssets. | This is a complete native answer only for AVFoundation-managed HLS. Plex currently supplies progressive MP3/AAC or original files, and Ensemble needs stable source/quality metadata plus cache-to-download adoption. The storage manager and resource loader are also unavailable on watchOS. [Apple: `AVAssetDownloadURLSession`](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession), [Apple: offline playback and storage](https://developer.apple.com/documentation/avfoundation/offline-playback-and-storage), [Apple: `AVAssetDownloadStorageManager`](https://developer.apple.com/documentation/avfoundation/avassetdownloadstoragemanager) |
| `FileHandle`, `DispatchIO`, and `InputStream` | Native synchronous or asynchronous file/stream reads and writes. `DispatchIO` adds queue-based file-descriptor I/O and water marks; bound streams add a finite in-memory pipe. | Use separate `FileHandle`s because the URLSession delegate already runs off the audio render thread and writes are sequential. `DispatchIO` would add machinery without eliminating the need to signal new growth after a reader reaches the file's current EOF. A bound stream eventually blocks its writer when its finite buffer fills and recreates backpressure. [Apple: `FileHandle`](https://developer.apple.com/documentation/foundation/filehandle), [Apple: `DispatchIO`](https://developer.apple.com/documentation/dispatch/dispatchio), [Apple: bound streams](https://developer.apple.com/documentation/foundation/uploading-streams-of-data) |
| `NSCondition` | A native lock plus predicate-based checkpoint: waiters block until signalled, then retest the protected predicate. | This directly implements the growing-file notification. Protect `availableByteCount`, terminal error, cancellation, and EOF with one condition; signal after append and broadcast at termination. No custom polling or concurrency framework is needed. [Apple: `NSCondition`](https://developer.apple.com/documentation/foundation/nscondition) |
| Audio File Stream Services plus `AVAudioConverter` | Apple parses limited windows of streamed audio, preserving partial packets across calls, then decodes compressed packets to PCM. | Ensemble already uses the correct native parser and converter. Keep them, but call them from the decoder reader rather than the URLSession delegate so PCM backpressure cannot block network ingestion. [Apple: Audio File Stream Services](https://developer.apple.com/documentation/audiotoolbox/audio-file-stream-services), [Apple: `AVAudioConverter`](https://developer.apple.com/documentation/avfaudio/avaudioconverter) |

### Native pieces to use

- Keep `URLSessionDataTask` and `URLSessionTaskMetrics`; the latter already supplies per-request DNS, connection, TLS, time-to-first-byte, protocol, reuse, proxy, and transfer timing. [Apple: `URLSessionTaskMetrics`](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics)
- Keep `AudioFileStreamParseBytes` and `AVAudioConverter`; they are explicitly designed for streamed compressed audio and PCM conversion.
- Use two `FileHandle`s and one `NSCondition` rather than a custom stream type, polling loop, `DispatchIO` channel, or pipe.
- Use `URL.cachesDirectory` for completed replay artifacts and Foundation's `Codable` for the small completion manifest. Apple identifies Caches as the location for purgeable transient downloadable content. [Apple: using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
- Use `FileManager.replaceItemAt` for same-volume durable installation after validation; Apple documents it as replacement that ensures no data loss. [Apple: `replaceItemAt`](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:))
- Keep the byte-budgeted LRU as a directory scan over completed manifests. Apple has no general file-cache eviction API with Ensemble's source/quality identity and active-file leases; `AVAssetDownloadStorageManager` applies only to AVFoundation-downloaded assets.

All of these selected primitives are available on iOS 15 and macOS 12. The transport, file, condition, parser, and converter primitives also cover watchOS 10; `AVAssetResourceLoader` and `AVAssetDownloadStorageManager` do not. Watch should therefore continue to let `AVPlayer` own direct-file streaming rather than share the main app's cache implementation.

`Library/Caches` is the correct home for completed replayable streams. Apple describes `tmp` as suitable for one-time, short-lived files that need not persist between launches, while `Caches` is for longer-lived but purgeable data that improves performance, including transient downloadable content. Neither is backed up. [Apple: using the file system effectively](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)

The simpler alternatives each drop a required property:

- A bounded in-memory encoded FIFO still needs suspend/resume flow control when full and cannot be reused after completion. An unbounded FIFO is unsafe on Ensemble's 2 GB-device floor.
- A pipe or bound stream eventually blocks its writer when the decoder/PCM path stalls, recreating the network-ingestion problem.
- `URLSessionDownloadTask` removes the custom writer only by removing progressive startup.
- Polling a growing file is simpler mechanically but wastes wakeups and adds latency. A condition/semaphore signalled after each append and at EOF is the minimal reliable coordination.

## What established implementations do

AndroidX Media3 is the clearest public production model:

- Its cache contract supports **partial caching of resources**, and `CacheDataSource` reads cached spans while fetching and writing misses from an upstream source. [Media3 cache package](https://developer.android.com/reference/androidx/media3/datasource/cache/package-summary), [`CacheDataSource`](https://developer.android.com/reference/androidx/media3/datasource/cache/CacheDataSource)
- Its transient cache can use `LeastRecentlyUsedCacheEvictor(maxBytes)`. [Media3 `LeastRecentlyUsedCacheEvictor`](https://developer.android.com/reference/androidx/media3/datasource/cache/LeastRecentlyUsedCacheEvictor)
- Its offline guide deliberately uses `SimpleCache` with `NoOpCacheEvictor`, persists download state separately in `DownloadIndex`, and points playback at the same download cache. That separation means user downloads do not disappear under normal cache pressure. [Media3: downloading media](https://developer.android.com/media/media3/exoplayer/downloading-media)

The reusable lesson is the policy boundary, not the Android classes: one read-through media layer, explicit persistent download state, and different eviction rules for transient versus user-owned artifacts.

Spotify's public engineering material confirms that its client fetches encoded track files in chunks (historically 512 KB HTTP range requests), and its Lite client exposes cache and downloads as separate storage categories. It does not publish enough detail to infer a cache-to-download promotion or cleanup policy. [Spotify Engineering: smoother streaming](https://engineering.atspotify.com/2018/08/smoother-streaming-with-bbr/), [Spotify Engineering: Spotify Lite](https://engineering.atspotify.com/2020/12/how-we-built-it-spotify-lite-one-year-later/)

## Build versus buy

### Full playback/cache package: do not adopt

The closest current packages replace too much or assume the wrong transport:

- [`AudioStreaming`](https://github.com/dimitris-c/AudioStreaming) is MIT-licensed, uses `AVAudioEngine`/Core Audio, and was updated in January 2026. Its current network configuration explicitly disables `URLCache`, and it exposes streaming/local playback rather than persistent playback-cache/download promotion. It also requires macOS 13 while Ensemble supports macOS 12. Adopting it would replace a large portion of Ensemble's playback engine without solving the retention policy. [network configuration](https://github.com/dimitris-c/AudioStreaming/blob/main/AudioStreaming/Core/Network/NetworkingClient.swift), [package platforms](https://github.com/dimitris-c/AudioStreaming/blob/main/Package.swift), [license](https://github.com/dimitris-c/AudioStreaming/blob/main/LICENSE)
- [`ZPlayerCacher`](https://github.com/ZhgChgLi/ZPlayerCacher) is MIT-licensed and was updated in December 2025, but it is an `AVAssetResourceLoaderDelegate` adapter for `AVPlayer`. Its remote strategy first requires `Content-Range` and `Accept-Ranges`, and its local strategy repeatedly materializes accumulated media as `Data`. That is a poor match for Plex chunked transcodes, Ensemble's `AVAudioEngine` pipeline, and low-memory devices. [remote range requirements](https://github.com/ZhgChgLi/ZPlayerCacher/blob/main/Sources/ZPlayerCacher/DataFetcherStrategy/RemoteDataFetcherStrategy.swift), [cached-data implementation](https://github.com/ZhgChgLi/ZPlayerCacher/blob/main/Sources/ZPlayerCacher/DataFetcherStrategy/LocalDataFetcherStrategy.swift), [license](https://github.com/ZhgChgLi/ZPlayerCacher/blob/main/LICENSE)
- [`SwiftAudioPlayer`](https://github.com/tanhakabir/SwiftAudioPlayer) combines streaming and a separate background downloader, but its last source commit is from 2021, its package declares iOS/tvOS only, and it would likewise replace the player instead of contributing a file-spool/cache primitive. It is not a viable foundation for this change. [package manifest](https://github.com/tanhakabir/SwiftAudioPlayer/blob/master/Package.swift), [license](https://github.com/tanhakabir/SwiftAudioPlayer/blob/master/LICENSE)

### Generic disk-cache package: possible, but no net simplification

Nuke 12.8 is already installed in Ensemble. Its generic `DataCache` provides a file-per-key LRU directory, a byte limit, URL lookup, and periodic sweeps. However, its normal store/read API takes whole `Data` values and it has no lease/pin API to prevent an automatic sweep from deleting an artifact currently being decoded. [`DataCache` 12.8 source](https://github.com/kean/Nuke/blob/12.8.0/Sources/Nuke/Caching/DataCache.swift)

It could safely own eviction only if it managed a directory containing **completed playback artifacts only**, while Ensemble separately protected active files and continued to own partial spools and durable downloads. Those qualifications require nearly the same lifecycle code as a small native sweep. Reusing the existing `PlaybackPrefetchController` cleanup path with `FileManager`, explicit access dates, a byte budget, and an active-file keep set is therefore smaller and easier to reason about.

Reconsider a generic cache dependency only if the policy later needs a durable index, cross-process coordination, or measured cleanup cost that the directory scan cannot handle. Even then, the package should own only completed transient artifacts, never network ingestion, decoder flow control, or offline-download records.

## Minimal policy to implement

- Commit to the completed cache only after clean EOF and existing duration/payload validation.
- Cache only full-track, offset-zero artifacts initially; discard seek fragments and failed/cancelled partials.
- Key by stable playback identity plus delivery variant (at minimum source, quality, codec/container, and any source revision available from Plex metadata), not by the expiring request URL.
- On a cache hit, update an explicit access timestamp and decode the immutable local file.
- Evict least-recently-used completed files when the directory exceeds a fixed byte budget; never evict active/current files.
- Sweep stale partials on launch. Treat every cache lookup as optional because iOS may purge `Caches` while Ensemble is not running.
- Promotion to offline must be an `OfflineDownloadService` operation: validate identity, quality, nonzero size, and duration; place the file atomically in `DownloadManager.downloadsDirectory`; then persist completion. If any check fails, use the existing download path.
