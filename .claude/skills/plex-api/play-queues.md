# Play Queue Endpoints

Play queues represent the current playback session. They're ephemeral and managed by the server.

## Create

### `POST /playQueues`
Create a play queue for playback.

**Parameters:**
- `type` (required): Queue type (`audio`, `video`)
- `uri` (optional): Content URI to play
- `playlistID` (optional): Playlist to create queue from
- `key` (optional): Key of first item to play
- `shuffle` (optional): `1` to shuffle, `0` for sequential
- `repeat` (optional): `0`=none, `1`=repeat one, `2`=repeat all
- `continuous` (optional): Continue with related content

**Example - play album:**
```
POST /playQueues?type=audio&uri=library://abc-123/item//library/metadata/456
```

**Example - play shuffled playlist:**
```
POST /playQueues?type=audio&playlistID=789&shuffle=1
```


## Retrieve

### `GET /playQueues/{playQueueId}`
Get play queue contents.

**Parameters:**
- `playQueueId` (required): Queue ID
- `own` (optional): Transfer ownership to requesting client
- `center` (optional): Center item ID for windowed retrieval
- `window` (optional): Items on each side of center
- `includeBefore` (optional): Include items before center
- `includeAfter` (optional): Include items after center

**Windowed retrieval:** For large queues, use `center` + `window` to fetch a subset around the current track.


## Modify

### `PUT /playQueues/{playQueueId}`
Add items to existing play queue.

**Parameters:**
- `playQueueId` (required): Queue ID
- `uri` (optional): Content URI to add
- `playlistID` (optional): Playlist to add
- `next` (optional): `1` to play next, `0` to queue at end

**Example - add track to play next:**
```
PUT /playQueues/123?uri=library://abc/item//library/metadata/456&next=1
```


## Shuffle

### `PUT /playQueues/{playQueueId}/shuffle`
Shuffle the play queue.

### `PUT /playQueues/{playQueueId}/unshuffle`
Unshuffle (restore original order).


## Remove & Reorder

### `DELETE /playQueues/{playQueueId}/items/{playQueueItemId}`
Remove item from play queue.

**Parameters:**
- `playQueueId` (required): Queue ID
- `playQueueItemId` (required): Item's queue-specific ID

---

### `PUT /playQueues/{playQueueId}/items/{playQueueItemId}/move`
Move item within play queue.

**Parameters:**
- `playQueueId` (required): Queue ID
- `playQueueItemId` (required): Item to move
- `after` (optional): playQueueItemId to place after


## Response Structure

Play queue responses include:
- `playQueueID`: Queue identifier
- `playQueueSelectedItemID`: Currently playing item
- `playQueueSelectedItemOffset`: Position in queue
- `playQueueTotalCount`: Total items
- `playQueueVersion`: Version for conflict detection
- `Metadata`: Array of track items with `playQueueItemID`

**Note:** `playQueueItemID` is queue-specific and different from track `ratingKey`.
