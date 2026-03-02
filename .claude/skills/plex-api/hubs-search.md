# Hubs & Search Endpoints

## Hubs

Hubs are curated content sections like "Recently Added", "Recently Played", etc.

### `GET /hubs`
Get global hubs (cross-library).

**Parameters:**
- `count` (optional): Limit entries per hub
- `onlyTransient` (optional): Only transient hubs (recently played, etc.)
- `identifier` (optional): Limit to specific hub identifiers

---

### `GET /hubs/sections/{sectionId}`
Get hubs for a specific library section.

**Parameters:**
- `sectionId` (required): Section ID
- `count` (optional): Limit entries per hub
- `onlyTransient` (optional): Only transient hubs

**Common music hubs:**
- Recently Added
- Recently Played
- On Deck (continue listening)
- Popular (if enabled)

---

### Hub Management

### `GET /hubs/sections/{sectionId}/manage`
Get hub configuration for a section.

### `POST /hubs/sections/{sectionId}/manage`
Add a custom hub.

### `PUT /hubs/sections/{sectionId}/manage/move`
Reorder hubs.

### `DELETE /hubs/sections/{sectionId}/manage/{identifier}`
Remove a hub.


## Search

### `GET /hubs/search`
Search across library with hub-style results.

**Parameters:**
- `query` (required): Search term
- `sectionId` (optional): Scope to specific section
- `limit` (optional): Items per result type (default 3)

**Response:** Returns results grouped by type (artists, albums, tracks, playlists).

**Example:**
```
GET /hubs/search?query=beethoven&sectionId=1&limit=5
```

---

### `GET /hubs/search/voice`
Voice-optimized search (Siri, voice assistants).

**Parameters:**
- `query` (required): Voice query text
- `sectionId` (optional): Scope to section

**Differences from regular search:**
- Optimized for spoken queries
- May return different ranking


## Hub Response Structure

```json
{
  "Hub": [
    {
      "hubIdentifier": "hub.music.recentlyadded",
      "title": "Recently Added",
      "type": "album",
      "size": 10,
      "Metadata": [
        { "ratingKey": "123", "title": "Album Name", ... }
      ]
    }
  ]
}
```

**Key fields:**
- `hubIdentifier`: Unique hub ID
- `type`: Content type (artist, album, track)
- `size`: Number of items in hub
- `Metadata`: Array of items
