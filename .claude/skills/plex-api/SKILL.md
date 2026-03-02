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
