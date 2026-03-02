# Media Streaming Endpoints

## Audio Streaming

### `GET /library/parts/{partId}/{changestamp}/{filename}`
Direct audio file streaming URL.

**URL construction:**
```
{serverURL}/library/parts/{partId}/{changestamp}/{filename}?X-Plex-Token={token}
```

**Fields from track metadata:**
- `partId`: From `Media.Part.id`
- `changestamp`: From `Media.Part.key` path (number after `/library/parts/`)
- `filename`: From `Media.Part.file` (basename)

**Example:**
```
https://server.plex.direct:32400/library/parts/12345/1234567890/song.flac?X-Plex-Token=xxx
```


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

**Example - 300x300 album art:**
```
/photo/:/transcode?url=%2Flibrary%2Fmetadata%2F123%2Fthumb%2F1234567&width=300&height=300&minSize=1
```


## Transcoding (Audio Conversion)

For audio transcoding (format conversion, bitrate limiting):

### `GET /{transcodeType}/:/transcode/universal/decision`
Get transcoding decision (direct play vs transcode).

### `GET /{transcodeType}/:/transcode/universal/start.*`
Start transcoded stream.

**Note:** For music, direct streaming is usually preferred. Transcoding is typically only needed for:
- Format incompatibility (rare for audio)
- Bandwidth limiting on cellular


## Constructing Playback URLs

**Direct play (preferred for audio):**
```swift
let url = "\(serverURL)/library/parts/\(partId)/\(changestamp)/\(filename)"
    + "?X-Plex-Token=\(token)"
```

**With artwork:**
```swift
let artworkURL = "\(serverURL)/photo/:/transcode"
    + "?url=\(encodedThumbPath)"
    + "&width=300&height=300&minSize=1"
    + "&X-Plex-Token=\(token)"
```
