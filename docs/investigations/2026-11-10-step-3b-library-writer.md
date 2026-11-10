# Step 3b: library writer and the Plex library sync

Date: 2026-11-10. Design: [`shared-library-writer-design.md`](../reference/shared-library-writer-design.md)
sub-step 3b. Predecessor: [`2026-11-10-step-3a-playlist-membership-constraint.md`](2026-11-10-step-3a-playlist-membership-constraint.md).

## What changed

- **Rename** (own commit, no behaviour change): `MusicSourceSyncProvider` to
  `MusicSourceConnector`, `PlexMusicSourceSyncProvider` to `PlexConnector`,
  `AppleMusicSourceProvider` to `AppleMusicConnector`, with files, tests and
  the live skill references. Historical investigation notes keep the old names.
- **`LibraryWriter`** (`Services/LibraryWriter.swift`, an actor) is the only
  code that writes Plex library rows, deletes from an inventory or moves a
  library cursor. API: `libraryPlan(for:since:)`, `apply(_:to:)` (a sync pass),
  `applyChanges(_:to:)` (a live delta), `invalidateInventory(for:)`,
  `removeCursor(for:)`.
- **`PlexConnector`** fetches into a `LibraryBatch`: `fetchLibrary(plan:)` (full
  when `plan.since` is nil, otherwise the delta plus an inventory when one is
  due) and `fetchChanges(_:)` (the WebSocket pass). It keeps paging validation,
  the second inventory read, the moved-track repair, release formats and the
  24-hour full-metadata pass. It holds a cursor repository only for playlists
  (step 3d).
- **`MusicSourceChangeFetching`** and `LibraryChangeHint` are new.
  `SyncCoordinator.reconcilePlexLibraryChanges` no longer casts to the Plex
  type; it maps `PlexLibraryChange` to hints and calls the capability.
- **One coordinator library path** for connectors that fetch:
  plan, fetch, apply. Full and incremental differ only in the plan.
- `SyncCursorScopeType.plexLibrary` is now `.library` (stored value
  `plex-library` unchanged, so no row changes).
- Persistence: `fetchTrackSummaries(forSource:)` (date, rating and album key per
  track, one read) replaces `fetchAlbumTimestamps`, `fetchTrackTimestamps` and
  `fetchTrackRatings`, which only the old Plex filters used.
- A DEBUG route, `ensemble://debug/sync?mode=full|incremental`, so the store
  comparison below needs no taps (documented in `agent-runtime-testing.md`).

### Deviations from the design, and why

1. **Two transitional protocols.** The design puts `fetchLibrary(plan:)` in the
   base protocol. Apple Music cannot implement it before 3c, and the base
   protocol cannot keep `syncLibrary` because Plex no longer has it. So
   `MusicSourceLibraryFetching` (Plex) and `MusicSourceLibrarySyncing` (Apple
   Music and the test fakes) exist for 3b; 3c folds the first into
   `MusicSourceConnector` and deletes the second, and the coordinator's one
   `if let fetcher … else legacy` branch with it.
2. **`LibraryInventory` is built by a throwing initializer.** Blank or repeated
   album and track IDs, blank artist IDs, and a track whose album is missing
   cannot be constructed, so the writer never receives an invalid inventory. This
   replaces Plex's `completeAlbum*` helpers. "Repeated" cannot be shown by the
   `Set` and `Dictionary` fields, so the initializer takes arrays. Artist IDs may
   repeat (Plex never checked them).
3. **The membership rule for "mark the inventory due" is the writer's and more
   precise**: a track not stored or under another album, or an album not stored
   or with a different count. Before, any changed album marked it, and the
   targeted pass also compared counts from an explicit album's track list. A
   removed track still marks it (the coordinator does that for deletion hints).
4. **The stale-batch guard ignores a batch** only when its query started before
   the newest committed cursor date and that date is not in the future, so a
   clock set backwards cannot silence sync.
5. **Progress** is coarse (0.1, 0.3, 0.8, 1.0) instead of per phase.

### Behaviour that shifts (all inside the design's approved list or explained)

- Plex gains the stale-response guard (approved in section 5 of the design).
- A complete but empty (or tracks-less, artists-less, albums-less) inventory
  deletes nothing and leaves the inventory due; genres are deleted only from a
  non-empty genre list.
- A full sync now writes only rows whose stored fields differ (the old full sync
  rewrote every row), and fetches everything before writing, so a failed fetch
  leaves the store as it was. `changed*` counts therefore count rows written.
- A full sync records an incremental cursor date too, and the inventory cursor
  records the query start, not the end time.

## Deletion table

`LibraryWriterTests`, on an on-disk store (13 tests, all pass). One source, `A`,
holds artists a1 and a2, albums b1 and b2, tracks t1, t2 and t3; source `B`
holds the same IDs.

| Case | Input | Expected | Test |
| --- | --- | --- | --- |
| Complete inventory | t3, b2, a2 missing | exactly those deleted from `A`, `removedTrackRatingKeys == [t3]` | `testInventoryDeletesOnlyWhatIsMissingAndOnlyFromItsOwnSource` |
| Second source | same pass | `B` keeps every row | same |
| Partial | delta with one track | nothing deleted | `testNothingIsDeletedWithoutACompleteNonEmptyInventory` |
| Empty delta | no rows | nothing deleted | same |
| Complete but empty | empty sets | nothing deleted, full-metadata date unchanged | same |
| Inventory without tracks, without artists | one set empty | nothing deleted, date unchanged | same |
| Failed fetch | the connector throws before any batch | the coordinator never reaches the writer | by construction; the writer validates input in its initializer |
| Invalid inventory | blank artist, blank or repeated album, blank or repeated track, missing album, no album | throws `invalidInventory` | `testAnInventoryThatFailsValidationIsRefusedBeforeAnyWrite` |
| Stale batch | older query arrives after a newer pass, with a full inventory or a deleting one | nothing written or deleted, cursor stays | `testAStaleBatchArrivingAfterANewerOneChangesNothing` |
| Clock set backwards | cursor dated in the future | the batch applies | `testACursorDatedInTheFutureDoesNotMakeEveryBatchStale` |
| Unchanged rows | the same batch twice | second pass writes 0 rows; edits write only changed rows | `testUnchangedRowsAreNotRewritten` |
| Live delta | a batch that also carries an inventory | nothing deleted, only the inventory is marked due | `testALiveDeltaNeverDeletesAndMovesNoCursorButInvalidation` |
| Delta marks inventory due | new track, moved track, new album vs retitled track | due, due, due, not due | `testADeltaThatAddsOrMovesATrackMarksTheInventoryDue` |
| Cancellation | deadline already past | throws, no rows, cursors unchanged | `testACancelledPassWritesNothingAndLeavesTheCursor` |
| Cursors | full, inventory-only, delta | full date, inventory date and incremental date advance by pass kind to the query start | `testCursorsRecordQueryStartAndAdvanceByPassKind` |
| Genres | empty list vs a shorter list | empty keeps all, shorter deletes the missing one | `testGenresAreDeletedOnlyFromANonEmptyGenreInventory` |
| Counts | album left with no tracks | count 0 | `testAlbumCountsComeFromTheInventoryIncludingZero` |

The monotonic cursor rule is `SyncCursorRepository`'s existing `max`, covered by
its own tests; the writer adds the stale guard above.

## Before and after on the real server

iPad Pro 11" simulator `6511F397-5820-4CB5-AB14-8C7F3D164A10`, the live Plex
server, five sources on three servers. Procedure (each build): restore the same
starting store (copied out of the container before any run), install the build,
launch, wait for the app's own startup (incremental) sync, snapshot; launch,
`debug/sync?mode=full`, snapshot; launch, `debug/sync?mode=incremental`,
snapshot. A snapshot terminates the app, copies the SQLite files out read-only
and records per source and entity the row count, a SHA-256 of the identifying
fields (source, rating key, key, title or name, artist or album name) and of all
columns except the volatile and relationship ones, the track-to-album links,
totals and which cursor fields are set. Copies were deleted afterwards.

Builds: "before" is the rename plus debug-route commit (`8696a36d`, behaviour of
`develop`), built from an archive of that commit; "after" is `88dbd440`. Installed
build proven to be the built one: the `Ensemble.debug.dylib` SHA-256 and
`CFBundleVersion` matched before launch each time (before `cc7da12c…`
`202611100907`, after `4dbf9797…` `202611100931`).

Per source after a full sync, before / after:

| Source (account:server:library) | Artists | Albums | Tracks | Genres | Identity checksums | Content checksums | Track-album links |
| --- | --- | --- | --- | --- | --- | --- | --- |
| …:168bc…:4 | 35 / 35 | 43 / 43 | 1451 / 1451 | 3 / 3 | match | match | match |
| …:168bc…:5 | 56 / 56 | 69 / 69 | 439 / 439 | 8 / 8 | match | match | match |
| …:168bc…:7 | 4 / 4 | 4 / 4 | 56 / 56 | 2 / 2 | match | match | match |
| …:6912…:7 | 392 / 392 | 721 / 721 | 9696 / 9696 | 20 / 20 | match | match | match |
| …:ce5e…:5 | 111 / 111 | 238 / 238 | 3756 / 3756 | 13 / 13 | match | match | match |

The startup incremental snapshot is identical for before and after in every
field. After the full sync and after the explicit incremental sync the only
difference is `playlistTrack` 5857 (before) against 5858 (after): the
"Recently Played" smart playlist (4670) holds 276 against 277 rows. That is the
server changing between runs, not the code: a second run of the **before** build
five minutes later reads 5858 and 277 as well, and playlists are untouched code
(step 3d). A first pair of runs also differed in two tracks' play counts and last
played date for the same reason (a client played tracks on the server in
between), and a race in my waiting script made an earlier snapshot cut the sync
short; both were found by re-running with the script fixed and the before build
three times. Run times from the journey log: full sync 10.7 s before, 9.3 to 9.5
s after; incremental 1.9 s both.

Deletion on real data: the Plex server cannot be changed, so I injected into a
copy of the starting store three tracks, one album and one artist cloned from a
real row of one source, with rating keys the server has never had. Both builds
removed all five on the startup sync and ended with a snapshot identical to the
run without them (other sources untouched).

## Review round: deletion-safety fixes

- **Moved track after the delta read.** The repair compares each delta-fetched track's parent with
  the inventory's parent and excludes it from repair only when they agree; the inventory wins.
  Test: `PlexConnectorLibraryFetchTests.testATrackMovedAfterTheDeltaReadSurvivesItsOldAlbumsRemoval`
  (fake server, real connector, writer and on-disk store).
- **Confirming read.** The inventory used for deletion is the union of both reads' identifiers, so a
  row is deleted only when both reads omit it; the second read's data is used for everything else.
  Test: `testADeletionNeedsAbsenceFromBothInventoryReads`.
- **Album to artist closure.** Chosen: the writer never deletes an artist that a stored album still
  references (`removeMissing` keeps `inventory.artistIDs` plus the stored albums' artists). Validating
  closure in the initializer cannot work because inventory-only album entries carry no parent, and
  failing the sync would not protect rows either; keeping the artist cannot delete a listed row.
  Test: `testAnArtistAStoredAlbumStillReferencesIsNeverDeleted`.
- **Genre.** A delta track takes its genre from the stored album when the album is not in the delta.
  Test: `testATrackOnlyDeltaKeepsTheStoredAlbumGenre`.
- **No library protocol.** A connector conforming to neither library protocol now logs an error and
  throws `providerUnavailable` instead of reporting success (removed in 3c).
- **Not fixed, in `ON_DECK.md`:** a pending rating overwritten by sync (over the 40-line budget),
  unbounded full fetch and write, no stale guard on `applyChanges`, rows committed before the cursor,
  hidden entries pruned by a deletion.

## Verification

- `swift test -q --package-path Packages/EnsemblePersistence`: 102 tests, 0 failures.
- `swift test -q --package-path Packages/EnsembleCore`: 1,199 tests, 14 failed
  assertions in five methods, all timing-bound: four in
  `HomeViewModelRefreshPolicyTests` (1 s fulfillment waits) and
  `LibraryViewModelCacheCleanupTests.testBrowseSnapshotPreservesVisibleTracksUntilEmptySourceStateSettles`.
  Re-run alone while the machine was still busy they failed again (8 methods);
  the unmodified base `e8ec7ef0`, run the same way beside a macOS build, failed
  the same classes (85 tests, 16 failed assertions); re-run alone on a quieter
  machine my tree passed 85 of 85. `LibraryWriterTests` (13), the
  `SyncCoordinator*`, `PlexConnector*`, `WebSocketSync*`, `PlaylistRefresh*`
  and `SyncProviderResolver` classes (119 tests) pass.
- `scripts/build_serial.py` for the `Ensemble` scheme: iPad Pro 11" destination
  `** BUILD SUCCEEDED **` for the rename commit, the writer commit and the final
  tree; macOS destination `** BUILD SUCCEEDED **` on the final tree.
- The iPad simulator was shut down and read back as `Shutdown` at the end.

## Not verified

- Background Refresh delivering a library change through the writer, on the
  iPhone (owed in `physical-device-backlog.md`).
- Adding then removing a file in the owned album (the 2026-10-08 check): this
  needs a library mutation on the live server, which this step was told not to
  make. The deletion decisions are covered by the table tests and the injected
  rows instead; the add path, the Siri index save and the offline download
  follow-up are untouched code and not re-exercised.
- A WebSocket-driven targeted pass on the simulator: the server sent no library
  event during the runs, so `fetchChanges` and `applyChanges` are covered by
  `testALiveDeltaNeverDeletesAndMovesNoCursorButInvalidation` and the existing
  `WebSocketSyncControllerTests` only.
- Apple Music, which still writes directly until 3c.
- Timing of the writer's queue behind long batches under a Background Refresh
  deadline (design section 5).
