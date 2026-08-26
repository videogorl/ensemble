# Streaming cache and download reuse

Research date: 2026-08-26

## Recommendation

Keep the growing-file plus signalled decoder-reader design. It is the smallest design that simultaneously:

- keeps `URLSession` ingestion independent from decoder/PCM backpressure;
- bounds memory for original or lossless tracks;
- produces a complete file that can survive replay; and
- allows a verified completed artifact to be promoted into the existing offline-download store.

There is no Apple API or current Swift package that removes this coordination without either waiting for the entire download, moving playback to `AVPlayer`, requiring HTTP byte-range support, or buffering whole tracks in memory.

## Current Ensemble behavior

- `StreamingAudioPipeline` and `ProgressiveStreamLoader` write uniquely suffixed files under `tmp/EnsembleStreamCache`.
- Cleanup keeps only the current track, the next two, the previous one, scheduled tracks, and active loaders. `PlaybackResolvedFileCache` separately remembers at most 10 resolved file URLs in memory.
- `PlaybackTransportCoordinator` can reuse a completed `ProgressiveStreamLoader`, but the live `StreamingAudioPipeline` completion callback is not connected to either cache. Its completed file may remain briefly because of filename-based cleanup, but it is not a durable replay hit.
- Partial and complete pipeline files have the same naming shape and no persisted quality/completeness record. Offline files instead live in `DownloadManager.downloadsDirectory` and are indexed by `OfflineDownloadService`/`DownloadManager`.

This means the intended “complete cache files remain useful for analysis and replay” behavior is only partially implemented today.

Use three file states with separate ownership:

1. **In-flight spool**: a unique partial file, owned by the active pipeline. Delete it on cancellation/failure and sweep abandoned partials at launch.
2. **Completed playback cache**: an immutable, reproducible file in `Library/Caches`, keyed by stable source/track plus the delivered media variant. Do not delete it when the track or queue finishes; retain it under a byte-budgeted LRU policy until storage pressure, explicit invalidation, or an OS purge.
3. **Offline download**: a durable, user-requested artifact owned and indexed by `OfflineDownloadService`/`DownloadManager`. Cache eviction must never touch it.

If a download is requested and a completed playback artifact exactly matches the requested source identity and acceptable quality, let the download owner validate it, copy it to a temporary destination beside the durable download, and atomically rename it before recording completion. Do not let the playback cache create or mutate download records. A transcoded playback file must not satisfy an `original` request merely because it is complete.

## Why the native shortcuts do not replace the spool

| Primitive | What Apple provides | Consequence for Ensemble |
| --- | --- | --- |
| `URLSessionDataTask` | Incremental response data is delivered to `urlSession(_:dataTask:didReceive:)`. | This is the appropriate network source for progressive decode, but Ensemble must write the chunks somewhere and coordinate the consumer. [Apple: `URLSessionDataDelegate`](https://developer.apple.com/documentation/foundation/urlsessiondatadelegate) |
| `URLSessionDownloadTask` | Foundation writes to a temporary file, reports byte counts, and provides the file URL only in `didFinishDownloadingTo` after success. The app must move it before that callback returns. | Excellent for a conventional offline download, but it cannot feed the decoder progressively. Waiting for completion would turn every play into a full-track download-before-play. [Apple: `URLSessionDownloadTask`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask) |
| `URLCache` | A memory/disk map from requests to whole `CachedURLResponse` values, governed by HTTP cache semantics. Its per-response cache callback applies to data/upload tasks, not background or ephemeral sessions. Upload and download tasks do not use URL loading-system caching. | It does not expose an append-only file or a progressive byte reader. It is also a poor stable identity layer for tokenized/transcode URLs and range requests. [Apple: accessing cached data](https://developer.apple.com/documentation/foundation/accessing-cached-data), [Apple: cache policy](https://developer.apple.com/documentation/foundation/nsmutableurlrequest/cachepolicy) |
| `AVAssetDownloadURLSession` | Background persistence and offline storage management for HTTP Live Streaming assets. | Useful if Plex delivery is changed to HLS and playback is handed to AVFoundation's HLS stack; it is not a general progressive MP3/FLAC spool. [Apple: `AVAssetDownloadURLSession`](https://developer.apple.com/documentation/avfoundation/avassetdownloadurlsession), [Apple: offline playback and storage](https://developer.apple.com/documentation/avfoundation/offline-playback-and-storage) |

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
