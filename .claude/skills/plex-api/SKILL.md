---
name: plex-api
description: "Plex Media Server API reference. Load when implementing or debugging Plex API integration."
---

# Plex Media Server API Reference

Based on Plex Media Server OpenAPI spec v1.2.0. Full spec: [openapi.json](openapi.json)

## Sub-Documents

Load the relevant document(s) based on what you're implementing:

| Document | Load when... |
|----------|--------------|
| [library-sync.md](library-sync.md) | Fetching library sections, artists, albums, tracks; incremental sync with timestamps |
| [playlists.md](playlists.md) | Creating, editing, deleting playlists; adding/removing/reordering items |
| [play-queues.md](play-queues.md) | Creating play queues for playback; shuffle, add next, queue management |
| [playback-tracking.md](playback-tracking.md) | Timeline reporting, scrobbling, rating items |
| [hubs-search.md](hubs-search.md) | Fetching hubs (recently added, etc.); search across library |
| [media-streaming.md](media-streaming.md) | Audio streaming URLs, image transcoding, loudness/waveform data |


## Common Headers

All requests require these headers:

| Header | Required | Description |
|--------|----------|-------------|
| `X-Plex-Token` | Yes | Auth token from plex.tv OAuth |
| `X-Plex-Client-Identifier` | Yes | Unique client ID |
| `X-Plex-Product` | No | Client name (e.g., `Ensemble`) |
| `X-Plex-Version` | No | Client version |
| `X-Plex-Platform` | No | Platform (e.g., `iOS`) |

Request JSON via `Accept: application/json` header. Default response is XML.


## Common Item Types

| Type | Value |
|------|-------|
| Artist | 8 |
| Album | 9 |
| Track | 10 |
| Playlist | 15 |


## URI Formats

```
# Single item
library://{libraryUUID}/item//library/metadata/{ratingKey}

# Directory contents
library://{libraryUUID}/directory//library/metadata/{ratingKey}/children

# All leaves (all tracks under artist/album)
library://{libraryUUID}/directory//library/metadata/{ratingKey}/allLeaves
```


## Testing Endpoints with curl

**Before implementing any Plex endpoint in code, test it with curl first.** This catches API quirks (like required parameters or call sequences) before they cause hard-to-debug runtime failures.

### Getting Test Credentials

```bash
# Get server access token from plex.tv (uses account token from browser console)
ACCOUNT_TOKEN="<from localStorage.getItem('myPlexAccessToken') in plex.tv>"
curl -s "https://plex.tv/api/v2/resources?includeHttps=1&X-Plex-Token=${ACCOUNT_TOKEN}&X-Plex-Client-Identifier=claude-test" \
  -H "Accept: application/json" | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    if r.get('provides') == 'server':
        print(f\"Server: {r['name']}\")
        print(f\"Token: {r['accessToken']}\")
        for c in r.get('connections', []):
            if c.get('local'): print(f\"  URL: {c['uri']}\")"
```

**Do NOT save tokens to files or memory.** Request fresh credentials each session.

### Basic Endpoint Testing

```bash
SERVER="https://192-168-x-x.xxxxx.plex.direct:32400"
TOKEN="<server access token>"

# Test basic connectivity
curl -s -k "${SERVER}/identity"

# List library sections
curl -s -k "${SERVER}/library/sections?X-Plex-Token=${TOKEN}" -H "Accept: application/json"

# Search for a track
curl -s -k "${SERVER}/library/sections/3/search?type=10&query=SongName&X-Plex-Token=${TOKEN}" -H "Accept: application/json"
```

### Testing Transcode Endpoints

The universal transcode endpoint requires a specific call sequence:

```bash
SESSION=$(python3 -c "import uuid; print(uuid.uuid4())")
CLIENT="test-$(date +%s)"
PROFILE="add-transcode-target-codec(type%3DmusicProfile%26context%3Dstreaming%26protocol%3Dhttp%26audioCodec%3Daac)%2Badd-transcode-target-codec(type%3DmusicProfile%26context%3Dstreaming%26protocol%3Dhttp%26audioCodec%3Dmp3)"

# Step 1: Call decision endpoint FIRST (required to warm up session)
curl -s -k "${SERVER}/music/:/transcode/universal/decision?path=/library/metadata/${RATING_KEY}&protocol=http&mediaIndex=0&partIndex=0&directPlay=0&directStream=1&directStreamAudio=1&hasMDE=1&musicBitrate=128&audioBitrate=128&X-Plex-Token=${TOKEN}&X-Plex-Client-Identifier=${CLIENT}&X-Plex-Session-Identifier=${SESSION}&session=${SESSION}&X-Plex-Product=Ensemble&X-Plex-Platform=iOS&X-Plex-Client-Profile-Extra=${PROFILE}" -H "Accept: application/json"

# Step 2: Now call start.mp3 (will return 400 without step 1!)
curl -s -k -o /dev/null -w "HTTP %{http_code}, Size: %{size_download} bytes\n" \
  "${SERVER}/music/:/transcode/universal/start.mp3?path=/library/metadata/${RATING_KEY}&protocol=http&mediaIndex=0&partIndex=0&directPlay=0&directStream=1&directStreamAudio=1&hasMDE=1&musicBitrate=128&audioBitrate=128&X-Plex-Token=${TOKEN}&X-Plex-Client-Identifier=${CLIENT}&X-Plex-Session-Identifier=${SESSION}&session=${SESSION}&X-Plex-Product=Ensemble&X-Plex-Platform=iOS&X-Plex-Client-Profile-Extra=${PROFILE}"
```

### Managing Transcode Sessions

```bash
# List active transcode sessions
curl -s -k "${SERVER}/transcode/sessions?X-Plex-Token=${TOKEN}" -H "Accept: application/json"

# Kill a stuck session
curl -s -k -X DELETE "${SERVER}/transcode/sessions/${SESSION_KEY}?X-Plex-Token=${TOKEN}"
```

### What to Document After Testing

After successfully testing an endpoint, note in commit messages or code comments:
- Required parameters that aren't obvious
- Call sequences (e.g., "decision before start")
- Error conditions discovered (e.g., "400 without Profile-Extra")
- Response format quirks


## Quick Reference

| Action | Endpoint | Method |
|--------|----------|--------|
| Get server info | `/` | GET |
| Get server identity | `/identity` | GET |
| List library sections | `/library/sections/all` | GET |
| Get section items | `/library/sections/{id}/all` | GET |
| Get item metadata | `/library/metadata/{id}` | GET |
| List playlists | `/playlists` | GET |
| Create play queue | `/playQueues` | POST |
| Report playback | `/:/timeline` | POST |
| Mark played | `/:/scrobble` | PUT |
| Transcode decision | `/music/:/transcode/universal/decision` | GET |
| Transcode stream | `/music/:/transcode/universal/start.mp3` | GET |
| List transcode sessions | `/transcode/sessions` | GET |
| Kill transcode session | `/transcode/sessions/{key}` | DELETE |
