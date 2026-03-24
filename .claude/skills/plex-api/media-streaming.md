# Media Streaming Endpoints

## Streaming Strategy: Direct Stream First, Transcode Fallback

Ensemble uses smart routing via `PlexAPIClient.resolveStreamURL()`:

1. **Original quality + stream key** → direct file URL (no decision call). Instant playback (<1s).
2. **Non-original quality** → call decision endpoint:
   - `directplay` or `copy` → direct file URL (<1s startup)
   - `transcode` → **progressive stream** via `ProgressiveStreamLoader` (~1-2s startup)
3. **No stream key** → progressive transcode stream (decision call + start.mp3).

Direct file stream (`/library/parts/...`) returns proper HTTP headers (`Accept-Ranges: bytes`, `Content-Length`, `206 Partial Content`) that AVPlayer handles natively.

Progressive transcode uses `AVAssetResourceLoaderDelegate` with custom `ensemble-transcode://` URL scheme to bridge PMS's chunked `Transfer-Encoding` response to AVPlayer. Data is written to a growing temp file and served to AVPlayer as it arrives. Post-download: XING header injection + frequency analysis via `onDownloadComplete` callback.

Tracks that fail with direct stream are tracked in `PlexMusicSourceSyncProvider.directStreamFailedKeys` and automatically skip to the download path on retry. Cleared on connection refresh.

**DO NOT "disable universal endpoint" as a fix for playback failures.** Curl testing has confirmed the universal endpoint returns valid audio data. The "resource unavailable" error is an AVPlayer-specific issue, not a server problem.

**ALWAYS test with curl before making streaming code changes.** Token is in `.env` at project root.


## Universal Transcode Endpoint (Primary — use this)

### Step 1: `GET /music/:/transcode/universal/decision` (REQUIRED)
Warm up the transcode session. **MUST be called before start.mp3** or PMS returns HTTP 400.
Each download should use a unique `X-Plex-Session-Identifier` / `session` / `transcodeSessionId`
so concurrent prefetch downloads do not conflict with each other.
Only accept HTTP 200 from this endpoint — 400 means the session was NOT warmed up.

### Step 2: `GET /music/:/transcode/universal/start.mp3`
Stream the transcoded audio. Uses the same query parameters as the decision call.

**Required parameters:**
- `path`: `/library/metadata/{ratingKey}` (URL-encoded)
- `protocol`: `http` (HLS not supported for music on all PMS versions)
- `mediaIndex`: `0`
- `partIndex`: `0`
- `directPlay`: `0` (prevents redirect to raw file URL)
- `directStream`: `1` (streams original codec through PMS pipeline)
- `directStreamAudio`: `1`
- `hasMDE`: `1`
- `X-Plex-Token`: Auth token
- `X-Plex-Client-Identifier`: Unique client ID
- `X-Plex-Session-Identifier`: Session UUID (must match between decision and start)
- `transcodeSessionId`: Same session UUID
- `session`: Same session UUID
- `X-Plex-Product`, `X-Plex-Platform`, `X-Plex-Device`: Client metadata
- `X-Plex-Client-Profile-Extra`: Codec capabilities (see below)

**Quality-specific parameters:**
- Original: no bitrate params (uses `directStream=1`)
- High: `musicBitrate=320&audioBitrate=320`
- Medium: `musicBitrate=192&audioBitrate=192`
- Low: `musicBitrate=128&audioBitrate=128`

**Client profile extra (codec declarations):**
```
add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=mp3)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=aac)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=mp3)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=flac)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=alac)
```
**Note:** AAC is a direct-play codec only, NOT a transcode target. PMS silently produces 0-byte output when transcoding high-sample-rate FLAC (96kHz/24-bit) → AAC. MP3 is the only safe transcode output codec.

**Response characteristics (important for AVPlayer):**
```
HTTP/1.1 200 OK
Content-Type: audio/mpeg
Transfer-Encoding: chunked
Accept-Ranges: none
Connection: close
Cache-Control: no-cache
```
- No `Content-Length` header — stream length is unknown upfront
- Chunked encoding — data arrives in chunks
- No range requests supported
- Connection closes after transfer
- These characteristics may cause AVPlayer issues (active investigation)

**curl test pattern:**
```bash
source .env  # loads PLEX_ACCESS_TOKEN and PLEX_SERVER_URL
SESSION_ID="test-$(date +%s)"

# Decision first
curl -s -o /dev/null -w "Decision: %{http_code}\n" \
  "${PLEX_SERVER_URL}/music/:/transcode/universal/decision?path=%2Flibrary%2Fmetadata%2F8785&protocol=http&mediaIndex=0&partIndex=0&directPlay=0&directStream=1&directStreamAudio=1&hasMDE=1&musicBitrate=128&audioBitrate=128&X-Plex-Token=$PLEX_ACCESS_TOKEN&X-Plex-Client-Identifier=curl-test&X-Plex-Session-Identifier=$SESSION_ID&session=$SESSION_ID&X-Plex-Product=Ensemble&X-Plex-Platform=iOS"

# Then stream
curl -s -o /dev/null -w "Stream: %{http_code} Size: %{size_download}\n" \
  "${PLEX_SERVER_URL}/music/:/transcode/universal/start.mp3?path=%2Flibrary%2Fmetadata%2F8785&protocol=http&mediaIndex=0&partIndex=0&directPlay=0&directStream=1&directStreamAudio=1&hasMDE=1&musicBitrate=128&audioBitrate=128&X-Plex-Token=$PLEX_ACCESS_TOKEN&X-Plex-Client-Identifier=curl-test&X-Plex-Session-Identifier=$SESSION_ID&session=$SESSION_ID&X-Plex-Product=Ensemble&X-Plex-Platform=iOS"
```


## Direct File Stream (Used for direct-play and copy decisions)

### `GET /library/parts/{partId}/{changestamp}/{filename}`

Direct audio file URL. Now the **preferred streaming path** when PMS determines no transcoding is needed (directplay/copy decision). Returns proper HTTP headers for native AVPlayer streaming:

```
HTTP/1.1 200 OK
Accept-Ranges: bytes
Content-Length: {fileSize}
Connection: Keep-Alive
```

Supports `206 Partial Content` for byte range requests (verified). AVPlayer can seek and report accurate progress.

**URL construction:**
```
{serverURL}/library/parts/{partId}/{changestamp}/{filename}?X-Plex-Token={token}&X-Plex-Client-Identifier={clientId}
```

Built by `PlexAPIClient.getStreamURL(trackKey:)` using the track's stored `streamURL` (part key).


## Universal Download URL (for offline downloads and genuine transcodes)

Same as the universal stream URL. The decision call IS required before start.mp3 (PMS returns 400
without it). Each download uses a unique session ID so concurrent downloads do not conflict.

- Offline downloads: `PlexAPIClient.getUniversalDownloadURL()` — returns URL for URLSession download task (caller must call decision separately)
- Playback (transcode needed): `PlexAPIClient.downloadUniversalStreamToFile()` — calls decision + downloads to temp file, returns file URL for AVPlayer
- Playback (smart routing): `PlexAPIClient.resolveStreamURL()` — calls decision, returns `.directStream(URL)`, `.downloadedFile(URL)`, or `.progressiveTranscode(ProgressiveStreamConfig)` based on PMS decision
- Progressive streaming: `ProgressiveStreamLoader` (EnsembleCore) — AVAssetResourceLoaderDelegate that bridges chunked transcode to AVPlayer via `ensemble-transcode://` custom URL scheme


## Waveform / Loudness Data

### `GET /library/streams/{streamId}/loudness`
Get loudness timeline data for waveform visualization.

**Parameters:**
- `streamId` (required): Audio stream ID from track metadata
- `subsample` (optional): Downsampling factor

**Response:** Array of loudness values over time, suitable for waveform rendering.

**Getting streamId:** Found in track metadata at `Media.Part.Stream[].id` where `streamType=2` (audio).


## Image Transcoding

### `GET /photo/:/transcode`
Transcode/resize images (artwork, thumbnails).

**Parameters:**
- `url` (required): Source image path (relative to server)
- `width` (optional): Desired width in pixels
- `height` (optional): Desired height in pixels
- `minSize` (optional): `1` to scale to fit smaller dimension
- `upscale` (optional): `0` to prevent upscaling beyond original
- `format` (optional): Output format (`jpg`, `png`)
- `quality` (optional): Output quality (0-100)

**URL construction:**
```
{serverURL}/photo/:/transcode?url={encodedPath}&width=300&height=300&X-Plex-Token={token}
```

**Common source paths:**
- Album art: `/library/metadata/{ratingKey}/thumb/{timestamp}`
- Artist art: `/library/metadata/{ratingKey}/thumb/{timestamp}`


## Transcode Session Management

```bash
# List active transcode sessions
curl -s "${PLEX_SERVER_URL}/transcode/sessions?X-Plex-Token=${TOKEN}" -H "Accept: application/json"

# Kill a stuck session
curl -s -X DELETE "${PLEX_SERVER_URL}/transcode/sessions/${SESSION_KEY}?X-Plex-Token=${TOKEN}"
```


## RESOLVED: AVPlayer "resource unavailable" / CFHTTP -16845

**Root cause:** AVPlayer's CoreMedia HTTP stack (CFHTTP) cannot handle PMS's chunked transcode response (`Transfer-Encoding: chunked`, no `Content-Length`, `Connection: close`). This causes CFHTTP error -16845, which surfaces as `NSURLErrorResourceUnavailable` (-1008). After the first failure, the stale transcode session on PMS causes subsequent requests to return HTTP 400.

**Fix:** `PlexAPIClient.downloadUniversalStreamToFile()` downloads the stream via URLSession (which handles chunked encoding correctly) to a temp file, then injects a XING header for VBR duration accuracy. AVPlayer receives a `file://` URL instead of a remote URL, bypassing CFHTTP entirely.

**DO NOT revert to giving AVPlayer remote transcode URLs.** The CFHTTP issue is in Apple's CoreMedia framework and cannot be worked around with AVURLAsset options or headers.

**DO NOT re-add CAF conversion.** A previous approach converted downloaded MP3s to uncompressed CAF (PCM) for zero-gap gapless playback. This created ~60MB files per 5-min track (vs ~6MB for MP3), causing linear memory growth on low-RAM devices and 13-second blocking downloads. XING header injection provides sufficient gapless metadata at negligible cost.


## RESOLVED: VBR MP3 duration overestimate / FigFilePlayer err=-12864

**Root cause:** PMS's universal transcode produces VBR MP3 files without XING/LAME headers. AVPlayer can't determine the true duration or frame layout, causing duration overestimation (e.g., 270s vs actual 195s), FigFilePlayer errors at file boundaries, and broken gapless transitions.

**Fix:** `MP3VBRHeaderUtility.injectXingHeaderIfNeeded()` scans the downloaded file's MPEG frames and prepends a XING header frame with accurate frame count, total byte count, and LAME gapless metadata. Called automatically after `downloadUniversalStreamToFile()` for non-original quality.

**Key facts:**
- PMS always outputs MP3 regardless of transcode profile or start path (tested AAC-only profile, `start.m4a`, `start` — all return `audio/mpeg`)
- The XING frame includes a LAME extension with encoder delay (576 samples, standard for ffmpeg/libmp3lame) and padding (calculated from Plex metadata duration), enabling AVPlayer to trim silence at track boundaries for gapless playback
- Frame count duration matches Plex metadata: 195.81s vs 195.78s (previously AVPlayer reported 270.29s)
- `effectiveDuration()` caps AVPlayer's duration to metadata when >10% over, as a safety net
- Metadata duration is threaded from `Track.duration` through `SyncCoordinator` → `PlexMusicSourceSyncProvider` → `PlexAPIClient.downloadUniversalStreamToFile()` → `MP3VBRHeaderUtility`


## CRITICAL: PMS start.mp3 is sensitive to query params and URL encoding

Two issues cause `start.mp3` to return **400 Bad Request** while `decision` returns 200:

1. **`X-Plex-Client-Profile-Name=generic`** — DO NOT include this query parameter. The decision endpoint tolerates it, but start.mp3 rejects it with 400.

2. **URLComponents `%3D` encoding** — Swift's `URLComponents` encodes `=` as `%3D` inside query parameter values. PMS's start.mp3 requires literal `=` inside `X-Plex-Client-Profile-Extra`. **Use `PlexAPIClient.buildTranscodeURL(path:queryItems:)`** instead, which uses `addingPercentEncoding(withAllowedCharacters:)` with `urlQueryAllowed` minus `&` — this keeps `=`, `+`, `(`, `)` literal as PMS requires while properly encoding non-ASCII characters (critical for iOS 15 URL parser compatibility).
