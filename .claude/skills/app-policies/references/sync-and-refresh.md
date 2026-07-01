# Sync And Refresh Policy

Load this reference for Feed/library freshness, stale-while-revalidate behavior, pull-to-refresh, background refresh, WebSocket-triggered sync, source cleanup, or Siri index/context refresh.

## Policies

- Feed and library surfaces are offline-first: show cached or last-good data immediately, then refresh in the background.
- Empty or failed network results must not overwrite last-good Feed snapshots.
- Browse empty/add-source decisions are readiness-owned. `AppReadinessCoordinator` is the source of truth for bootstrap-settled, cached-library/feed-ready, no-source, and no-enabled-library states; Feed/library views must not infer those states from transient account, hub, playlist, or source arrays.
- While iCloud/source restoration is still awaiting source data, library browse surfaces must preserve or publish cached source content using cached source keys as a provisional filter. They must not clear visible album/artist/track content or schedule source cleanup until source restoration has settled.
- Feed uses stale-while-revalidate cadence: fetch once per app session or when the last network snapshot is at least 10 minutes old; manual pull-to-refresh bypasses the cadence.
- Feed/Search hub refresh should use inline Plex hub metadata from the hub payload and skip hubs that do not include usable music metadata. Do not add speculative per-hub item fallback requests without live PMS evidence and tests, because unsupported hub keys can produce repeated 404s during refresh.
- Refreshable root screens attach `.refreshable` to the native scroll owner for every visible content state and expose `.refreshCommand` so keyboard/menu refresh invokes the active screen's same action.
- Background refresh routes through `BackgroundRefreshCoordinator`, not transient UI view models.
- WebSocket library/update/download events accelerate refresh and sync. Debounce, in-flight guards, cooldowns, polling timers, and foreground refresh remain fallback paths.
- Source cleanup is destructive and must stay outside UI view models. Removed/disabled sources should clean caches, lyrics, artwork, offline targets, downloads, and stale rows through the owning cleanup services.
- Sync should pre-cache detail-grade album, artist, and playlist artwork before users navigate into artwork-backed detail surfaces. Existing persistent artwork should only skip sync caching when it satisfies the full-size detail requirement; undersized thumbnails remain fallback files and should be replaced during sync while the server is available.
- Incremental playlist sync should fetch added/updated playlists each run, but full playlist inventory for orphan removal should run only after playlist changes, first/full sync, or a periodic cleanup window. Startup sync must avoid repeating inventory-only orphan checks when Plex reports no playlist changes and a recent cleanup exists.
- Full/manual playlist sync should refresh playlist inventory metadata, then fetch playlist track lists only for new or server-updated playlists. Keep a deliberate repair/full-resync path if future recovery tooling needs to rebuild every playlist body.
- If Plex returns source artwork below the requested detail size, the successful detail-size fetch attempt should be recorded with the persistent artwork identity so future syncs do not re-download the same server-limited image until the source path or modified date changes.
- Siri media index, media context refresh, and automatic startup sync are freshness work where relevant and must stay source-scoped. Defer this work while the device is known offline, coalesce concurrent Spotlight/Siri index refresh requests, and route startup sync plus Spotlight/Siri indexing through foreground idle budgeting so launch, scrolling, navigation, Now Playing gestures, share sheets, and audio-critical windows remain responsive on constrained devices.
- Constrained legacy devices such as iPhone 6s/iPad Air 2 should use a longer foreground idle delay before nonessential work. Navigation events from `NavigationCoordinator` must mark the `ForegroundWorkScheduler` as navigating so automatic startup sync cannot begin under a tab change, push, pop, or external route transition.

## Owners

- `SyncCoordinator` is the sync facade and owns actual sync policy.
- `NetworkLifecycleController` owns app-foreground and network-transition refresh/invalidation planning.
- `PeriodicSyncController` owns foreground timer scheduling and WebSocket-aware polling interval policy.
- `BackgroundRefreshCoordinator` owns app-refresh and foreground freshness sequencing.
- `HomeHubLoader` owns Feed snapshot loading used by Feed and background refresh paths.
- `AppReadinessCoordinator` owns launch/source/cache readiness snapshots consumed by browse surfaces.
- `ForegroundWorkScheduler` owns idle gating for nonessential refresh-adjacent indexing and retry work.
- `SourceCacheCleanupService` owns destructive source/all-library cache eviction.
- `PlexWebSocketCoordinator` owns coalesced WebSocket event routing into sync/download/health flows.

## Implementation Hooks

- Use `HomeHubLoader` or `BackgroundRefreshCoordinator` for Feed refresh. Do not create `HomeViewModel` only to refresh background data.
- Keep cached rows visible during refresh after a screen has shown content; mark stale/loading locally rather than blanking the surface.
- Feed, playlist, artist, album, track, genre, and library browse refreshes should publish committed snapshots atomically. Degraded empty/partial reloads should preserve the current visible snapshot until bootstrap is settled and the repository confirms the empty state is authoritative.
- Genre browse rows are normalized display categories keyed by title and must be backed by at least one visible album genre match. Duplicate genre titles across visible enabled sources should merge for display, and genre detail should resolve albums from cached album genre metadata across those visible sources without requiring a live Plex refetch.
- Filter cached source rows against enabled sources before publishing browse state.
- Mood browse rows are display categories keyed by normalized title. Plex mood keys are library-local, so merge duplicate mood titles across sources for display and carry per-source mood keys when available. Mood detail pages should use the cached per-source key first and only refetch/resolve the current library's mood key when cached metadata is missing or stale.
- Keep WebSocket event handling idempotent and safe to miss.
- `SyncCoordinator` owns full-size persistent artwork pre-caching through `cacheAlbumArtwork`, `cacheArtistArtwork`, and `cachePlaylistArtwork`; detail views should treat sync output as the durable cache source and use visible loading only as a recovery path.
- `ArtworkIdentity.requestedPixelDimension` records the largest persistent artwork request already attempted for the current source identity; `ArtworkDownloadManager.localArtworkExists` uses it to distinguish stale thumbnails from server-limited detail responses.

## Verification

- Add or update freshness tests for Feed cadence, last-good preservation, manual refresh bypass, and background refresh behavior.
- Use simulator validation for pull-to-refresh, refresh commands, cached-content stability, and source enable/disable flows.
- Use performance gates when changing Feed launch/refresh or high-frequency WebSocket publication behavior.
