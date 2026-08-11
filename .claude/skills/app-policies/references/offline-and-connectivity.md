# Offline And Connectivity Policy

Load this reference for changes involving device connectivity, per-server health, Plex endpoint selection, track availability, WebSocket availability, source status, or offline fallback behavior.

## Policies

- Downloaded tracks are playable even when the device or the track's Plex server is unavailable. Non-downloaded tracks require device connectivity and an available source server.
- Plex streaming on cellular is user-controlled and defaults on. When disabled, non-downloaded Plex tracks are unavailable and queue playback skips them; Apple Music remains governed by MusicKit and the system's media settings. Low Data Mode keeps streaming available when no local payload exists but prefers a valid download when one is available.
- Device offline and server offline are distinct states. UI should report "not available offline" for device-level offline misses and use classified server failure messages for per-server failures.
- Playback queues should filter or skip unavailable, non-downloaded tracks instead of attempting known-unavailable streams.
- Unknown or connecting health is not confirmed unavailability. Queue and row preflight checks should allow the real request to run; only a confirmed offline state should suppress it.
- Server health checks update availability and diagnostics; they must not silently discard cached library data or downloaded playback options.
- When source restoration newly enables a server or an authoritative network transition arrives during a health pass, preserve one owner-coalesced follow-up pass and recompute eligible servers after the in-flight pass completes. Unrelated source-settling updates must not cancel it, startup/foreground/inventory health passes must not overlap, and an earlier pass over stale network or source state must not leave a restored server indefinitely unknown. Cold-launch health belongs to the startup pipeline on both iOS and macOS; the initial scene activation must not race it with foreground freshness.
- When the device is known offline, Plex server API requests must fail fast before URLSession work or endpoint failover probing. Cached/downloaded data should carry the UI until connectivity returns.
- Album, artist, and playlist artwork is part of the offline library cache. Sync should persist detail-grade artwork for artwork-backed detail surfaces before navigation needs it; visible online browsing may still persist artwork as a recovery path. Nuke's image cache is only a rendering/performance layer and is not the source of truth for offline artwork. If a remote artwork URL resolves but the image request fails, visible artwork resolution should retry the persistent local cache before surfacing a placeholder. Artwork metadata/path invalidation should mark persistent artwork stale for online refresh, not delete the file before a replacement exists; stale persistent artwork may be shown while offline or while the server is unavailable.
- Persistent artwork may be smaller than the requested detail size when Plex's source image is smaller. Once a detail-size fetch has succeeded for the current artwork identity, that file is valid offline cache until the source path or modified date changes.
- Plex endpoint selection uses policy-aware ordering: local secure, remote secure, local insecure, remote insecure, then relay. Insecure endpoint use follows the configured insecure-connection policy.
- Endpoint failover may briefly cool down endpoints that just failed lightweight probing at the transport or TLS layer, including timeout, DNS, refused, certificate, handshake, and device-network failures, when another candidate exists. Full request timeouts should trigger failover without preemptively skipping the current endpoint, because the lightweight identity probe may still be the best immediate health signal. If every candidate is cooling down, failover must retry them rather than reporting the server offline from stale cooldown state alone.
- Endpoints selected by server health checks should seed the API client's preferred-endpoint fast path, so a later request-time failover can retry the known healthy endpoint before launching broad parallel probes.
- WebSocket events are acceleration hints. Polling timers, foreground refresh, and circuit breakers must remain fallback paths because some servers reject or close WebSocket connections.
- WebSocket healthy signals from an already-available server should refresh that server's health-check cache instead of triggering or allowing near-term duplicate probes.
- Source identity must include account, server, and library scope where applicable. Library section keys are per-server and are not globally unique.
- Watch server discovery treats each Plex server independently; an unreachable server must not prevent reachable servers and their libraries from loading.

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
