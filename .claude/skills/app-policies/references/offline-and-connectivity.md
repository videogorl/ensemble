# Offline And Connectivity Policy

Load this reference for changes involving device connectivity, per-server health, Plex endpoint selection, track availability, WebSocket availability, source status, or offline fallback behavior.

## Policies

- Downloaded tracks are playable even when the device or the track's Plex server is unavailable. Non-downloaded tracks require device connectivity and an available source server.
- Device offline and server offline are distinct states. UI should report "not available offline" for device-level offline misses and use classified server failure messages for per-server failures.
- Playback queues should filter or skip unavailable, non-downloaded tracks instead of attempting known-unavailable streams.
- Server health checks update availability and diagnostics; they must not silently discard cached library data or downloaded playback options.
- Plex endpoint selection uses policy-aware ordering: local secure, remote secure, local insecure, remote insecure, then relay. Insecure endpoint use follows the configured insecure-connection policy.
- WebSocket events are acceleration hints. Polling timers, foreground refresh, and circuit breakers must remain fallback paths because some servers reject or close WebSocket connections.
- Source identity must include account, server, and library scope where applicable. Library section keys are per-server and are not globally unique.

## Owners

- `PlexConnectionPolicy`, `ConnectionFailoverManager`, and `ServerConnectionRegistry` own endpoint ordering, probing, and selected connection state.
- `ServerHealthChecker`, `ServerConnectionController`, and `SyncCoordinator` own server availability, failure messages, and source status publication.
- `TrackAvailabilityResolver` owns track-level availability classification for UI rows.
- `PlaybackService` and `PlaybackTransportCoordinator` own playback-time enforcement and recovery when availability changes.
- `PlexWebSocketManager` and `PlexWebSocketCoordinator` own socket lifecycle, event routing, debounce, and fallback signaling.

## Implementation Hooks

- Reuse `sourceCompositeKey` and server keys rather than deriving availability from display names or library keys alone.
- Prefer cached/downloaded data before network attempts when offline or degraded.
- Keep failure reasons privacy-safe and user-actionable. Do not expose tokens, raw URLs, or query strings in diagnostics.
- When changing Plex streaming or transport behavior, also load `plex-api` and run live curl checks using `.env` credentials before code changes.

## Verification

- Add or update unit tests around endpoint ordering, server health classification, and track availability when those policies change.
- Use simulator validation for user-visible offline/online behavior, unavailable row states, or playback fallback.
- For WebSocket changes, verify that polling or manual refresh still covers missed events.
