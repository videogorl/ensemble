# System Integration Recipes

## Siri, App Intents, Spotlight, And Now Playing

- Put pure identity, payload, normalization, scoring, and index codecs in
  `EnsembleSiriShared`.
- Keep extensions thin: resolve/disambiguate, encode a versioned handoff, and
  return to the app. Playback executes in `SiriPlaybackCoordinator`.
- Direct IDs require exact source identity. Source-less requests may fuzzy-match
  within enabled sources but never infer ownership from a media ID.
- `SystemMediaIntegrationService` owns donations and Spotlight deltas;
  `PlaybackNowPlayingBridge` owns MediaPlayer singleton writes.
- Donate only direct app-UI starts. Delete Spotlight entries by explicit or
  source-scoped identity, never globally.
- Portable links contain descriptive metadata, not credentials/source IDs, and
  resolve into scene-local navigation without autoplay.

## Watch Placement

Portable models live in `EnsembleDomain`, Plex facade work in `EnsemblePlex`,
Watch services/cache/playback in `EnsembleWatchCore`, and Watch SwiftUI in the
Watch target. Do not link full `EnsembleCore` or `EnsembleUI`.

## KVS

Use KVS only for small preference data. Add a stable key, an explicit sync
toggle, remote apply logic, local push wiring, dependency-container observation,
and echo suppression through the existing service. Gate both push and apply by
the toggle; source credentials and provider-local catalogs do not belong in KVS.
