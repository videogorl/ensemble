# Playback And Queue Policy

Load this reference for playback start behavior, queue state, shuffle/repeat/autoplay, offline queue filtering, local-file playback, transport recovery, prefetch, reporting, or system-media donation behavior.

## Policies

- `QueueManager` is the source of truth for queue order, sections, history, shuffle, repeat, and autoplay state.
- Regular play disables shuffle and starts from the requested index. Shuffle play enables shuffle, preserves original order for restore, and starts from the shuffled queue.
- Toggling shuffle keeps the current item, excludes autoplay items from the shuffle candidates, filters already played history from candidates, and restores original order when disabled.
- Queue navigation records history before advancing, restarts the current track when Previous is invoked after the configured restart threshold, and wraps only when repeat-all is enabled.
- Autoplay is a separate queue section. It should not be treated as manually queued content or shuffled into the main future queue.
- Playback start paths must pass `PlaybackStartContext`. Only direct app UI starts donate to system media; Siri, App Shortcuts, remote commands, autoplay, restoration, and background recovery are non-donating.
- macOS Dock menu playback controls are user commands for the existing queue/playback state. They must dispatch through `PlaybackService`/active Now Playing owners and must not add system-media donations or mutate `MPRemoteCommandCenter` directly.
- Playback should prefer valid local files/downloads when present. Corrupt or invalid local files fail locally while online paths may recover by streaming or refreshing.
- Device-offline queues are filtered to downloaded tracks. Device-online queues skip non-downloaded tracks from unavailable servers.
- Direct file streams and universal transcode can both be valid. Do not disable either broadly without live endpoint proof and a scoped failing path.
- Timeline and scrobble reporting must remain source-exact; do not fall back across Plex source boundaries.
- Lyrics chord mode is queue-scoped UI state. Enabling chord mode applies to the current queue until the queue item identity sequence changes; queue rebuilds reset it to off. When enabled, tracks without chord streams fall back to normal lyrics while preserving the queue-scoped enabled state so later chord-capable tracks resume chord display automatically.

## Owners

- `PlaybackService` remains the playback facade and side-effect boundary for queue mutation and transport retry loops.
- `QueueManager` owns queue state and pure queue operations.
- `PlaybackQueueController` owns queue persistence, history normalization, autoplay flattening, and download-state restamping.
- `PlaybackTransportCoordinator`, `PlaybackRecoveryPolicy`, `PlaybackLocalFilePolicy`, `PlaybackPrefetchController`, and `PlaybackLaunchCoordinator` own focused playback seams.
- `PlaybackNowPlayingBridge` owns `MPNowPlayingInfoCenter` and remote command writes.
- `SystemMediaIntegrationService` owns donations, Spotlight indexing/deletion, and media user-context refresh.

## Implementation Hooks

- Keep MediaPlayer singleton writes out of playback engines, view models, and UI.
- Keep playback queue snapshots backward compatible when persistence changes.
- Use source-scoped identifiers for Now Playing external IDs, donations, Spotlight identifiers, artwork cache identity, and reporting.
- When changing streaming or playback transport, load `plex-api` and test the relevant PMS endpoint with curl using `.env` credentials.

## Verification

- Add or update queue tests for shuffle, repeat, autoplay, history, queue restoration, and download-state refresh changes.
- Add or update Now Playing tests when queue-scoped UI state such as Lyrics chord mode must persist across track advance and reset on queue rebuild.
- Add playback transport/recovery tests for local-file validation, offline fallback, endpoint selection, and retry classification changes.
- Use simulator validation for user-visible playback, Now Playing, remote command, or unavailable-track behavior.
