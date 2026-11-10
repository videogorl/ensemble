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
  loads. Playlists with any row missing keys select the work, so a second
  launch does nothing. It fills the keys and deletes a row only when it repeats
  the item (`playlistItemID`, else `trackRatingKey`) at its position. A
  different item at an occupied position moves after the playlist's last
  position instead of being deleted. Rows without a playlist are deleted. It
  logs once, counts only: `Playlist membership backfill: keysFilled=N
  duplicateRowsRemoved=N playlists=N`.
- `PlaylistRepository.setPlaylistTrackSnapshots` reuses the row at each
  position and deletes extras, instead of deleting and reinserting every row
  (a delete plus insert of the same key in one save is what the constraint
  would reject). It is the only production code that inserts `CDPlaylistTrack`.
- Removed: `CDPlaylist.playlistItemsArray` duplicate filter, and
  `removeDuplicatePlaylists()` with its call in `syncAll`.
- `CoreDataStack.onDisk(at:)` for tests; `isCurrentModel` checks the new field.

## What the experiments showed

- A real store with no duplicates (SE, simulators) migrates and backfills
  cleanly. The migration with duplicate rows present also loads: SQLite treats
  the all-NULL key triples as distinct, so nothing conflicts until keys exist.
- Core Data treats nil key values as **equal** when it checks the constraint at
  save time (two nil-key rows at one order merged to one). So after migration no
  row may be saved while its keys are nil; the backfill runs before any writer
  can exist, in the stack initializer.
- `NSInMemoryStoreType` enforces the constraint within one save but **not
  across contexts** (two contexts inserting one key both kept their row). An
  on-disk SQLite store enforces it across contexts. The concurrency test
  therefore uses `CoreDataStack.onDisk` and two repositories.
- `NSBatchDeleteRequest` is unsupported on in-memory stores (raises), so the
  backfill deletes through the context.
- Bug caught by the harness: an early version called `context.reset()` inside a
  loop over already-fetched playlists, leaving the last one or two playlists of
  a 52-playlist store unkeyed until the next launch. Fixed with a fetch-limit
  loop; the harness now shows zero work on a rerun.

## Real stores

Copies only, in the session scratchpad, never modified in place; deleted after
the run. Harness: a throwaway XCTest (not committed) that opens a copy with
`CoreDataStack.onDisk`, then reopens it with a fresh stack to prove the second
launch does nothing. "Duplicate groups" = (playlist, order) pairs with more
than one row. Distinct tracks = distinct (playlist, track) pairs.

| Store | Rows before | Dup groups before | Rows after | Dup groups after | Distinct tracks before/after | Result |
| --- | --- | --- | --- | --- | --- | --- |
| iPhone SE (device copy, 50 playlists) | 5,827 | 0 | 5,827 | 0 | 5,827 / 5,827 | Loads; 5,827 keyed; 2.5 s; second launch 0 work |
| SE copy + injected duplicates (top 5 playlists ×3 rows; 2 playlists repeat tracks at other positions) | 14,920 | 4,544 | 5,832 | 0 | 5,827 / 5,827 | Loads; 9,088 rows removed; the 5 repeated-track rows kept (`repeatedTrackPlaylists` 5 / 5); 2.2 s; second launch 0 work |
| iPhone 17 Pro Max simulator (52 playlists) | 5,822 | 0 | 5,822 | 0 | 5,822 / 5,822 | Loads; 5,822 keyed; second launch 0 work |
| iPhone 17 Pro Max copy + every row doubled | 11,644 | 5,822 | 5,822 | 0 | 5,822 / 5,822 | Loads; 5,822 rows removed; 1.8 s; second launch 0 work |
| iPad Pro 11" simulator (52 playlists) | 5,822 | 0 | 5,822 | 0 | 5,822 / 5,822 | Loads; keyed; second launch 0 work |
| Mac app store (`Application Support/Ensemble`) | 0 | 0 | 0 | 0 | 0 / 0 | Loads (empty, older model, migrated through) |
| `xctest` store | 0 | 0 | 0 | 0 | 0 / 0 | Loads |

No real store had duplicates; the 2,840-group simulator store no longer
exists. Duplicate cases were built on copies by inserting rows with `sqlite3`.
Evidence: `before.txt`, `after.txt` and `ZZHarnessTests.swift.txt` in the
session scratchpad (`.../scratchpad/`).

Note: the SE and simulator "All Music" playlists hold more rows (3,597) than
their header track count (3,460) with no duplicate positions; that is the
header/body mismatch of issue #98, not a membership duplicate.

## Writers

Only `PlaylistRepository.setPlaylistTrackSnapshots` inserts membership rows;
its callers are the Plex and Apple Music providers and `SyncCoordinator`
(created and optimistic-add playlists). It runs on the repository's
`membershipWriteContext` (`NSMergeByPropertyObjectTrumpMergePolicy`, as every
context). `relinkPlaylistMemberships` only sets `track`; the keys never change
there. Playlist deletion cascades. With the constraint, two repositories
writing one playlist concurrently ended with one row per position (test), and
repeated tracks at different positions keep both rows.

## Verification

- `swift test -q --package-path Packages/EnsemblePersistence`: 100 tests, 0
  failures, except `DownloadManagerTests.testReconciliationPreservesExistingQualityAndReplacementIsExplicit`,
  which fails intermittently on the unmodified base commit `7cbafb0d` too.
- `swift test --package-path Packages/EnsembleCore`: 1,187 tests; one failure,
  `PlexWebSocketCoordinatorTests.testDownloadCompletionEventsAreDebounced`, a
  timing test under load that passes on its own (6 of 6).
- `xcodebuild` (via `scripts/build_serial.py`) for the `Ensemble` scheme:
  iOS Simulator and macOS both `** BUILD SUCCEEDED **`.
- Simulator: build `0.4.0 202611100625.6796` installed on the iPad Pro 11"
  simulator (installed `Ensemble.debug.dylib` byte-identical to the build) over
  its existing store; the app launched, the store migrated (5,822 rows keyed, 0
  duplicate groups) and playlists 15659, 4667 and 4666 loaded 238, 265 and
  3,597 tracks. The iPhone 17 Pro Max was busy with another session's UI-test
  run using a model-11 build, which cannot open a migrated store, so I did not
  migrate it in place; its store was put back from the pre-migration copy
  (model 11, 5,822 rows) after a brief launch of my build migrated it.

Owed on the physical iPhone SE: see `physical-device-backlog.md`.
