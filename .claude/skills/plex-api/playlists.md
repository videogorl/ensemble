# Playlist Endpoints

## List & Get

### `GET /playlists`
Get all playlists.

**Parameters:**
- `playlistType` (optional): Filter by type (`audio`, `video`, `photo`)
- `smart` (optional): `1` for smart playlists only, `0` for regular only

---

### `GET /playlists/{playlistId}`
Get playlist metadata.

**Parameters:**
- `playlistId` (required): Playlist ID

---

### `GET /playlists/{playlistId}/items`
Get playlist contents (tracks).

**Parameters:**
- `playlistId` (required): Playlist ID
- `type` (optional): Metadata type filter


## Create & Edit

### `POST /playlists`
Create a new playlist.

**Parameters:**
- `title` (form, required): Playlist title
- `type` (form, required): Playlist type (`audio`)
- `uri` (optional): Content URI to initialize with
- `playQueueID` (optional): Create from existing play queue

**Example - create empty playlist:**
```
POST /playlists
Content-Type: application/x-www-form-urlencoded

title=My%20Playlist&type=audio
```

---

### `PUT /playlists/{playlistId}`
Edit playlist metadata (rename).

**Parameters:**
- `playlistId` (required): Playlist ID
- `title` (optional): New title

**Example - rename playlist:**
```
PUT /playlists/12345?title=New%20Name
```


## Add & Remove Items

### `PUT /playlists/{playlistId}/items`
Add items to a playlist.

**Parameters:**
- `playlistId` (required): Playlist ID
- `uri` (required): Content URI to add

**URI format:**
```
library://{libraryUUID}/item//library/metadata/{ratingKey}
```

**Example - add track:**
```
PUT /playlists/12345/items?uri=library://abc-123/item//library/metadata/67890
```

---

### `DELETE /playlists/{playlistId}/items`
Clear all items from a playlist.

**Parameters:**
- `playlistId` (required): Playlist ID


## Reorder Items

### `PUT /playlists/{playlistId}/items/{playlistItemId}/move`
Move an item within a playlist.

**Parameters:**
- `playlistId` (required): Playlist ID
- `playlistItemId` (required): The item's playlist-specific ID (not ratingKey)
- `after` (optional): playlistItemId to place after (omit for first position)

**Note:** `playlistItemId` is returned in playlist items response, distinct from track `ratingKey`.


## Delete

### `DELETE /playlists/{playlistId}`
Delete a playlist.

**Parameters:**
- `playlistId` (required): Playlist ID


## Smart Playlists

Smart playlists are server-generated based on rules. They:
- Cannot have items added/removed manually
- Cannot be reordered
- Can be identified by `smart="1"` in playlist metadata

Treat smart playlists as read-only for mutation operations.
