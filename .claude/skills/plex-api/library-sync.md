# Library Sync Endpoints

## Library Sections

### `GET /library/sections/all`
Get all library sections (music, movies, etc.)

**Response includes:** Section ID, type, title, agent, scanner, uuid, locations

---

### `GET /library/sections/{sectionId}`
Get a specific library section.

**Parameters:**
- `sectionId` (required): Section identifier
- `includeDetails` (optional): Include types, filters, sorts metadata

---

### `GET /library/sections/{sectionId}/all`
Get all items in a section. Primary endpoint for fetching library content.

**Parameters:**
- `sectionId` (required): Section ID
- `type` (optional): Item type (8=artist, 9=album, 10=track)
- `sort` (optional): Sort field (e.g., `titleSort:asc`, `addedAt:desc`)

**Pagination headers:**
- `X-Plex-Container-Start`: Offset
- `X-Plex-Container-Size`: Page size

**Timestamp filters (for incremental sync):**
- `addedAt>=`: Items added on/after Unix timestamp
- `updatedAt>=`: Items updated on/after Unix timestamp

**Example - incremental artist sync:**
```
GET /library/sections/1/all?type=8&addedAt>=1709251200
```

---

### `GET /library/sections/{sectionId}/albums`
Get albums in a music section.

**Parameters:**
- `sectionId` (required): Section ID

---

### `GET /library/sections/{sectionId}/collections`
Get collections in a section.

**Parameters:**
- `sectionId` (required): Section ID


## Metadata

### `GET /library/metadata/{ids}`
Get metadata for item(s) by rating key.

**Parameters:**
- `ids` (required): Rating key(s), comma-separated for multiple
- `includeChildren` (optional): Include child items
- `includeRelated` (optional): Include related items

---

### `GET /library/metadata/{ids}/allLeaves`
Get all leaf items (tracks) for an artist or album.

**Use cases:**
- Fetch all tracks for an artist (grandchildren)
- Fetch all tracks for an album (children)


## Incremental Sync Patterns

For efficient incremental sync, use timestamp filters:

```
# Artists added since timestamp
GET /library/sections/{id}/all?type=8&addedAt>={timestamp}

# Albums updated since timestamp
GET /library/sections/{id}/all?type=9&updatedAt>={timestamp}

# Tracks added since timestamp
GET /library/sections/{id}/all?type=10&addedAt>={timestamp}
```

**Notes:**
- Timestamps are Unix epoch seconds
- Combine with pagination for large result sets
- `updatedAt` catches metadata changes; `addedAt` catches new items
