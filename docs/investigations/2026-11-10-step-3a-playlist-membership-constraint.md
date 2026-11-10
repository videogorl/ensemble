# Step 3a: playlist membership constraint (model 12)

Date: 2026-11-10. Design: [`shared-library-writer-design.md`](../reference/shared-library-writer-design.md)
sub-step 3a, approved by Felicity on 2026-11-10 (add the constraint; test the
migration against real stores before it lands).

## Change

- Model 12 adds `playlistRatingKey` and `playlistSourceCompositeKey` to
  `CDPlaylistTrack` and a uniqueness constraint on
  (`playlistSourceCompositeKey`, `playlistRatingKey`, `order`). The lightweight
  migration is inferred; no mapping model.
- `PlaylistMembershipBackfill` runs from `CoreDataStack.init` after the store
  loads (not for in-memory stores). It fills the keys and deletes a row only
  when it repeats the item at its position. Item identity is `playlistItemID`,
  else `trackRatingKey`, else the linked track's rating key, else the object
  ID (the old reader's chain, so linked-only legacy rows written twice are
  recognized as duplicates). A different item at an occupied position moves
  after the playlist's last position instead of being deleted. Rows without a
  playlist are deleted. It logs once, counts only: `Playlist membership
  backfill: keysFilled=N duplicateRowsRemoved=N playlists=N`.
- `PlaylistRepository.setPlaylistTrackSnapshots` reuses the row at each
  position and deletes extras, instead of deleting and reinserting every row
  (a delete plus insert of the same key in one save is what the constraint
  would reject). It is the only production code that inserts `CDPlaylistTrack`.
- `CDPlaylist.playlistItemsArray` keeps its exact-duplicate guard (see
  "Resumable by design"); `removeDuplicatePlaylists()` and its call in
  `syncAll` are removed.
- `CoreDataStack.onDisk(at:)` for tests; `isCurrentModel` checks the new field.

### Resumable by design

Rows still missing keys are the durable record that the backfill is unfinished.
No separate flag exists, so there is nothing to get out of step with the data:
a store with no such rows costs one grouped query at launch (3 to 30 ms on the
copies below).

- The work is a series of SQL batch statements, per playlist: delete duplicate
  rows, move a conflicting different item, then set the keys on every row of
  the playlist in one statement. After any statement the store is valid and
  the pass can be repeated: duplicates deleted but keys unset is simply
  unfinished work. A failure between statements loses no membership
  (`testBackfillFailureMidwayIsFinishedByTheNextRun` throws after the first
  playlist's duplicates are deleted, then finishes on the next run).
- A failure is logged, never fatal, and the app continues. The next launch
  repeats the pass. Until then:
  - the only membership inserter, the body writer, takes each existing row at a
    position, deletes duplicates and sets keys on every row it keeps, so it
    leaves its playlist complete;
  - `relinkPlaylistMemberships` skips rows without keys. Saving a change to a
    nil-key row would let the constraint treat unrelated nil-key rows at one
    position as equal (observed: Core Data merges two nil-key rows at the same
    order into one), so those rows wait for the backfill;
  - readers keep the exact-duplicate guard in `playlistItemsArray`, so a store
    that failed its backfill shows each item once instead of doubled playlists.
    The guard can go once the backfill's completion is recorded durably or a
    later release is sure no store retains unkeyed rows (candidate for 3e).
- Chosen over a metadata flag because `setMetadata` persists only with the
  next save, which a no-work pass never makes, and over an asynchronous pass
  behind a gate because every reader and writer would then wait on shared
  state. Cost: the one-time pass runs synchronously in `CoreDataStack.init`,
  like the store load and migration beside it.

### Boundedness

Per playlist, the pass fetches only `objectID`, `order`, `playlistItemID`,
`trackRatingKey` and `track.ratingKey` as dictionaries (no managed objects, no
track faulting) and does the changes as SQL batch statements, so memory is
bounded by the largest playlist's attribute rows. The context is reset between
playlists. Rows are not split across batches because duplicates are judged per
playlist; a playlist is the unit that stays valid after every statement.

## What the experiments showed

- A real store with no duplicates (SE, simulators) migrates and backfills
  cleanly. The migration with duplicate rows present also loads: SQLite treats
  the all-NULL key triples as distinct, so nothing conflicts until keys exist.
- Core Data treats nil key values as **equal** when it checks the constraint at
  save time (two nil-key rows at one order merged to one).
- `NSInMemoryStoreType` enforces the constraint within one save but **not
  across contexts** (two contexts inserting one key both kept their row). An
  on-disk SQLite store enforces it across contexts. The concurrency test
  therefore uses `CoreDataStack.onDisk` and two repositories. In-memory stores
  also reject batch statements, so the backfill does not run on them.
- Bug caught by the harness in the first version: `context.reset()` inside a
  loop over already-fetched playlists left the last playlists of a 52-playlist
  store unkeyed. The rewrite fetches one playlist at a time.
- A model-11 build cannot open a model-12 store: opening a migrated copy with
  the model-11 `.mom` and automatic migration off fails with
  `NSCocoaErrorDomain 134100` (incompatible model version); the store file,
  schema and row count were unchanged afterwards. The shipped app's
  `CoreDataStack` calls `fatalError` on a store load error, so an older build
  installed over a model-12 store fails at launch and deletes nothing. (In a
  test process where model 12 is also in the bundle, Core Data silently
  migrated the store back down to model 11 and dropped the new columns; a
  shipped old build does not contain model 12, so that path does not apply to
  it. Not reproduced with an old binary.) This is what happened to nobody here
  but would hit another worker's older build on a simulator store my build had
  migrated.

## Real stores

Copies only, in the session scratchpad, never modified in place; deleted after
the run. The SE store was copied again from the phone for this round; the
iPhone 17 Pro Max store was copied (model 11) while its simulator was shut
down. Harness: a throwaway XCTest (not committed) that opens a copy with
`CoreDataStack.onDisk`, then reopens it with a fresh stack to prove the second
launch does nothing. "Dup groups" = (playlist, order) pairs with more than one
row. Distinct tracks = distinct (playlist, track) pairs.

| Store | Rows before | Dup groups before | Rows after | Dup groups after | Distinct tracks before/after | Result |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone SE (device copy, 50 playlists) | 5,827 | 0 | 5,827 | 0 | 5,827 / 5,827 | Loads; 5,827 keyed; 0.30 s; second launch 7 ms, no work |
| SE copy + injected duplicates (top 5 playlists, 3 rows each; 2 playlists repeat tracks at other positions) | 14,920 | 4,544 | 5,832 | 0 | 5,827 / 5,827 | Loads; 9,088 rows removed; the 5 repeated-track rows kept; 0.33 s; second launch 5 ms |
| iPhone 17 Pro Max simulator copy (52 playlists) | 5,822 | 0 | 5,822 | 0 | 5,822 / 5,822 | Loads; keyed; 0.17 s |
| iPhone 17 Pro Max copy, every row doubled | 11,644 | 5,822 | 5,822 | 0 | 5,822 / 5,822 | Loads; 5,822 rows removed; 0.22 s |
| iPad Pro 11" simulator (already migrated by the first round) | 5,822 | 0 | 5,822 | 0 | 5,822 / 5,822 | Loads; nothing to do, 30 ms |
| Mac app store (empty, older model) | 0 | 0 | 0 | 0 | 0 / 0 | Loads |
| `xctest` store (empty) | 0 | 0 | 0 | 0 | 0 / 0 | Loads |
| Synthetic: iPhone 17 copy grown to 100,000 rows, one 20,000-row playlist, 8,201 duplicate pairs | 100,000 | 8,201 | 91,799 | 0 | 5,822 / 5,822 | Loads; 0.83 s |

No real store had duplicates; the 2,840-group store no longer exists.

### Time and memory (Mac, M-series, loaded machine)

Backfill alone, after the store load, in its own process; peak is
`ledger_phys_footprint_peak` minus the footprint just before the pass (two runs
each):

| Store | Backfill time | Peak over pre-run footprint |
| --- | --- | --- |
| SE copy + duplicates (14,920 rows) | 0.19 s, 0.20 s | +6 MB |
| Synthetic 100,000 rows, 20,000-row playlist | 0.59 s, 0.56 s | +19 MB, +17 MB |

The first round took 1.6 to 2.5 s of launch time for the same SE store because
it materialized every membership object and saved through Core Data; the
statement-based pass takes about 0.2 s.

Implication for an iPhone SE (A13) and for launch: not measured on the
device. A real SE store is the 5,827-row case, about 0.2 s on the Mac; even at
5 times slower it is about 1 s once, then 3 to 30 ms per launch. The synthetic
store is larger than anything real here. The pass stays synchronous, as the
store load and migration already are. If a later store grows past that,
the first candidate is moving it behind an explicit readiness gate.

Watch: `WatchCatalogStore` uses `CoreDataStack.shared`, so the watch process
loads the same model and runs the same code on its own store at first launch
after the update. The watch catalog code never writes `CDPlaylistTrack`, so the
pass finds no rows and costs two empty queries.

## Writers

Only `PlaylistRepository.setPlaylistTrackSnapshots` inserts membership rows;
its callers are the Plex and Apple Music providers and `SyncCoordinator`
(created and optimistic-add playlists). It runs on the repository's
`membershipWriteContext` (`NSMergeByPropertyObjectTrumpMergePolicy`, as every
context). `relinkPlaylistMemberships` only sets `track` and now skips rows
without keys (see "Resumable by design"). Playlist deletion cascades. With the constraint, two repositories
writing one playlist concurrently ended with one row per position (test), and
repeated tracks at different positions keep both rows.

## Verification

- `swift test -q --package-path Packages/EnsemblePersistence`: 101 tests, 0
  failures on the last run. `DownloadManagerTests.testReconciliationPreservesExistingQualityAndReplacementIsExplicit`
  fails intermittently on the unmodified base commit `7cbafb0d` too.
- `swift test --package-path Packages/EnsembleCore`: 1,187 tests. The machine
  was at load average 100 to 500 from other sessions; three full runs gave 8,
  1 and 4 failures, each in a different timing-sensitive test (Now Playing
  favorite and artwork tests, `PlexWebSocketCoordinatorTests`), and
  `NowPlayingViewModelFavoriteTests` plus `PlexWebSocketCoordinatorTests`
  pass together (36 of 36) and `NowPlayingViewModelFavoriteTests` passed 3 of
  3 alone. No failure involves playlists or persistence.
- `xcodebuild` (via `scripts/build_serial.py`) for the `Ensemble` scheme:
  iOS Simulator (iPad Pro 11" destination) and macOS both `** BUILD SUCCEEDED **`.
- Simulator, iPad Pro 11" `6511F397-...`: build `0.4.0 202611100742.9297`
  installed (installed `Ensemble.debug.dylib` byte-identical to the build). The
  store was replaced with a model-11 copy of the iPhone 17 Pro Max store with
  every membership row doubled (11,644 rows, 5,822 duplicate groups). The app
  launched, migrated it in place to 5,822 keyed rows with 0 duplicate groups,
  and playlists 15659 and 4666 loaded 238 and 3,597 tracks (app log; playlist
  4667 was not reached before the shared machine's load stalled the run). The
  simulator is `Shutdown`. The iPhone 17 Pro Max simulator was not touched.

Not verified: the backfill log line in the app's own session log (the file sink
is not attached when the stack is created; the unit test asserts the message);
timing on the iPhone SE or watch hardware; an older shipped binary opened
against a model-12 store.

Owed on the physical iPhone SE: see `physical-device-backlog.md`.
