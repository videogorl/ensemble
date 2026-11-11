# Step 3: shared library writer, close-out (3a to 3e)

Date: 2026-11-11. Design: [`shared-library-writer-design.md`](../reference/shared-library-writer-design.md).
Predecessors: [3a](2026-11-10-step-3a-playlist-membership-constraint.md),
[3b](2026-11-10-step-3b-library-writer.md), [3c](2026-11-10-step-3c-apple-music-writer.md). 3d has no note of its
own; it is written up here. Before step 3: `82b1928e` (`develop` before 3a merged, 2026-11-10 09:00). Step 3d
merged at `a5f2ac81`; this note is on the branch `refactor/step-3e-closeout`.

**Status: step 3 is closed on simulator and iPhone SE evidence. It is not verified.** The project reserves that
word for acceptance on the physical iPhone 16 Pro; what is still owed is listed below and in
[`physical-device-backlog.md`](../reference/physical-device-backlog.md).

## What each sub-step delivered

- **3a, membership constraint.** Model 12 adds `playlistRatingKey` and `playlistSourceCompositeKey` to
  `CDPlaylistTrack` and constrains (`playlistSourceCompositeKey`, `playlistRatingKey`, `order`).
  `PlaylistMembershipBackfill` fills the keys and removes exact duplicates at launch, resumably.
  `PlaylistRepository.setPlaylistTrackSnapshots` reuses the row at each position. `removeDuplicatePlaylists()`
  and its call in `syncAll` are gone. `CDPlaylist.playlistItemsArray` keeps its exact-duplicate guard for a store
  whose backfill has not finished (3a's note explains; see "Not removed" below).
- **3b, writer and Plex library.** `MusicSourceSyncProvider` became `MusicSourceConnector` (and the two
  classes `PlexConnector` and `AppleMusicConnector`). `LibraryWriter`, an actor, became the only code that
  writes Plex library rows, deletes from an inventory or moves a library cursor. `MusicSourceChangeFetching`
  and `LibraryChangeHint` replaced the coordinator's cast to the Plex type. Full and incremental library sync
  became one coordinator path (plan, fetch, apply). `fetchAlbumTimestamps`, `fetchTrackTimestamps` and
  `fetchTrackRatings` were replaced by one summary read.
- **3c, Apple Music library.** `AppleMusicLibraryFetcher` reads the library into a `LibraryBatch`; the
  connector no longer writes rows, deletes orphans or keeps a UserDefaults date. An inventory is attached only
  when the API total, the MusicKit count and the IDs agree, and an empty library that the connector proves
  deletes that source's rows (`emptyIsAuthoritative`, Felicity's decision on 2026-11-10). The transitional
  `MusicSourceLibraryFetching`/`MusicSourceLibrarySyncing` protocols are deleted. Source removal clears the
  source's cursors through the writer. A queued rating survives a sync.
- **3d, playlists on the writer.** Connectors return playlist headers and bodies (`fetchPlaylistHeaders`,
  `fetchPlaylistBodies`) and hold no repository. `LibraryWriter` applies a playlist batch in one serial chain:
  a header's date advances in the save after its body, a read older than the newest committed list read is
  ignored, deletion needs a complete non-empty list, a body that a connector could not prove is reported as
  unresolved and retried, and a pass with unresolved bodies returns `.partial` so background recovery stays
  outstanding. Optimistic creates and appends, confirmed local deletes and edits that cache their effect run
  in the chain; a playlist with a queued add, remove, rename or delete is not overwritten by a read. Apple Music
  playlist bodies need a proof (REST total, or MusicKit's count as a witness;
  `AppleMusicPlaylistInventoryProof`). The "local count above server count" repair is gone (issue #98), as are
  the Plex playlist UserDefaults keys and the full-sync fallbacks in `PlaylistRefreshController`.
- **3e, this close-out.** Removed the Plex change set's `uniqueCount`; added the capability-flag agreement
  test; wrote the connector rule and the new writer rules into the `architecture` skill; rewrote the
  `known-issues` duplicate entry; removed the freeze line from `CLAUDE.md`; this note and the backlog and plan
  updates.

## 3e: what was removed, and the caller search for it

The design names five repository reads to remove (`fetchAlbumTimestamps`, `fetchTrackTimestamps`,
`fetchTrackRatings`, `fetchPlaylistLocalTrackStates`, `fetchPlaylistTimestamps`), plus `removeDuplicatePlaylists`.
`rg -n '\b<name>\b' --glob '*.swift' .` finds no occurrence of any of the six: 3b to 3d already deleted them.

To find what else 3a to 3d left unused, three searches over `Packages/`, `Ensemble/`, `EnsembleWatch/` and the
Siri extension (tests included, then production only):

1. Every protocol requirement of `LibraryRepositoryProtocol`, `PlaylistRepositoryProtocol`,
   `SyncCursorRepositoryProtocol` and `PendingMutationRepositoryProtocol` (121 function names): count calls
   outside the repository files, outside tests, excluding the declarations.
2. Every declaration in the sync, writer, connector, coordinator and repository files, flagged when its name
   occurs in production code no more often than it is declared.
3. The same test over every non-test Swift file changed between `82b1928e` and `HEAD` (51 files).

Removed (one commit, `8c40a707`):

- `PlexConnector.IncrementalChangeSet.uniqueCount`: its only production readers were the incremental-sync log
  lines that 3b deleted (`git show 1b1da095`). The one test that asserted it now reads `uniqueItems.count`.

Left in place:

| Symbol | Why it stays |
| --- | --- |
| `LibraryRepository.upsertTrack`, `upsertGenre`, `PlaylistRepository.setPlaylistTracks`, `fetchGenres` | No production caller, but about 20 test call sites seed stores through them and about a dozen fakes implement them; the instruction was to keep what a test needs. Recorded in `ON_DECK.md` with the next step |
| `CoreDataStack.onDisk(at:)`, `onDiskWithoutBackfill` | Test-only by design (SQLite stores that enforce the constraint) |
| `CDPlaylist.playlistItemsArray` exact-duplicate guard | The design lists it for deletion, but removing it changes what a store with an unfinished backfill shows, so it is a behaviour change. 3a's note records it as a 3e candidate once the backfill's completion is durable |
| `AppleMusicConnector.Attributes.hasCatalog`, `PlaylistViewModel.isPlaylistPendingCreation` | Unused, but they predate step 3 (`a387ff2c`, `3fd55d25`); in `ON_DECK.md` |
| `*ForTesting` hooks on `SyncCoordinator` and others | Pre-existing; not left unused by 3a to 3d |

Name-based scans cannot see a reference through a differently named wrapper or a dynamic lookup, so this is a
search result, not a proof of absence. The builds below would have failed on a removed symbol that was in use.

## The capability-flag agreement test

`MusicSourceCapabilityAgreementTests` (one table-driven test): for each source type, `MusicSourceCapabilities`
must say `supportsLyrics`, `supportsAudioFileInfo`, `supportsCollectionRatings` and `supportsOfflineDownloads`
exactly when the connector conforms to `MusicSourceLyricsProviding`, `MusicSourceFileInfoProviding`,
`MusicSourceCollectionRatingMutating` and `MusicSourceTwoPhasePlaybackResolving`. Checked once that it can
fail: with Plex's `supportsLyrics` flipped to false it failed with "PlexConnector supportsLyrics vs
MusicSourceLyricsProviding".

`AppleMusicConnector` exists only on iOS 18, so the Apple Music row is inside `#if os(iOS)`. `swift test` runs on
the Mac, so that row compiles in the iOS build for testing but is not run by the package test command; see
"Not verified".

## Evidence

| Sub-step | Tests | Simulator | iPhone SE |
| --- | --- | --- | --- |
| 3a | Persistence: on-disk concurrency test, backfill tests (resumable, track deletion waits for it), migration of model-11 stores with duplicates | iPad Pro 11" migrated a model-11 store with every row doubled (11,644 rows) to 5,822 keyed rows; five real or copied stores migrated on the Mac | Build `202611100947.9277` launched over the SE store; `testPlaylists` passed; the store copied back has 5,827 keyed rows and no duplicate positions |
| 3b | `LibraryWriterTests` deletion table; `PlexConnectorLibraryFetchTests` with a fake server, the real connector, writer and on-disk store | Startup, full and incremental Plex store snapshots identical before and after (15,398 tracks, five sources on three servers) | Not run in 3b |
| 3c | `AppleMusicLibraryFetcherTests`, writer tests, source-removal test | Plex store snapshots identical again; a MusicKit library cannot be authorized on the simulator | Scripted `testM0` to `testM19`: first sync, add a song, remove a song, empty-library case by test only, revoke access, toggle the source, on a 20-song library |
| 3d | `LibraryWriterPlaylistTests`, `AppleMusicPlaylistInventoryProofTests`, `PlexConnectorPlaylistSyncTests`, `WebSocketSyncControllerTests`, three Codex reviews whose fixes landed and whose deferrals are in `ON_DECK.md` | No simulator store comparison is recorded for 3d | Device MCP on build `202611111150.4978`, live PMS, disposable playlist: idle pass, create, add, rename, remove, delete, offline rename and offline add all passed; reorder not run. Rows in the backlog |
| 3e | Capability test above; full package runs below | iOS and macOS builds below | None |

Other phone evidence that touched step 3 code: Apple Music play counts survive a sync (2026-11-11, Device MCP
pass) and the forced and system background refresh runs (build `202611111034.1182`, before 3d's playlist
changes), both in the backlog.

## Verification of this branch

Run on 2026-11-11 at the commit named in the final report, on a machine under load from other sessions.

- `swift test -q` in `Packages/EnsembleAPI`: 87 XCTest tests, 0 failures; Swift Testing 0 tests.
- `swift test -q` in `Packages/EnsemblePersistence`: 102 XCTest tests, 0 failures; Swift Testing 0 tests.
- `swift test -q` in `Packages/EnsembleCore`: 1,274 XCTest tests, 1 failure; Swift Testing 8 tests in 2 suites, all passed. The failure is `StreamingAudioPipelineTests.testDroppedDownloadResumesOrFailsAfterTheReserve` (stream recovery, no sync code). It is intermittent: re-run alone it failed in 2 of 3 runs here and in 1 of 2 completed runs on untouched `develop`. The new capability test and `PlexConnectorTests` pass.
- `scripts/build_serial.py` for the `Ensemble` scheme: `generic/platform=iOS Simulator` and `platform=macOS` both `** BUILD SUCCEEDED **`; `build-for-testing` of the `EnsembleCore` scheme for the iOS Simulator `** TEST BUILD SUCCEEDED **` (compiles the iOS-only Apple Music row). No watchOS build: `EnsembleWatch`, `EnsembleWatchCore`, `EnsemblePlex` and `EnsembleDomain` do not import `EnsembleCore`, and only an `EnsembleCore` symbol was removed. No simulator was booted.

## Measures

Both commands use `82b1928e` as "before" and the tip of this branch as "after". Counts are `wc -l` of the files
as `git show <rev>:<path>` returns them.

**Sync and library-writing source lines** (Core services: provider or connector, protocol, coordinator, refresh
controller, WebSocket sync controller, resolver, the two Apple Music helper files and `LibraryWriter`;
Persistence: all repositories, `SyncCursorRepository`, `RepositoryPredicates`, and the 3a backfill):

| | Before | After |
| --- | ---: | ---: |
| `PlexMusicSourceSyncProvider` / `PlexConnector` | 1,867 | 1,084 |
| `AppleMusicSourceProvider` / `AppleMusicConnector` | 1,916 | 1,301 |
| `AppleMusicLibraryFetcher` + `AppleMusicPlaylistInventoryProof` | 0 | 524 |
| `LibraryWriter` | 0 | 717 |
| `MusicSourceSyncProvider` / `MusicSourceConnector` | 314 | 338 |
| `SyncCoordinator` | 3,840 | 3,782 |
| `PlaylistRefreshController`, `WebSocketSyncController`, `SyncProviderResolver` | 291 | 281 |
| Core services subtotal | 8,228 | 8,027 |
| Persistence repositories | 4,735 | 4,550 |
| `PlaylistMembershipBackfill` | 0 | 163 |
| **Total** | **12,963** | **12,740** |

Net 223 fewer lines (1.7 percent). The design estimated 700 to 1,000 fewer; the writer came in at 717 lines
against 400 estimated, the Apple Music helpers added 524 that the estimate did not count, and the coordinator
shrank by 58 rather than 150 to 250. Test lines in the two packages grew: Core 40,068 to 43,133 and Persistence
4,444 to 4,613. Whole-unit counts below moved for other reasons too (stream recovery, App Intents, UI, the tests of other
work), so they say little about step 3. Same commands as plan section 8, run on a `git archive` of
`82b1928e` and on this tree:

| Unit | Source before | Source after | Tests before | Tests after |
| --- | ---: | ---: | ---: | ---: |
| EnsembleAPI | 6,335 | 6,340 | 2,693 | 2,767 |
| EnsembleCore | 70,431 | 71,351 | 40,068 | 43,133 |
| EnsembleDomain | 1,329 | 1,329 | 330 | 330 |
| EnsemblePersistence | 7,964 | 8,031 | 4,444 | 4,613 |
| EnsemblePlex | 946 | 946 | 206 | 206 |
| EnsembleSiriShared | 1,077 | 1,077 | 371 | 371 |
| EnsembleSupport | 270 | 270 | 106 | 106 |
| EnsembleUI | 46,172 | 46,247 | 2,890 | 2,890 |
| EnsembleWatchCore | 3,760 | 3,760 | 739 | 739 |
| Ensemble | 4,040 | 4,077 | not measured | not measured |
| EnsembleWatch | 3,914 | 3,914 | not measured | not measured |
| EnsembleSiriIntentsExtension | 910 | 910 | not measured | not measured |
| Total | 147,148 | 148,252 | 51,847 | 55,155 |

Commands:

```bash
for f in <the files above>; do git show 82b1928e:<dir>/$f.swift | wc -l; git show HEAD:<dir>/$f.swift | wc -l; done
# whole units, as plan section 8: git archive 82b1928e into a scratch directory, run the section 8 loop there
# and in the working tree.
```

**Fix commits** (plan section 8: commits whose subject starts fix, recover, restore, repair or revert, touching
`EnsembleUI/Sources`, or `*Sync*` files in Core or Persistence; `--no-merges`):

| Window | Count |
| --- | ---: |
| 30 days before 2026-11-10 (2026-10-11 to 2026-11-10) | 2 |
| The 30 days before that (2026-09-11 to 2026-10-11) | 10 |
| Last 30 days, to 2026-11-11 | 3 |
| Step 3 itself, `82b1928e..HEAD` | 1 |

```bash
git log --oneline --no-merges -i -E --grep='^(fix|recover|restore|repair|revert)' \
  --since=<date> --until=<date> <rev> -- Packages/EnsembleUI/Sources \
  ':(glob)Packages/EnsembleCore/Sources/**/*Sync*' ':(glob)Packages/EnsemblePersistence/Sources/**/*Sync*' | wc -l
```

None of the commits in the last 30 days or in step 3's own range touches sync: they are the mirrored Now
Playing fix (`9b42f70b`), the iPhone SE Songs acceptance test (`e685f37e`) and the TV Now Playing restore
(`c273feb5`), all matched through the UI path. The number is too small to show a trend, and it cannot yet: step 3
ran for two days, and 3a to 3d's own review fixes are not named "fix" in the commit subject. The path filter
also stopped matching sync code after the 3b rename (`PlexMusicSourceSyncProvider` became `PlexConnector`, so
it no longer contains `Sync`); adding the connector, `LibraryWriter` and repository paths gives the same 3 and
2. A real comparison needs the next 30 days.

## Not verified, and what is owed

- **Nothing in step 3 has been run on the physical iPhone 16 Pro.** Steps 3a to 3d have rows in the backlog with
  their SE results.
- **Apple Music on the iPhone**: playlist reads and bodies (`meta.total` for playlist tracks, MusicKit's count
  against REST, a playlist deleted in Music, no `inventory withheld` line on a healthy library); a library of
  many thousands of songs not being judged incomplete; play history kept when MusicKit cannot read it.
- **Plex, still owed on a phone**: reorder (needs a finger), an edit from another client arriving by WebSocket,
  repeated tracks and an emptied playlist, a request count for the issue #98 playlist, Background Refresh
  delivering a library change and finishing near its deadline, the owned-album add-and-remove check of
  2026-10-08, offline playlist targets after the 3a migration, and a forced full playlist sync after it.
- **Cases only a test covers**: deleting a scope's last playlist, a `.partial` pass keeping background
  recovery outstanding, an expired background refresh and resuming without a relaunch (the SE could not trigger
  it; `ON_DECK.md` suggests a debug route).
- **iPhone SE 2**: the device that froze on 2026-08-08 has not opened a merged playlist since the constraint.
- **The Apple Music row of the capability test** is compiled by the iOS build but was not run; no test
  action exists for the package on an iOS destination.
- **No live Plex or Apple Music mutation was made for 3e.** The 3d SE run's mutations used a disposable playlist
  with Felicity's approval for that step.
- **Deferred review findings remain open in `ON_DECK.md`**; removing the freeze makes them fixable, it does not
  fix them: a rating changed during a sync's write, a full pass interrupted between its delete saves, an
  Apple Music timeout reported as a cancellation, the in-memory local-edit guard, a queued mutation that never
  uploads freezing its playlist, no refresh after a queued mutation uploads, a REST-only Apple Music playlist
  read again every pass, `.partial` showing "last synced", a failing local delete leaving the last playlist's
  row, playlist favourite writes outside the chain, unbounded full fetch and write, no stale guard on
  `applyChanges`, rows committing before the cursor, and the Hidden-entry findings.
