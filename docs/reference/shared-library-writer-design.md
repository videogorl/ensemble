# Step 3 design: shared library writer

Status: approved by Felicity on 2026-11-10, with all six recommendations in
section 6 accepted. The same day she asked to build it with other services
such as Jellyfin in mind, through "a connector layer to standardize all
writes and functions from each connector". Section 3.5 and the 3b to 3e
changes answer that; they need her approval before 3b starts (section 7).
3a is unchanged by this revision and is being implemented from the approved
text. Written 2026-11-10 against `d9b1f941`, revised against `7cbafb0d`.
Plan context: [`rearchitecture-plan.md`](rearchitecture-plan.md) sections 4.4,
4.5 and 5. Out of scope: the `EnsembleSourceKit` package, a conformance kit,
a fake source, the `ratingKey` rename, any Jellyfin code, GRDB or SQLite, and
a module split.

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

### What a source does beyond library sync

Most of a connector layer already exists. `MusicSourceSyncProvider.swift`
(314 lines) holds the base protocol and twelve opt-in capability protocols.
`SyncProviderResolver` (102 lines) routes an item to its exact source and
capability, failing explicitly when either is missing. `MusicSourceCapabilities`
(25 fields per `MusicSourceType`, in `Models/MusicSource.swift`) is the UI
contract, and `MusicItemActionCapabilities` adds per-item overrides. Plex
declares nine of them, Apple Music six.

| Function | Owner today | Neutral protocol? |
|---|---|---|
| Account, sign-in | `AccountManager` (1,473 lines; Plex in Keychain, Apple Music a device-local switch), `PlexAccountDiscoveryService` | No: 77 uses of `plexAccounts` or `isAppleMusicEnabled` |
| Connection, failover, health | `PlexAPIClient` endpoint selection, `ServerHealthChecker`, `PlexWebSocketCoordinator`; `SyncCoordinator.ensureServerConnection`, `serverFailureMessage`, `refreshConnection` guard on `.plex` | No; `requiresServerConnection` flag only |
| Building sources | `SyncCoordinator.refreshProviders` constructs both types | One factory, by type |
| Library and playlist sync | `sync*` methods; each source writes | Protocol yes, writes no |
| Live changes | `reconcilePlexLibraryChanges` casts to `PlexMusicSourceSyncProvider` | No (cast) |
| Feed | `getHomeHubResult(limit:)`; `HomeHubLoader` merges | Yes |
| Artwork | `getArtworkURL(path:size:)` via `SyncCoordinator` into `ArtworkLoader` | Yes |
| Search | Local search over the store; `AppleMusicCatalogSearch` for an `.appleMusic` scope; Plex Explore calls `PlexAPIClient` directly in `SearchViewModel` | Local yes, remote no |
| Playback | `track.isAppleMusic` picks the MusicKit player; every other track uses the native engine through `MusicSourceTwoPhasePlaybackResolving` | Yes for stream sources |
| Downloads | `getDownloadURL` on the two-phase protocol; `supportsOfflineDownloads` | Yes |
| Timeline, scrobble | `MusicSourcePlaybackReporting` | Yes; Dislike availability checks `.plex` |
| Ratings | `MusicSourceRatingMutating`, `MusicSourceCollectionRatingMutating` | Yes |
| Playlist edits | `MusicSourcePlaylistMutating`; Apple Music's `MusicSourcePlaylistReconciling` writes through a repository | Yes, but reconcile writes |
| Details, lyrics, radio, file info, artist lookup | Five opt-in protocols | Yes |
| Metadata edits | `MetadataMutationService` → `MetadataMutationClient`, built from account and server IDs, which only `PlexAPIClient` implements | Protocol yes, lookup Plex |
| Waveform | `PlaybackService+Presentation` calls `PlexAPIClient.getLoudnessTimeline` | No; gated by `supportsWaveform` |
| Apple Music catalogue adds and catalogue playlists | `SyncCoordinator` casts to `AppleMusicSourceProvider` | No (cast) |
| Source removal | `SourceCacheCleanupService`; `cleanupRemovedSource` branches for Apple Music caches and the Plex cursor | Mostly |
| Watch | `EnsemblePlex` | Plex only, outside this step |

Counted with `rg`: about 35 source-type comparisons in 17 Core and UI files,
8 of them in `SyncCoordinator`. Outside their own files, concrete source types
are named only in `SyncCoordinator` (8 times). Playback, downloads, reporting,
ratings, playlist edits, Feed and artwork already need no new code for a third
stream source. The gaps are writes (this step), live changes, accounts,
connection health, and four direct `PlexAPIClient` uses.

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

The source protocol, renamed `MusicSourceConnector` (section 3.5), keeps
fetch methods only: `fetchLibrary(plan:)`, `fetchPlaylistHeaders(plan:)`
(headers plus whether they are complete) and `fetchPlaylistBodies(ids:)`.
Full and incremental become one call with a different plan, and
`SyncCoordinator` runs one path: plan, fetch, apply. Sources receive values
and return values; there are no callbacks.

### 3.2 What the writer owns

- **Rows.** Upsert the source row; write only inputs whose stored metadata
  does not `match`; artists, albums, tracks, genres in order, with
  cancellation checks.
- **Deltas.** If a delta adds a track or moves it to another album, invalidate
  the inventory cursor before writing, so a cancelled pass still reconciles.
  Plex's rule today, applied to every source.
- **Deletion, only from an inventory.** The writer refuses an inventory with
  blank or repeated IDs, a track whose parent is missing from `albumIDs`, or no
  IDs while the source has stored rows (decision 2): nothing is deleted
  and the cursor stays due. Otherwise it deletes what is missing, sets album
  counts from `trackParents` (including zero), prunes Hidden items once, and
  reports removed track IDs for both sources.
- **Playlists.** Header and body in one save, so a failed body cannot advance
  the date. Responses older than the stored date are ignored for both sources.
  One body-refresh rule: no stored body, a changed or missing date, or an empty
  stored body under a non-empty header. The "local count above server
  count" rule is dropped (decision 4). Playlists are deleted only from a
  complete header list, and never from an empty one (decision 2).
- **Optimistic playlist writes (decision 1).** `persistCreatedPlaylist` and
  `persistOptimisticPlaylistAdd` leave `SyncCoordinator` and become playlist
  batches the writer applies, so a create or add cannot race a sync body
  write. Playlist title and rating edits stay with `MutationCoordinator` and
  `MetadataMutationService`.
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
lines. The connector work in section 3.5 adds about 70 lines and removes a
few dozen, so it does not change this estimate. The success measure stays the
plan section 8 fix-commit count, which reads 2 for the last 30 days.

### 3.5 The connector layer

Added 2026-11-10 at Felicity's request: one layer that standardizes every
write and function of each source, so a service such as Jellyfin can attach
later. The smallest honest version finishes the protocol family that already
exists (section 1, "What a source does beyond library sync") in place.

- **The write half is `LibraryWriter`.** After 3d no source holds a repository
  or writes the store. Library rows, playlists, cursors, optimistic creates
  and adds, and Apple Music's reconciled bodies all reach the store as batches
  the writer applies. Remote mutations (rate, edit a playlist, report
  playback) stay source methods, because they write to the service, not the
  store.
- **The read and function half is `MusicSourceConnector`.** This is
  `MusicSourceSyncProvider` renamed, with its four `sync*` methods replaced by
  fetches. The twelve capability protocols stay as they are, plus one new one.
  The file becomes `MusicSourceConnector.swift`, so a new source reads one
  file to learn what to implement. The two classes become `PlexConnector` and
  `AppleMusicConnector`.

```swift
/// A connected music service. It reads from and changes the remote service
/// and never touches the store; LibraryWriter applies what it returns.
public protocol MusicSourceConnector: Sendable {
    var sourceIdentifier: MusicSourceIdentifier { get }
    func fetchLibrary(plan: LibrarySyncPlan) async throws -> LibraryBatch
    func fetchPlaylistHeaders(plan: PlaylistSyncPlan) async throws -> PlaylistHeaderList
    func fetchPlaylistBodies(ids: Set<String>) async throws -> PlaylistBatch
    func getHomeHubResult(limit: Int) async throws -> MusicSourceHubFetchResult
    func getArtworkURL(path: String?, size: Int) async throws -> URL?
}

/// New in 3b. Turns hints from a live channel (the Plex WebSocket today) into
/// a delta. A delta never deletes; a deletion hint marks the inventory due.
public protocol MusicSourceChangeFetching: MusicSourceConnector {
    func fetchChanges(_ hints: Set<LibraryChangeHint>) async throws -> LibraryBatch
}
```

`LibraryChangeHint` holds an item ID, its kind (artist, album or track) and
whether it was deleted. The Plex socket keeps producing `PlexLibraryChange`,
and `SyncCoordinator` maps it to hints. This removes the one cast to the Plex
type in the sync path. The capability protocols that stay optional and are
routed by `SyncProviderResolver.requireCapability`: playback resolving and
two-phase resolving, track and collection ratings, playlist mutating and
reconciling, playback reporting, artist lookup, details, file info, lyrics,
and radio. Only `reconcilePlaylist` changes: in 3d it returns a playlist
batch instead of taking a repository.

**Capability flags.** Both layers stay, each for its own reader. Protocol
conformance decides routing. `MusicSourceCapabilities` decides UI and copy;
it holds strings, so it cannot be derived from conformance. Four flags have a
protocol counterpart: `supportsLyrics`, `supportsAudioFileInfo`,
`supportsCollectionRatings` and `supportsOfflineDownloads` (two-phase
resolving). Both sources agree today. 3e adds one table test that checks each
pair per source type, using type checks
(`PlexConnector.self is MusicSourceLyricsProviding.Type`), so a new source
cannot claim a flag it does not implement. That test is the one part of the
dropped conformance kit worth keeping, and the test policy's "source
conformance" line covers it.

**Source-specific on purpose:**

- **MusicKit playback.** `track.isAppleMusic` selects the system player, as
  plan 4.3 requires ("two engines exist and stay"). A stream source uses the
  native engine through two-phase resolving.
  `StreamDecision.directStream(partKey:)` takes any server path, so its Plex
  name does not block reuse.
- **Accounts and sign-in.** Credentials, discovery and sign-in screens differ
  per service. `AccountManager` stays the owner; a new service adds its own
  account type there.
- **Connection health and failover.** Only Plex has them. Turning
  `ensureServerConnection`, `serverFailureMessage` and `refreshConnection`
  into a capability waits until a second server source shows what is common.
- **One-source functions:** Apple Music catalogue adds and catalogue
  playlists, the Plex waveform call, Plex Explore search, and the
  metadata-edit client lookup.
- **Building connectors.** `SyncCoordinator.refreshProviders` stays the one
  place each source type is constructed.

**Rule for later, written into `architecture` in 3e.** Shared code branches
on source type only to build a connector, to pick the MusicKit engine, or for
icons and copy through `MusicSourceCapabilities`. Any other function becomes a
capability protocol when a second source needs it, not before.

**No package.** An `EnsembleSourceKit` target would have to hold these
protocols, but they take and return `Track`, `Playlist`, `PlaylistItem`,
`Hub`, `Album`, `ArtistDetail` and other EnsembleCore models. Moving those is
the parked step 4. A package now would add a target and move one 300-line
file, deleting nothing.

**What Jellyfin would then need (not built):** a `MusicSourceType` case and
capabilities entry (the compiler lists every switch to update);
`MediaSourceIdentity` parsing for its key; an account type and sign-in in
`AccountManager`; one branch in `refreshProviders`; a connector with the five
required methods, plus two-phase resolving, reporting, ratings and playlist
edits as the server supports them; and `jellyfin-sdk-swift` (plan 4.8, MPL
2.0). The writer, sync coordinator, playback, downloads and Feed would need
no change.

**Cost.** The rename touches about 160 mentions in about 25 Swift files (47
for the protocol, 55 for the Plex class, 60 for the Apple Music class), plus
four skill files. It is compiler-checked and adds no lines. The change
capability and hint mapping add about 30 lines and remove the cast. The
reconcile change and source-neutral cursor cleanup are net deletions. The
flag test is about 40 lines. Risk is low; the main cost is merge friction
with branches touching the same files, handled by ordering in section 4.

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
- **3b. Writer and Plex library.** Starts after 3a is merged. Its first
  commit is the mechanical rename from section 3.5 (protocol, both classes,
  their files, tests and the four skill references) with no behaviour change,
  checked by the build and the existing `EnsembleCore` tests. Files: new
  `LibraryWriter.swift`, `PlexConnector.swift`, `MusicSourceConnector.swift`,
  `SyncCoordinator.swift`, `SyncCursorRepository.swift`, one writer test file.
  Adds `MusicSourceChangeFetching` and `LibraryChangeHint`; the WebSocket
  targeted pass calls the capability instead of casting to the Plex type.
  Preserves section 3.2 and Plex's repair, second read, 24-hour full-metadata
  pass and WebSocket behaviour. Accept: table tests per deletion class (a delta
  never deletes; an inventory deletes only missing IDs; blank, repeated,
  orphan-parent and empty inventories refuse; cancellation leaves the cursor;
  cursors stay monotonic); on the simulator, add then remove a file in the
  owned album and see counts, the Siri index save and the offline download
  follow as on 2026-10-08. Owed on the iPhone: Background Refresh delivering
  the same change. Deletes Plex library writes, orphan and cursor code.
- **3c. Apple Music library, one coordinator path.** Files:
  `AppleMusicConnector.swift`, `SyncCoordinator.swift`,
  `LibraryWriter.swift`. Source removal deletes all of the source's cursors
  through the writer, so `cleanupRemovedSource` loses its Plex cursor branch
  and its call into the Apple Music type. Preserves contents, favourites, dates and play
  history. Accept: the existing provider tests rewritten to assert batches.
  Hypothesis: the simulator cannot authorize a MusicKit library, so a library
  pass with an added and a removed song is owed on the iPhone. Deletes the old
  library methods, the Apple Music UserDefaults date and the split coordinator
  paths.
- **3d. Playlists on the writer.** Files: both connectors,
  `SyncCoordinator.swift`, `PlaylistRefreshController.swift`,
  `WebSocketSyncController.swift`, `LibraryWriter.swift`. Optimistic creates
  and adds become writer batches (decision 1), and `reconcilePlaylist`
  returns a body batch instead of writing through a repository, so no
  connector holds a repository afterwards. Preserves mutation feedback,
  optimistic adds, read-only smart playlists and last-playlist targets. Accept: Plex create, add, rename, reorder and delete on a disposable
  playlist; an edit from another client arrives by WebSocket; the issue #98
  playlist makes no body request on an unchanged full pass. Owed on the
  iPhone: the same on Apple Music. Deletes playlist writes in both providers,
  the Plex UserDefaults keys, the full-sync fallbacks and the old playlist
  methods.
- **3e. Close-out.** Remove repository reads left unused; add the capability
  flag agreement test (section 3.5); update the `architecture` sync rules,
  adding the connector rule from section 3.5, and the `known-issues` duplicate
  entry; write the verification note; measure lines and fix commits; add owed
  checks to `physical-device-backlog.md`; remove the freeze line.

No sub-step is added: the connector work rides on files 3b to 3e already
rewrite. 3a is unchanged.

## 5. Risks

- **Launch crash on migration.** A failed load is fatal; 3a tests real model-11
  stores with duplicates first, and a read-only copy of the iPhone's store
  migrates on the Mac before 3a lands (decision 6).
- **One place to get deletion wrong.** A writer bug hits both sources; the 3b
  table tests are the guard, and the test policy allows them.
- **Behaviour shifts.** Apple Music gains the empty guard, Plex gains the
  stale-response guard, and the body rule drops a repair. Felicity approved
  all three on 2026-11-10.
- **Rename friction.** The 3b rename touches files other branches may hold.
  It lands as its own commit right after 3a merges, before the writer code,
  so a rebase meets only renames.
- **Serialization.** WebSocket playlist writes queue behind library batches in
  the actor. Network work stays outside it, so waits should be short; 3b
  rechecks Background Refresh deadlines.
- **Apple Music evidence** is mostly owed to the phone, so 3c and 3d stay
  unverified longer.
- **Left alone:** the known issue "Full Sync Joining Narrower Source Work". One
  coordinator path makes it easier to fix later.

## 6. Decisions (Felicity, 2026-11-10)

Felicity approved the design and agreed with every recommendation:

1. **Writes outside sync.** Optimistic playlist creates and adds go through
   the writer. Title and rating edits stay with their current owners
   (`MutationCoordinator`, `MetadataMutationService`). Lands in 3d.
2. **Empty inventory.** A complete but empty inventory deletes nothing, for
   library and playlists. Removing the source stays the only way to clear
   it. Accepted cost: a last playlist deleted on another client lingers until
   the server has a playlist again or it is deleted in Ensemble.
3. **Apple Music removals.** No second confirming read for now; rely on the
   writer's structural checks. Revisit if a wrongful delete is seen.
4. **Body refresh rule.** Drop "local count above server count" once the
   constraint lands, ending the issue #98 refetch. Lands in 3d.
5. **Constraint.** Add the `CDPlaylistTrack` uniqueness constraint (3a).
6. **Migration on real data.** Copy the iPhone's store read-only and migrate
   the copy on the Mac before 3a lands. This is a gate on merging 3a; the 3a
   text above is left as written because 3a is already being implemented.

## 7. Open questions for Felicity (connector revision)

1. **Connector scope.** Is section 3.5 the connector layer you meant: one
   protocol family in EnsembleCore, the writer as its only write path, new
   capabilities added when a second source needs them, and no package or
   Jellyfin code? Recommended: yes. The larger alternative, the plan 4.4
   facet protocol in its own package with a conformance kit and a fake
   source, needs the model split in step 4 first.
2. **Rename.** Rename `MusicSourceSyncProvider` to `MusicSourceConnector`,
   and the two classes to `PlexConnector` and `AppleMusicConnector`, in 3b?
   Recommended: yes. The protocol stops syncing in 3b, so the old name would
   be wrong, and the cost is one mechanical commit. Keeping the names is
   also workable; the layer works the same either way.
3. **Connection health as a capability.** Generalize Plex's ensure, refresh
   and failure-message calls now, or when Jellyfin is scheduled? Recommended:
   when Jellyfin is scheduled. One implementation cannot show what is common.

## 8. Will this help the crashes?

Felicity asked whether this will help some of the crashes she has seen. The
evidence is in
[`2026-11-10-crash-evidence-and-library-writer.md`](../investigations/2026-11-10-crash-evidence-and-library-writer.md).
In short: two iPhone SE 2 freezes on 2026-08-08 happened while opening a
playlist, on a build from the day before the duplicate-membership fix. The
constraint and the 3a backfill make that cause impossible rather than
mitigated. A third SE 2 freeze (2026-08-16) has no log and may or may not
share the cause. Audio-engine aborts and table row-count crashes are outside
this step and already fixed or owned by step 6. That note lists the device
reports and dSYMs that would settle the open case. A suggestion for 3a,
passed on without changing its text: have the backfill log how many duplicate
rows it removed, so each phone's first launch shows whether it carried any.
