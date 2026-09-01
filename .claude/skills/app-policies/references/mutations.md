# Mutations Policy

- Shared workflows own mutation validation, remote/queued semantics, optimistic
  persistence, reconciliation, and feedback. Views/ViewModels own presentation,
  confirmation, navigation, and local display state only.
- Mutation capability and disabled reasons come from provider/source/item
  contracts. Missing or malformed ownership fails closed and never inherits
  Plex or the only configured provider's permissions.
- Offline-capable work enters one durable mutation queue only when the resolved
  provider explicitly supports it. Queue records retain the exact owner and all
  referenced source scopes; removing a referenced source prevents replay.
- Plex playlist/rating/scrobble operations may opt into offline replay. Apple
  Music playlist/favorite/library operations remain online-only unless a proven
  provider capability changes that contract.
- Playlist mutations are source-aware. Reject incompatible sources, read-only or
  smart targets, unresolved tracks, and duplicates according to the shared
  resolver. Never rebuild a partially available playlist solely from locally
  synced tracks.
- Same-named regular playlists may merge for display across providers; smart or
  editorial kinds stay separate. Mutating a merged artist, album, track, or
  playlist first selects one exact-source constituent. Playback, queueing, and
  adding media to a playlist use the preferred copy without prompting.
- Merging is presentation-only: exact source records remain stored and reappear
  when disabled. Preferred source order may choose among proven copies but never
  reroutes an explicit mutation, rating, download, or playback owner.
- Album families require the same normalized title, album artist, and release
  year. Edition markers remain part of the title; missing years stay separate.
  A merged album shows every constituent track, then collapses matching rows only
  when Songs merging is enabled.
- A merged artist, album, or playlist is pinned only when every constituent is
  pinned. Pin and unpin update every exact-source constituent as one reversible
  batch while persistence remains source-scoped.
- Playlist membership identity/order and enough display metadata remain durable
  independently of the current library cache, so disabled or unavailable library
  tracks remain visible and removable even when they cannot play/download.
- Accepted mutations update exact local state immediately when safe. Older sync
  snapshots cannot overwrite that optimistic state; background reconciliation
  targets only the affected owner and converges to provider authority.
- A Plex playlist delete returning 404 converges the exact local/queued playlist
  as absent or inaccessible while preserving unrelated/shared artwork and other
  HTTP failures for retry. Diagnostics must not claim server deletion when loss
  of access is also possible.
- Ratings/favorites and scrobbles remain source-exact. Apple favorites use the
  provider's binary truth; unsupported removal/dislike operations stay visibly
  unavailable rather than simulated.
- Pins and source-visibility preferences are local reversible mutations.
  Focus-based overrides are temporary and restore the saved preference when
  Focus ends; they do not discard already queued mutations.
- Hidden selections are exact source-scoped roots. Artists derive their albums
  and tracks, albums derive their tracks, and playlists derive nothing. They
  affect newly generated queues but never rewrite the active playback queue.
- Hidden records use last-writer-wins tombstones and may sync independently of
  source credentials through private CloudKit. Unavailable exact identities stay
  dormant; only explicit unhide or a complete authoritative inventory removes one.
- Destructive mutation feedback is explicit and centralized. A failed or partial
  destructive operation never dismisses as full success or silently deletes
  additional local data.
