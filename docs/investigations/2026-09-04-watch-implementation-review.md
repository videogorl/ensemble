# Apple Watch implementation review

Reviewed commit: `8aff52de`. Scope: UI, navigation/data speed, and reliability across cold starts. This is a source assessment plus six existing package checks; no physical Watch or simulator UI inspection was performed. Performance effects below are code-derived risks, not measured timings. No production code was changed.

## Recommended order

| Order | Improvement | Impact | Relative effort |
| --- | --- | --- | --- |
| 1 | Restore the saved library before network discovery | Cold-start browsing and offline reliability | Medium |
| 2 | Make remote queue requests recoverable | Prevent stuck loading and ignored controls | Small–medium |
| 3 | Persist detail membership and refresh in place | Faster playlist/genre revisits and cold starts | Medium |
| 4 | Separate playback position checkpoints from queue writes | Main-thread work and write volume | Medium |
| 5 | Retain hidden-media state through launch and cloud failure | Consistent visible library | Small–medium |
| 6 | Reject obsolete bootstrap/autoplay results | Prevent stale state and wrong recommendations | Small–medium |
| 7 | Cache browse projections and scope database reads | Large-library navigation speed | Medium |
| 8 | Recover from persistent-store opening failure | Avoid a launch crash loop | Medium; shared owner |

## Findings

### 1. Full cached browsing waits for live discovery

`WatchExperienceModel.bootstrap` loads `loadHomeSnapshot`, which deliberately has no albums, artists, playlists, tracks, or genres. The full `loadSnapshot` occurs only inside `finishBootstrap`, after server discovery and `loadPlaylistTargets`. The supposedly cached-library reconstruction also calls Plex resources over the network, followed by another resources fetch in discovery.

Consequently, a slow network delays access to already-saved categories; if credentials or discovery fail, the model reports ready with only the home snapshot and never loads the full saved library. A user can enter a category and see “No Albums” despite rows existing on disk. Restored playback also resolves its stream against `libraries`, which initially remains empty.

First fix: hydrate saved browse state independently of credentials/discovery, retaining source selection information. Discover and refresh afterward; fetch playlist mutation targets when their actions need them. Loading database categories on demand can follow if full hydration is measurably expensive. Restored Play should either wait for source resolution with a clear status or expose a retry.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:2332`, `:2375`, `:1876`; `Packages/EnsembleWatchCore/Sources/WatchCatalogStore.swift:186`; `Packages/EnsemblePlex/Sources/EnsemblePlex.swift:285`.

### 2. Remote Queue can remain on a loader after a dropped request

`WatchSessionModel.requestQueue` clears the previous queue before calling `send`. `send` silently returns for callers without a completion when any command is already in flight. Read requests occupy this same slot while `isCommandInFlight` remains false because they are non-mutating.

A concrete path is opening Now Playing, which requests playlist targets, then opening Queue before that reply arrives. Queue loses its saved rows, its request is rejected, and the view displays “Loading queue.” Its task depends only on playback target, so finishing the earlier request or becoming reachable does not retry it. Transport buttons can likewise appear enabled while a read request causes their commands to be discarded.

First fix: retain the last queue during refresh, represent queue loading/error explicitly, and coalesce or defer the queue read until it can run. Retry on reachability recovery and provide an explicit retry action. Avoid blindly replaying mutating commands.

Evidence: `EnsembleWatch/App/WatchSessionModel.swift:135`, `:219`; `EnsembleWatch/Views/WatchRootView.swift:2344`, `:2439`, `:2734`.

### 3. Detail loading is not a durable cache

Playlist-group and genre entry points set `detailTracks = []` and fetch again on every appearance. The catalog store persists playlist summaries, but no playlist membership. Fetched detail results only populate the model's shared `detailTracks`; they are not saved back to the catalog. Album/artist details can seed from catalog tracks, but their fresh results also disappear on the next visit or launch.

For album/artist details, a successful empty response cannot clear cached tracks because assignment requires a nonempty result. That preserves stale tracks even when the server legitimately returns none.

First fix: persist successfully loaded membership with source identity and ordering, show it immediately, and refresh in place. Keep unavailable responses distinct from authoritative empty responses. Use destination-scoped detail state as needed: the existing request-ID guard protects against older requests, but all detail screens still share one result array.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:1505`, `:1601`, `:1616`, `:2603`; `Packages/EnsembleWatchCore/Sources/WatchCatalogStore.swift:39`; `EnsembleWatch/Views/WatchRootView.swift:896`.

### 4. Every five-second position checkpoint rewrites the full queue on MainActor

The playback-time subscription runs on the main run loop and invokes synchronous queue persistence. This builds and JSON-encodes the queue, original queue, and history, then atomically rewrites the file. The display limit does not bound the persisted queue: the persistence policy removes future autoplay items but retains the ordinary queue. Large song collections therefore make the work scale with queue size every five seconds and at launch. Save errors are swallowed.

First fix: serialize file work off the main actor, save queue structure only when it changes, and checkpoint position separately. Preserve ordered writes and a reliable background checkpoint. Report persistence errors through privacy-safe logging. Measure on a Watch with a large queue before choosing further storage changes.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:1322`, `:1368`, `:561`; `Packages/EnsembleWatchCore/Sources/WatchPlaybackQueueStore.swift:83`, `:100`; `Packages/EnsembleDomain/Sources/PlaybackQueuePolicy.swift:127`.

### 5. Hidden media reappears when cloud state is unavailable

Hidden identities start empty and have no local persisted restoration. Cloud lookup returns an empty set both for valid empty state and for any error; `refreshHiddenMedia` unconditionally replaces the current identities with it. Cold launch can reveal hidden items until CloudKit responds, and a later cloud failure can reveal them again.

First fix: persist the last successful hidden-state snapshot, seed it before publishing browse content, and retain it on transport/decode failures. Successful empty state should still clear it.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:1195`, `:1251`, `:2239`.

### 6. Bootstrap and autoplay lack complete stale-result protection

Refresh cancels the previous bootstrap task, but the bootstrap ID guards only task cleanup, not state publication or persistence. The database continuation does not propagate cancellation, and several called operations catch errors. An older operation can therefore resume and publish or clear shared sync state after a new refresh starts. Manual selected-library sync is a separate task path.

Autoplay requests are untracked tasks. They do not revalidate the seed, queue revision, or whether autoplay is still enabled before appending their results. Replacing the queue or disabling autoplay during a slow recommendation fetch can still admit old recommendations.

First fix: check a current operation ID before applying bootstrap results, serialize catalog refresh entry points, and cancel/revalidate autoplay requests against the active queue. Reuse the request-ID pattern already present in detail and stream preparation.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:1451`, `:2128`, `:2317`, `:1948`.

### 7. Database adoption still leaves full-library processing in browse rendering

`libraryTracks`, `libraryAlbums`, `libraryArtists`, and `playlistGroups` filter/merge collections on every access. Category sections then filter, sort, and group again; some bodies evaluate the same computed section array more than once. These views observe the broad experience model, so unrelated published status/queue changes can cause that work to repeat. The store loads all current tracks, and each upsert fetches all existing rows of its entity, including older retained rows.

First fix: hold display-ready projections keyed by actual catalog/preference/search changes, compute each section list once per render, and query detail/category rows by source and identity. Keep the existing native lists and system Crown scrolling. Profile before replacing persistence or introducing a new framework.

Evidence: `Packages/EnsembleWatchCore/Sources/EnsembleWatchCore.swift:1373`; `EnsembleWatch/Views/WatchRootView.swift:669`; `Packages/EnsembleWatchCore/Sources/WatchCatalogStore.swift:201`, `:321`, `:381`.

### 8. Persistent-store failure terminates launch

The Watch's default catalog store constructs shared `CoreDataStack`, whose persistent-store load callback calls `fatalError` for any opening/migration error. The Watch cannot show a recovery screen in that case. This is a code-confirmed failure path, not evidence that a real user's store is currently damaged.

First fix: expose a recoverable store-unavailable state through the shared persistence owner, retain the store for diagnosis/retry, and allow recovery UI. Do not automatically delete persisted user data.

Evidence: `Packages/EnsembleWatchCore/Sources/WatchCatalogStore.swift:17`; `Packages/EnsemblePersistence/Sources/CoreData/CoreDataStack.swift:27`.

## Smaller UI and continuity improvements

- **Use source-aware pin identity.** Home uses `ForEach(snapshot.pins)` and the model's plain Plex ID. Identical IDs from different servers collide. Reuse `watchListID`, already used by other rows. Evidence: `EnsembleWatch/Views/WatchRootView.swift:241`; `Packages/EnsembleDomain/Sources/EnsembleDomain.swift:147`.
- **Show connection freshness alongside remote metadata.** The restored application context is accepted without checking `updatedAt`, and its handler says “Connected to iPhone” even when reachability is false. Preserve last-known metadata but label it appropriately. Evidence: `EnsembleWatch/App/WatchSessionModel.swift:299`, `:311`, `:469`.
- **Make track lists reachable with less scrolling.** Sort and Favorites controls occupy the first section of every detail list; category lists similarly lead with Order. Consider a native menu for these less-frequent controls. Let collection titles wrap beyond their current single line. Validate on the smallest supported Watch and larger text settings. Evidence: `EnsembleWatch/Views/WatchRootView.swift:732`, `:919`, `:2087`.
- **Restore useful navigation after process death.** Navigation path, selected pin, sheet presentation, and browse options are all view-local state. Consider saving the last meaningful source-scoped destination and options, validating them against restored content before reopening. This is a product improvement, not an existing restoration promise. Evidence: `EnsembleWatch/Views/WatchRootView.swift:17`, `:516`, `:877`.
- **Guard artwork publication after async work.** Now Playing clears its artwork at load start and does not check cancellation/current identity before assigning the asynchronously loaded image. The media-player artwork setter checks the track, but the view assignment does not. Retain the current image during same-item refresh and reject obsolete results. Evidence: `EnsembleWatch/Views/WatchRootView.swift:2984`.

## Validation and limits

Six existing WatchCore tests passed: catalog persistence/home-only load, playback queue round-trip, queue file migration, cached bootstrap readiness, early cached pins, and last-good snapshot selection. The command was:

```sh
swift test -q --package-path Packages/EnsembleWatchCore --filter 'EnsembleWatchCoreTests.test(WatchCatalogStorePersistsCatalogRowsAndLoadsHomeOnly|WatchPlaybackQueueStoreRoundTripsAllQueueState|WatchPlaybackQueueStoreMigratesDefaultsToAtomicFile|CachedCatalogStartsReadyAndRefreshesOnlyWhenStale|CachedPinsAreAvailableBeforeCloudBootstrapCompletes|RefreshKeepsLastGoodCatalogUntilSelectedContentArrives)'
```

These tests use host-side package execution and in-memory catalog stores; they do not prove Watch relaunch, physical storage durability, network recovery, scrolling, or launch latency. Core Data emitted entity-model ambiguity warnings during the in-memory test run; all six checks passed. The bootstrap test uses an empty catalog and does not assert populated offline browsing.

The highest-value next runtime check is a fresh Watch build with two sources: browse a large library and playlist, terminate the app, relaunch with network unavailable, then reconnect while opening Queue and issuing transport commands. Capture time to first usable cached content, source-scoped row counts, write duration, and visible recovery states. No new tests or production changes were added for this assessment.
