# Media Streaming Endpoints

## CRITICAL: Universal Transcode is the Primary Streaming Path

**DO NOT use direct file URLs for streaming.** Direct file stream (`/library/parts/...`) returns 503 on some server configurations. The universal transcode endpoint is the only reliable streaming path.

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
add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=aac)
+add-transcode-target-codec(type=musicProfile&context=streaming&protocol=http&audioCodec=mp3)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=aac)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=mp3)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=flac)
+add-direct-play-codec(type=musicProfile&context=streaming&audioCodec=alac)
```

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


## Direct File Stream (BROKEN — do not use as primary path)

### `GET /library/parts/{partId}/{changestamp}/{filename}`

Direct audio file URL. **Returns 503 Service Unavailable** on some server configurations. Only used as a last resort fallback in the provider code, and only when the universal endpoint itself fails to construct a URL (not when AVPlayer fails to play it).

**URL construction:**
```
{serverURL}/library/parts/{partId}/{changestamp}/{filename}?X-Plex-Token={token}
```


## Universal Download URL (for offline downloads and playback)

Same as the universal stream URL. The decision call IS required before start.mp3 (PMS returns 400
without it). Each download uses a unique session ID so concurrent downloads do not conflict.

- Offline downloads: `PlexAPIClient.getUniversalDownloadURL()` — returns URL for URLSession download task (caller must call decision separately)
- Playback: `PlexAPIClient.downloadUniversalStreamToFile()` — calls decision + downloads to temp file, returns file URL for AVPlayer


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

**Fix:** `PlexAPIClient.downloadUniversalStreamToFile()` downloads the stream via URLSession (which handles chunked encoding correctly) to a temp file. AVPlayer receives a `file://` URL instead of a remote URL, bypassing CFHTTP entirely.

**DO NOT revert to giving AVPlayer remote transcode URLs.** The CFHTTP issue is in Apple's CoreMedia framework and cannot be worked around with AVURLAsset options or headers.


## CRITICAL: PMS start.mp3 is sensitive to query params and URL encoding

Two issues cause `start.mp3` to return **400 Bad Request** while `decision` returns 200:

1. **`X-Plex-Client-Profile-Name=generic`** — DO NOT include this query parameter. The decision endpoint tolerates it, but start.mp3 rejects it with 400.

2. **URLComponents `%3D` encoding** — Swift's `URLComponents` encodes `=` as `%3D` inside query parameter values. PMS's start.mp3 requires literal `=` inside `X-Plex-Client-Profile-Extra`. **Use `PlexAPIClient.buildTranscodeURL(path:queryItems:)`** instead, which manually encodes only `&` (as `%26`) and spaces (as `%20`).
