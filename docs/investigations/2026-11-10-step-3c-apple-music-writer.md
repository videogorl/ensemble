# Step 3c: Apple Music library on the writer, one coordinator path

Date: 2026-11-10. Design: [`shared-library-writer-design.md`](../reference/shared-library-writer-design.md)
sub-step 3c. Predecessor: [`2026-11-10-step-3b-library-writer.md`](2026-11-10-step-3b-library-writer.md).
Commits on top of `dfaba101`: `e8d928b3` (pending rating fix), `d9150fee` (Apple Music onto the writer),
`5d97313b` (drop unused progress plumbing), plus the documentation commit.

## What changed

- **`AppleMusicLibraryFetcher`** (new, `Services/AppleMusicLibraryFetcher.swift`, not iOS-only) reads the
  Apple Music library into a `LibraryBatch` through an `AppleMusicLibrarySource` protocol (REST song list,
  MusicKit metadata, authorization status). The REST and MusicKit-backed source stays in
  `AppleMusicConnector` (iOS 18); the fetcher, the `LibrarySong`/`Page` decoding types and the row mappers
  moved out of the iOS-only file so the decision logic runs under `swift test` on the Mac.
- **`AppleMusicConnector`** now has `fetchLibrary(plan:)`. It no longer writes library rows, deletes orphans,
  prunes Hidden items, or keeps `sources.appleMusic.libraryInventory.authoritativeDate` in UserDefaults.
- **`MusicSourceConnector.fetchLibrary(plan:)` is a requirement.** `MusicSourceLibraryFetching` and
  `MusicSourceLibrarySyncing` are deleted, and so is the coordinator's `if let fetcher ... else legacy` branch.
  `SyncCoordinator.syncLibrary` is plan, fetch, apply for every source.
- **Source removal** always calls `libraryWriter.removeCursor(for:)`; the Plex-only branch and the call into the
  Apple Music type (`clearLibraryInventoryState`) are gone.
- **`LibraryBatch`** gained `tracksWithoutPlayHistory` (tracks whose last played date and play count the source
  could not read: the writer keeps the stored values, replacing the old `existing:` parameter) and
  `sourceDisplayName`/`sourceAccountName` (the writer's source upsert used to write nil names; Apple Music's row
  is "Apple Music" / "This Device").
- **Pending rating fix** (own commit, `e8d928b3`): `LibraryWriter` takes `PendingMutationRepositoryProtocol`;
  for tracks with a queued `trackRating` mutation it substitutes the stored rating, favourite flag and
  `lastRatedAt` before the changed-row comparison. The ON_DECK entry is removed.

Lines (whole branch against `dfaba101`): `EnsembleCore/Sources` +450 / -495, about 260 of the added lines are
moved unchanged (the decoding types and mappers); `AppleMusicConnector.swift` 28 added, 433 removed.
`EnsembleCore/Tests` +605 / -485.

## How an Apple Music inventory is judged complete

An inventory (what lets the writer delete) is attached only when all of these hold; otherwise the rows are
written as a delta and nothing is deleted:

1. `MusicAuthorization.currentStatus == .authorized` before the first page and again after the last.
2. Every page of both reads arrived. A thrown error, a cancelled request or a failed page ends the pass with no
   batch at all.
3. The API's `meta.total`, when the first page carries one, equals the number of songs received.
4. Every song MusicKit lists is in the REST list. Neither read gives a total of its own, so MusicKit being
   larger than the REST list is the only sign that a `next` chain stopped early. (The reverse, REST larger,
   can only keep rows.)

The writer then adds its own checks (blank or repeated IDs, a track whose album is missing, an inventory without
songs, a stale batch). A complete but empty library deletes nothing, per the owner's decision. A pass that is
not due for an inventory (cursor under 24 hours old) reads nothing.

Risk: condition 4 assumes MusicKit item IDs and REST library IDs are the same ID space (the existing code
already matched them for dates and play counts). If they were not, the inventory would be withheld on every
pass and removals would never apply; that fails safe and shows as `Apple Music inventory withheld` in the log.
This is the first check owed on the iPhone.

## Existing users' sync date

The UserDefaults date is not migrated. With no library cursor, the first pass after the update plans an
inventory, reads the whole library (what the old code did at most once a day anyway) and records the cursor;
that pass passes through the same checks as every other, so it cannot delete on weaker evidence than before.
The old UserDefaults entry is left in place unread (one date, harmless).

## Test table

`AppleMusicLibraryFetcherTests` (fake source, on-disk store, real writer) unless noted.

| Case | Expected | Test |
| --- | --- | --- |
| Complete inventory, one song fewer | the song, and its now-empty album, are deleted; removed track IDs reported | `testACompleteInventoryDeletesOnlyWhatTheLibraryNoLongerHolds` |
| MusicKit lists a song the REST list lacks (list ended early) | written as a delta; nothing deleted; inventory date unchanged | `testNothingIsDeletedUnlessTheReadIsProvedComplete` |
| API total larger than songs received | same | same |
| A page failed / request cancelled / MusicKit read failed | the pass throws; store and inventory date unchanged | same |
| Authorization revoked before, or mid-fetch | the pass throws; store unchanged | same |
| Empty library over a stored one | nothing deleted | `testAnEmptyLibraryDeletesNothing` |
| Apple pass vs a Plex source with the same rating keys, and the reverse | each leaves the other's rows | `testAnApplePassAndAPlexPassNeverTouchEachOthersRows` |
| Identical second pass | 0 rows written; source names kept | `testAnUnchangedLibraryWritesNothing` |
| Recent inventory, then a day later | no read, then a read; names kept | `testAPassNotDueForAnInventoryReadsNothing` |
| MusicKit has no history for a stored song | stored play count kept | `testStoredPlayHistoryIsKeptWhenMusicKitHasNoneForASong` |
| Source removal, Apple removed and Plex retained, and the reverse | removed source's rows and cursor gone, the other's kept | `SyncCoordinatorExecutionTests.testSourceRemovalClearsRowsAndCursorsForThatSourceOnly` |
| Queued rating vs a server value | queued rating kept; others take the server's; kept no longer once uploaded | `LibraryWriterTests.testASyncDoesNotReplaceARatingWhoseUploadIsStillQueued` |
| Writer deletion table from 3b | unchanged, still passes | `LibraryWriterTests` (15) |

Checked once that the suite can fail: with condition 4 disabled the "MusicKit lists a song" case fails.
Mapping tests for the moved decoding and mappers (`AppleMusicLibraryFetcherMappingTests`, 3) were moved out of the
iOS-only block of `DisplayPlaylistGroupingTests` so they run on the Mac; the three tests of the deleted UserDefaults
date and cadence helpers and the unused page-progress test were removed (the cadence is the writer's
`testPlanDueDatesFollowTheCursor`). About fourteen test fakes that conformed to `MusicSourceLibrarySyncing` now
return a batch from `fetchLibrary`; `LibraryBatchFixtures.swift` builds a batch of N new rows. A few coordinator
tests that ran with an `EmptyLibraryRepository` now use an in-memory `LibraryRepository`, because every source
passes through the writer.

## Plex before and after (iPad Pro 11" simulator `6511F397-5820-4CB5-AB14-8C7F3D164A10`)

Same method as 3b: restore one starting store after each install, launch, wait for the startup (incremental) sync,
snapshot; launch and open `ensemble://debug/sync?mode=full`, wait for `syncFinished`, snapshot; the same for
`mode=incremental`. A snapshot terminates the app, copies the SQLite files and records, per source and entity,
the row count, a hash of the identifying fields, a hash of all non-volatile columns, the track-to-album links,
which cursor fields are set, source rows and playlist counts. Differences from 3b's tooling: the startup wait polls
the store for every source's last sync date rather than a log line (the debug log lines are not visible), and
`simctl install` replaces the app's data container, so the starting store is copied in after each install.

Builds: before is an archive of `dfaba101` (`Ensemble.debug.dylib` SHA-256 `4864ca84…`, `CFBundleVersion`
`202611101028`); after is the final tree (`9b04552a…`, `202611101021.8928`). The installed dylib hash matched the
built one before each run. Five sources on three servers, 15,398 tracks.

Result: **startup, full and incremental snapshots are identical** (no differing field) for the before and the
after build, both for the first after build and for the rebuilt one after the simplify pass. Journey log: full sync
about 8.3 s before and after, incremental 1.2 s before and after. No server-side drift appeared this time.

## Apple Music at runtime

The iOS Simulator cannot authorize a MusicKit library on this Mac. A bare MusicKit executable run on the
simulator reported `MusicAuthorization.currentStatus == denied`, and both `MusicLibraryRequest<Song>` and a
`MusicDataRequest` to `/v1/me/library/songs` failed with `permissionDenied`. This is a probe of a bundle-less
binary with no Apple ID on the simulator, not a drive of the app's authorization prompt; I did not sign the
simulator into an Apple ID. No before and after Apple Music store comparison was possible; the iPhone checks are
in [`physical-device-backlog.md`](../reference/physical-device-backlog.md).

## Verification

- `swift test -q --package-path Packages/EnsembleCore`: 1,219 tests, 0 failures (run once at the end; the timing
  classes that failed under load in 3b passed).
- `swift test -q --package-path Packages/EnsemblePersistence`: 102 tests, 0 failures.
- `scripts/build_serial.py` for the `Ensemble` scheme on the iPad Pro destination: `BUILD SUCCEEDED` (compiles the
  iOS-only connector); `build-for-testing` of the `EnsembleCore` scheme for the same destination:
  `TEST BUILD SUCCEEDED` (compiles the iOS-only tests).
- The iPad simulator was shut down and read back as `Shutdown`. The Ensemble app installed on it is the final
  build with the store left by the last run.

## Not verified

- Anything Apple Music at runtime (see above). The iOS-only Apple Music tests in `DisplayPlaylistGroupingTests`
  compile but are not run: the `EnsembleCore` scheme has no test action and the package tests run on the Mac.
- The healthy-library assumption behind condition 4 (matching ID spaces) and the REST `meta.total` field are
  assumptions until a real library is read.
- The pending-rating substitution is tested at the writer; a queued favourite surviving a real offline sync on a
  device is not run.
- Cancellation or Background Refresh deadlines during an Apple Music pass.
