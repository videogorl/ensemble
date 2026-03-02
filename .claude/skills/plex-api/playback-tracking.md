# Playback Tracking Endpoints

## Timeline Reporting

### `POST /:/timeline`
Report playback progress. Call periodically during playback (e.g., every 10 seconds).

**Parameters:**
- `ratingKey` (required): Item's rating key
- `key` (optional): Details key (e.g., `/library/metadata/123`)
- `state` (required): `playing`, `paused`, or `stopped`
- `time` (required): Current position in milliseconds
- `duration` (required): Total duration in milliseconds
- `playQueueItemID` (optional): Play queue item ID if using queues
- `continuing` (optional): `1` if playback will continue after stop

**Example - report playing:**
```
POST /:/timeline?ratingKey=123&state=playing&time=45000&duration=180000
```

**Best practices:**
- Report every 10 seconds during playback
- Report on pause/resume with updated state
- Report on stop with `state=stopped`
- Include `playQueueItemID` when using play queues


## Scrobbling

### `PUT /:/scrobble`
Mark item as played. Typically called at 90% completion.

**Parameters:**
- `identifier` (required): Media provider ID (use `com.plexapp.plugins.library`)
- `key` (required): Rating key of item

**Example:**
```
PUT /:/scrobble?identifier=com.plexapp.plugins.library&key=123
```

---

### `PUT /:/unscrobble`
Mark item as unplayed.

**Parameters:**
- `identifier` (required): Media provider ID
- `key` (required): Rating key

**Example:**
```
PUT /:/unscrobble?identifier=com.plexapp.plugins.library&key=123
```


## Rating

### `PUT /:/rate`
Rate an item.

**Parameters:**
- `identifier` (required): Media provider ID (use `com.plexapp.plugins.library`)
- `key` (required): Rating key of item
- `rating` (required): Rating value (0-10 scale, or -1 to remove rating)

**Example - rate 8/10:**
```
PUT /:/rate?identifier=com.plexapp.plugins.library&key=123&rating=8
```

**Example - remove rating:**
```
PUT /:/rate?identifier=com.plexapp.plugins.library&key=123&rating=-1
```


## Playback Sessions

### `GET /status/sessions`
Get active playback sessions across all clients.

**Use cases:**
- Display "now playing" across devices
- Detect conflicts

---

### `GET /status/sessions/history/all`
Get playback history.

**Use cases:**
- Recently played
- Listening statistics


## Typical Flow

1. **Start playback:** Create play queue or begin streaming
2. **Report timeline:** Every 10s with `state=playing`, current `time`
3. **On pause:** Report with `state=paused`
4. **On resume:** Report with `state=playing`
5. **At 90%:** Call scrobble to mark as played
6. **On stop:** Report with `state=stopped`
