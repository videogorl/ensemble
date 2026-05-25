# Sync And Refresh Policy

Load this reference for Feed/library freshness, stale-while-revalidate behavior, pull-to-refresh, background refresh, WebSocket-triggered sync, source cleanup, or Siri index/context refresh.

## Policies

- Feed and library surfaces are offline-first: show cached or last-good data immediately, then refresh in the background.
- Empty or failed network results must not overwrite last-good Feed snapshots.
- Feed uses stale-while-revalidate cadence: fetch once per app session or when the last network snapshot is at least 10 minutes old; manual pull-to-refresh bypasses the cadence.
- Refreshable root screens attach `.refreshable` to the native scroll owner for every visible content state and expose `.refreshCommand` so keyboard/menu refresh invokes the active screen's same action.
- Background refresh routes through `BackgroundRefreshCoordinator`, not transient UI view models.
- WebSocket library/update/download events accelerate refresh and sync. Debounce, in-flight guards, cooldowns, polling timers, and foreground refresh remain fallback paths.
- Source cleanup is destructive and must stay outside UI view models. Removed/disabled sources should clean caches, lyrics, artwork, offline targets, downloads, and stale rows through the owning cleanup services.
- Siri media index and context refresh are part of freshness work where relevant and must stay source-scoped. Defer this work while the device is known offline so launch can render cached content first on constrained devices.

## Owners

- `SyncCoordinator` is the sync facade and owns actual sync policy.
- `NetworkLifecycleController` owns app-foreground and network-transition refresh/invalidation planning.
- `PeriodicSyncController` owns foreground timer scheduling and WebSocket-aware polling interval policy.
- `BackgroundRefreshCoordinator` owns app-refresh and foreground freshness sequencing.
- `HomeHubLoader` owns Feed snapshot loading used by Feed and background refresh paths.
- `SourceCacheCleanupService` owns destructive source/all-library cache eviction.
- `PlexWebSocketCoordinator` owns coalesced WebSocket event routing into sync/download/health flows.

## Implementation Hooks

- Use `HomeHubLoader` or `BackgroundRefreshCoordinator` for Feed refresh. Do not create `HomeViewModel` only to refresh background data.
- Keep cached rows visible during refresh after a screen has shown content; mark stale/loading locally rather than blanking the surface.
- Filter cached source rows against enabled sources before publishing browse state.
- Mood browse rows are display categories keyed by normalized title. Plex mood keys are library-local, so merge duplicate mood titles across sources for display and carry per-source mood keys when available. Mood detail pages should use the cached per-source key first and only refetch/resolve the current library's mood key when cached metadata is missing or stale.
- Keep WebSocket event handling idempotent and safe to miss.

## Verification

- Add or update freshness tests for Feed cadence, last-good preservation, manual refresh bypass, and background refresh behavior.
- Use simulator validation for pull-to-refresh, refresh commands, cached-content stability, and source enable/disable flows.
- Use performance gates when changing Feed launch/refresh or high-frequency WebSocket publication behavior.
