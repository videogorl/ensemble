# Step 3 design: shared library writer

Status: awaiting Felicity's approval. Written 2026-11-10 against `d9b1f941`.
Plan context: [`rearchitecture-plan.md`](rearchitecture-plan.md) sections 4.4,
4.5 and 5. Out of scope, per the plan: `EnsembleSourceKit`, a conformance kit,
a fake source, the `ratingKey` rename, Jellyfin groundwork, GRDB or SQLite,
and a module split.

Measured with `wc -l` on files, `sed -n 'a,bp' | wc -l` on function ranges,
and `git log --no-merges --since=90.days` for churn. Anything not read in
source is marked as a hypothesis. Paths are under
`Packages/EnsembleCore/Sources/Services/` unless noted; repositories are under
`Packages/EnsemblePersistence/Sources/Repositories/`.

## 1. Where things stand

### Who writes library data

- **Each source is its own writer.** `MusicSourceSyncProvider` (314 lines)
  hands the provider the repositories through `syncLibrary(to:)`,
  `syncLibraryIncremental(since:to:)`, `syncPlaylists(to:)` and
  `syncPlaylistsIncremental(to:forceOrphanCheck:)`. The provider fetches,
  filters unchanged rows, writes, deletes orphans, prunes Hidden items, and
  records its own cursor.
- **Plex:** `PlexMusicSourceSyncProvider.swift`, 1,867 lines, 12 commits in 90
  days. About 1,246 lines are sync: WebSocket targeted reconcile (141),
  incremental with inventory and full-metadata passes (356), filters and
  mappers (220), full sync (173), playlists (356). 47 write calls.
- **Apple Music:** `AppleMusicSourceProvider.swift`, 1,916 lines. About 751 are
  sync: library (260), playlists (218), playlist persistence (273). 16 write
  calls. Its incremental sync ignores `since` and refetches the whole library
  once a 24-hour UserDefaults date expires.
- **`SyncCoordinator.swift`** (3,840 lines, 31 commits in 90 days) drives them
  through separate full and incremental paths (`syncFullSource`,
  `syncIncrementalSource`, 327 lines), the WebSocket path
  (`reconcilePlexLibraryChanges`, 127) and mutation refreshes. It also writes
  directly: `persistCreatedPlaylist`, `persistOptimisticPlaylistAdd`, cursor
  invalidation, and `removeDuplicatePlaylists()` before every `syncAll`.
  `PlaylistRefreshController.swift` (140) runs the playlist-only, WebSocket,
  mutation and downloaded-playlist refreshes, falling back to full sync.
- **Other writers stay put:** `MutationCoordinator` (playlist title),
  `MetadataMutationService` (titles), and source removal in
  `SourceCacheCleanupService` and `SyncCoordinator.cleanupRemovedSource`.

Sync state lives in five places: `CDSyncCursor` scopes `plex-library` and
`server-playlists` (Plex only); `CDMusicSource.lastSyncedAt` (both;
`loadLastSyncDate` takes the earlier of it and the cursor); UserDefaults
`lastPlaylistSyncAt_*` and `lastPlaylistOrphanCheckAt_*` (Plex playlists,
written beside the cursor); and UserDefaults
`sources.appleMusic.libraryInventory.authoritativeDate`. Apple Music playlists
have no cursor.

### Where the sources diverge

| Concern | Plex | Apple Music |
|---|---|---|
| Unchanged rows | `changed*Inputs` plus timestamp and rating checks | the same `matches(_:)` filters, inline |
| Removed track IDs | reported; `OfflineDownloadService` line 2325 uses them | never reported |
| Album counts | from a complete track inventory, with moved-track repair | songs counted per album while mapping |
| Body refresh | date changed, or local count 0 or above the server count | date nil or changed, or stored count differs from stored rows |
| Stale response | not checked | ignored when older than the stored date |
| Header and body | header written twice so a failed body keeps the old date | one plan writes both |
| Hidden pruning | 8 `removeMissing` calls | 4 calls |

### Deletion safety today

- `removeOrphaned{Artists,Albums,Tracks,Playlists}` delete every source row not
  in the given set. `RepositoryPredicates.sourceScopedOrphan` falls back to the
  bare source predicate for an empty set, so **an empty set deletes every row
  of that source**. Nothing below the providers guards it.
- **Plex** inventories are complete by construction:
  `PlexAPIClient+Library.swift` lines 33–56 check `totalSize`, offsets and page
  sizes and throw on a mismatch. Album keys must be unique and non-blank, and
  every track's parent must be in the album inventory. When cached keys are not
  a subset of the response, Plex reads the inventory again and uses that
  answer. Two empty responses in a row would still delete the library.
- **Apple Music** checks only that the REST `next` chain ended without an error
  (`Page` decodes `data` and `next`, no total); MusicKit paging stops at the
  first short page. It deletes from that inventory at once, with no second read
  and no empty guard. This falls short of `app-policies` (sync and refresh),
  which asks pages to agree on a total and removals to pass a safety check.
- **`removeDuplicatePlaylists()`** (`PlaylistRepository.swift` line 1241) keeps
  one playlist per `ratingKey` across all sources. Plex playlist keys are
  per-server integers, so two servers sharing a key would lose one playlist on
  each `syncAll` and regain it on the next sync. Found in code; not reproduced.
- Failed requests throw before any orphan step, and cursors advance only after
  writes succeed, in both sources.

Every repository call opens a fresh background context, so two writers can
each fetch, find nothing, and insert. Only playlist bodies are serialized, on
one `membershipWriteContext`, since `d93b33fc`.

## 2. Where duplicates have happened

- **Playlist membership rows, confirmed.** `d93b33fc` (2026-08-09): concurrent
  delete-and-replace body saves created exact duplicate `CDPlaylistTrack` rows,
  doubled a merged playlist and froze an iPhone SE 2 (`known-issues`,
  "Cross-Source Snapshot Amplification"). The fix added three compensations:
  the serial membership context, a read-side filter in
  `CDPlaylist.playlistItemsArray`, and Plex's "local count above server count"
  repair rule. One simulator store still held 2,840 duplicate groups.
- **That repair rule now costs refetches.** Issue #98
  (`2026-10-05-state-efficiency-follow-up.md`): a smart playlist's header says
  1,595 tracks while its complete body has 3,460, so every full playlist sync
  refetches the unchanged body.
- **Library rows: no evidence.** Artist, album, track, playlist, genre, mood
  and source entities already have uniqueness constraints on (`ratingKey` or
  `key`, `sourceCompositeKey`) in model 11. A history search for duplicate and
  dedup found no library-row fix. Hypothesis: rows with a nil
  `sourceCompositeKey` escape those constraints; current sync writers always
  pass a key. `CDHub`, `CDHubItem`, `CDDownload` and `CDServer` have none but
  belong to Feed and downloads, outside this step.

**The constraint.** Only `CDPlaylistTrack` needs one. Core Data constraints
cannot name a relationship, so model 12 adds two optional strings,
`playlistRatingKey` and `playlistSourceCompositeKey`, and constrains
(`playlistSourceCompositeKey`, `playlistRatingKey`, `order`). Position is the
identity: a playlist may hold a track twice, and Apple Music items have no
`playlistItemID`. The body writer reuses rows by `order` and deletes extras
instead of deleting and reinserting all rows. The merge policy stays
`NSMergeByPropertyObjectTrumpMergePolicy`, which every context already uses,
so a conflicting insert updates the existing row.

**Migration.** Model 11 to 12 is lightweight and inferred (`CoreDataStack`
sets both options). Existing rows get nil keys; hypothesis: SQLite treats
those as distinct, so stores with legacy duplicates still migrate. This
matters because a failed store load calls `fatalError` at launch. After load,
a one-time backfill fills the keys from each row's playlist and deletes exact
duplicates, keeping the row per position that has a linked track. Memberships
are library cache; downloads, offline targets and pending mutations are not
touched. Tests need an SQLite store at a temporary URL; hypothesis:
`CoreDataStack.inMemory()` uses `NSInMemoryStoreType`, which does not enforce
uniqueness constraints.

## 3. Design

### 3.1 One writer

`LibraryWriter`, a new actor in EnsembleCore (about 400 lines), is the only
code that writes synced library rows, deletes from an inventory, or moves a
sync cursor. As an actor it applies one batch at a time, which removes the
fetch-then-insert races between sync paths. Sources stop receiving
repositories: they fetch and map into the existing Persistence inputs
(`ArtistUpsertInput` through `PlaylistTrackSnapshot`). No new model types.

```swift
struct LibraryBatch: Sendable {            // no inventory: a delta, never deletes
    var artists: [ArtistUpsertInput]; var albums: [AlbumUpsertInput]
    var tracks: [TrackUpsertInput]; var genres: [GenreUpsertInput]?
    var inventory: LibraryInventory?       // only when the source proved it complete
    var queryStartedAt: Date
}
struct LibraryInventory: Sendable {
    var artistIDs: Set<String>; var albumIDs: Set<String>
    var trackParents: [String: String]     // track -> album; gives album counts
    var genreIDs: Set<String>?
}
struct LibrarySyncPlan: Sendable {         // from the cursor, handed to the source
    var since: Date?; var inventoryDue: Bool; var fullMetadataDue: Bool
    var stored: StoredLibraryIDs           // cached keys and track parents
}
actor LibraryWriter {
    func libraryPlan(for: MusicSourceIdentifier) async throws -> LibrarySyncPlan
    func apply(_: LibraryBatch, to: MusicSourceIdentifier) async throws -> LibrarySyncResult
    func playlistsNeedingBodies(_: [PlaylistUpsertInput], server: String) async throws -> Set<String>
    func apply(_: PlaylistBatch, server: String) async throws -> PlaylistSyncResult
    func invalidateInventory(for: SyncScope) async throws
}
```

The provider protocol keeps fetch methods only: `fetchLibrary(plan:)`,
`fetchPlaylistHeaders(plan:)` (headers plus whether they are complete) and
`fetchPlaylistBodies(ids:)`. Full and incremental become one call with a
different plan, and `SyncCoordinator` runs one path: plan, fetch, apply.
Sources receive values and return values; there are no callbacks.

### 3.2 What the writer owns

- **Rows.** Upsert the source row; write only inputs whose stored metadata
  does not `match`; artists, albums, tracks, genres in order, with
  cancellation checks.
- **Deltas.** If a delta adds a track or moves it to another album, invalidate
  the inventory cursor before writing, so a cancelled pass still reconciles.
  Plex's rule today, applied to every source.
- **Deletion, only from an inventory.** The writer refuses an inventory with
  blank or repeated IDs, a track whose parent is missing from `albumIDs`, or no
  IDs while the source has stored rows (open question 2): nothing is deleted
  and the cursor stays due. Otherwise it deletes what is missing, sets album
  counts from `trackParents` (including zero), prunes Hidden items once, and
  reports removed track IDs for both sources.
- **Playlists.** Header and body in one save, so a failed body cannot advance
  the date. Responses older than the stored date are ignored for both sources.
  One body-refresh rule: no stored body, a changed or missing date, or an empty
  stored body under a non-empty header (open question 4). Playlists are deleted
  only from a complete header list.
- **Cursors.** All sync state moves to `CDSyncCursor`. Apple Music gets a
  library cursor in place of its UserDefaults date; the Plex playlist
  UserDefaults keys go. The case `.plexLibrary` becomes `.library` but keeps the
  stored value `plex-library`, so no rows change. Cursors record the query
  start and advance monotonically after commit, as `SyncCursorRepository` does
  now. `CDMusicSource.lastSyncedAt` stays as the display date, set by the
  writer.

### 3.3 What each source keeps

- **Plex:** paging and `totalSize` validation; the second inventory read when
  the first would remove cached keys (compared with `plan.stored`); the
  WebSocket targeted fetch, now returning a delta batch; metadata fetches for
  missing or moved tracks; release formats; and all mutation, playback,
  lyrics and detail APIs.
- **Apple Music:** REST and MusicKit paging; the REST-then-MusicKit body
  fallback; favourite and catalog-ID bookkeeping; `reconcilePlaylist` polling,
  with its body applied through the writer; mutation and catalog APIs. Its use
  of stored play history when native metadata is missing becomes an input
  flag, like the existing `updatesDateAdded`.

### 3.4 What is deleted, and size

Deleted: write, orphan, cursor and Hidden code in both providers; the four
`sync*` protocol methods; the separate full and incremental coordinator paths;
the full-sync fallbacks in `PlaylistRefreshController` and
`refreshProviderPlaylists` (a missing cursor already plans a full fetch);
`removeDuplicatePlaylists()`; the `playlistItemsArray` filter; the "above
server count" rule; the three UserDefaults keys; and repository reads only the
old filters use (`fetchAlbumTimestamps`, `fetchTrackTimestamps`,
`fetchTrackRatings`, `fetchPlaylistLocalTrackStates`, `fetchPlaylistTimestamps`).

Size, information only: about 400 lines added for the writer, 60 for the
backfill, plus model 12 and one table test file. Removed: roughly 450 to 550
from Plex, 250 to 300 from Apple Music, 150 to 250 from the coordinator and
refresh controller, about 150 from Persistence. Net: 700 to 1,000 fewer source
lines. The success measure stays the plan section 8 fix-commit count, which
reads 2 for the last 30 days.

## 4. Sub-steps

Each ships alone on `develop` and deletes the path it replaces. The freeze
covers sync and library-writing code from 3a to 3e; `CLAUDE.md` gets its line
when 3a starts. Simulator checks use an exact UUID and a build proven to be
the one just produced; Plex checks use the live PMS from `.env` and the owned
fixture items from the 2026-10-08 membership investigation. Destructive checks
use disposable items and need Felicity's approval each time.

- **3a. Membership constraint.** Files: model 12, `ManagedObjects.swift`,
  `PlaylistRepository.swift`, `CoreDataStack.swift` (store-URL initializer for
  tests), `SyncCoordinator.swift`, Persistence tests. Preserves body order and
  repeated tracks; changes no downloads, targets or pending mutations. Accept:
  an SQLite-store test where two concurrent body writes leave one set of rows;
  a model-11 store with duplicates migrates, launches and backfills to one row
  per position; on the simulator, a store from the current `develop` build
  (with the 2,840 duplicate groups if that store still exists) migrates and
  merged and single playlists show correct counts. Owed on the iPhone: the real
  store migrates with offline playlist targets intact. Deletes
  `removeDuplicatePlaylists` and the read-side filter.
- **3b. Writer and Plex library.** Files: new `LibraryWriter.swift`,
  `PlexMusicSourceSyncProvider.swift`, `MusicSourceSyncProvider.swift`,
  `SyncCoordinator.swift`, `SyncCursorRepository.swift`, one writer test file.
  Preserves section 3.2 and Plex's repair, second read, 24-hour full-metadata
  pass and WebSocket behaviour. Accept: table tests per deletion class (a delta
  never deletes; an inventory deletes only missing IDs; blank, repeated,
  orphan-parent and empty inventories refuse; cancellation leaves the cursor;
  cursors stay monotonic); on the simulator, add then remove a file in the
  owned album and see counts, the Siri index save and the offline download
  follow as on 2026-10-08. Owed on the iPhone: Background Refresh delivering
  the same change. Deletes Plex library writes, orphan and cursor code.
- **3c. Apple Music library, one coordinator path.** Files:
  `AppleMusicSourceProvider.swift`, `SyncCoordinator.swift`,
  `LibraryWriter.swift`. Preserves contents, favourites, dates and play
  history. Accept: the existing provider tests rewritten to assert batches.
  Hypothesis: the simulator cannot authorize a MusicKit library, so a library
  pass with an added and a removed song is owed on the iPhone. Deletes the old
  library methods, the Apple Music UserDefaults date and the split coordinator
  paths.
- **3d. Playlists on the writer.** Files: both providers,
  `SyncCoordinator.swift`, `PlaylistRefreshController.swift`,
  `WebSocketSyncController.swift`, `LibraryWriter.swift`. Preserves mutation
  feedback, optimistic adds, read-only smart playlists and last-playlist
  targets. Accept: Plex create, add, rename, reorder and delete on a disposable
  playlist; an edit from another client arrives by WebSocket; the issue #98
  playlist makes no body request on an unchanged full pass. Owed on the
  iPhone: the same on Apple Music. Deletes playlist writes in both providers,
  the Plex UserDefaults keys, the full-sync fallbacks and the old playlist
  methods.
- **3e. Close-out.** Remove repository reads left unused; update the
  `architecture` sync rules and the `known-issues` duplicate entry; write the
  verification note; measure lines and fix commits; add owed checks to
  `physical-device-backlog.md`; remove the freeze line.

## 5. Risks

- **Launch crash on migration.** A failed load is fatal; 3a tests real model-11
  stores with duplicates first (open question 6).
- **One place to get deletion wrong.** A writer bug hits both sources; the 3b
  table tests are the guard, and the test policy allows them.
- **Behaviour shifts.** Apple Music gains the empty guard, Plex gains the
  stale-response guard, and the body rule drops a repair. All are listed for
  approval.
- **Serialization.** WebSocket playlist writes queue behind library batches in
  the actor. Network work stays outside it, so waits should be short; 3b
  rechecks Background Refresh deadlines.
- **Apple Music evidence** is mostly owed to the phone, so 3c and 3d stay
  unverified longer.
- **Left alone:** the known issue "Full Sync Joining Narrower Source Work". One
  coordinator path makes it easier to fix later.

## 6. Open questions for Felicity

1. **Writes outside sync.** Should optimistic playlist creates and adds go
   through the writer? Recommended: yes, they write bodies. Title and rating
   edits stay with their command owners.
2. **Empty inventory.** Should a complete but empty inventory delete a source's
   rows? Recommended: no, for library and playlists; explicit source removal
   stays the way to clear one. Cost: a last playlist deleted on another client
   lingers until the server has a playlist again or it is deleted in Ensemble.
3. **Apple Music removals.** Plex reads twice before deleting; Apple Music
   does not. Keep that with the writer's structural checks, or have the writer
   delete only IDs missing from two consecutive inventories for both sources,
   so removals appear one pass later? Recommended: the first now; revisit if a
   wrongful delete is seen.
4. **Body refresh rule.** Drop "local count above server count" once the
   constraint makes duplicates impossible, ending the issue #98 refetch?
   Recommended: yes.
5. **Constraint or actor alone.** The actor already serializes writes; the
   constraint adds a migration. Recommended: add it, as the plan decided, so
   the read-side filter can go and other writers cannot bring duplicates back.
6. **Migration on your data.** Copy the iPhone store read-only with
   `devicectl` and migrate the copy on the Mac before 3a lands? Recommended:
   yes; it is the one real store with months of history.
