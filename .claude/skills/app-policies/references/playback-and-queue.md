# Playback And Queue Policy

Load this reference for playback start behavior, queue state, shuffle/repeat/autoplay, offline queue filtering, local-file playback, transport recovery, prefetch, reporting, or system-media donation behavior.

## Policies

- `QueueManager` is the source of truth for queue order, sections, history, shuffle, repeat, and autoplay state.
- Regular play disables shuffle and starts from the requested index. Shuffle play enables shuffle, preserves original order for restore, and starts from the shuffled queue.
- Toggling shuffle keeps the current item, excludes autoplay items from the shuffle candidates, filters already played history from candidates, and restores original order when disabled.
- Queue navigation records history before advancing, restarts the current track when Previous is invoked after the configured restart threshold, and wraps only when repeat-all is enabled.
- Autoplay is a separate queue section. It should not be treated as manually queued content or shuffled into the main future queue.
- SmartMix is a per-device playback preference controlled from the Now Playing Queue card. It defaults off, persists in local `UserDefaults`, and does not sync across devices.
- SmartMix uses bounded local/temp file silence and tempo analysis, equal-power overlapping deck fades, an eased outgoing high-pass sweep, and confidence-gated tempo matching. Very high-confidence matches let the outgoing deck ease toward the incoming track's tempo during the overlap; moderate-confidence close matches may still use incoming-only time stretching. SmartMix automatically falls back to non-stretched overlap when confidence, rate range, or device state is not suitable.
- SmartMix uses a true two-deck playback model: when a transition finishes, the incoming deck remains the live deck until the next transition, and the next SmartMix schedules onto the opposite deck. Do not force an immediate handoff back to a single primary deck at the transition boundary.
- SmartMix transitions keep track A current until transition midpoint, then promote track B for Now Playing presentation, artwork, queue index, system media identifiers, timeline reporting, and history. A skip before the SmartMix threshold keeps B playing; a skip at or after the threshold advances past B.
- SmartMix must gracefully fall back to existing gapless playback when analysis, file resolution, queue shape, route recovery, or second-deck scheduling is unavailable.
- SmartMix remains available on constrained devices. Analysis results are cached by track identity plus file metadata and analysis work routes through foreground budgeting so tempo/silence analysis does not run concurrently with startup sync, share sheets, Now Playing gestures, or audio-critical sections on A9/iOS 15-class devices.
- Playback route recovery must preserve the user-visible playhead. Audio-engine scheduling anchors, such as deck segment offsets used for SmartMix or gapless playback, must not become resume positions when render timing is unavailable.
- System Now Playing artwork should not flash to generated fallback artwork during track transitions. When the incoming track has an artwork path, keep the previous system artwork until the new artwork loads, then replace it; only use generated fallback artwork when no artwork path exists or the artwork load fails.
- Playback start paths must pass `PlaybackStartContext`. Only direct app UI starts donate to system media; Siri, App Shortcuts, remote commands, autoplay, restoration, and background recovery are non-donating.
- macOS Dock menu playback controls are user commands for the existing queue/playback state. They must dispatch through `PlaybackService`/active Now Playing owners and must not add system-media donations or mutate `MPRemoteCommandCenter` directly.
- Playback should prefer valid local files/downloads when present. Corrupt or invalid local files fail locally while online paths may recover by streaming or refreshing.
- Device-offline queues are filtered to downloaded tracks. Device-online queues skip non-downloaded tracks from unavailable servers.
- Direct file streams and universal transcode can both be valid. Do not disable either broadly without live endpoint proof and a scoped failing path.
- Timeline and scrobble reporting must remain source-exact; do not fall back across Plex source boundaries.
- Lyrics loading should try all regular, non-chord lyric streams exposed by current track metadata in priority order, preferring timed streams while keeping plain/local sidecars as fallbacks. Local regular sidecars should use the raw lyrics fetch path so plain text and LRC content are preserved.
- Lyrics chord mode is queue-scoped UI state. Enabling chord mode applies to the current queue until the queue item identity sequence changes; queue rebuilds reset it to off. When enabled, tracks without chord streams fall back to normal lyrics while preserving the queue-scoped enabled state so later chord-capable tracks resume chord display automatically.

## Owners

- `PlaybackService` remains the playback facade and side-effect boundary for queue mutation and transport retry loops.
- `QueueManager` owns queue state and pure queue operations.
- `PlaybackQueueController` owns queue persistence, history normalization, autoplay flattening, and download-state restamping.
- `PlaybackTransportCoordinator`, `PlaybackRecoveryPolicy`, `PlaybackLocalFilePolicy`, `PlaybackPrefetchController`, `PlaybackLaunchCoordinator`, `SmartMixAnalysisService`, and `SmartMixPlanner` own focused playback seams.
- `ForegroundWorkScheduler` owns playback-safe budgeting for optional analysis work; it must not block user-initiated playback commands or download transfers.
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
