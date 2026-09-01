# Downloads Policy

- `OfflineDownloadService` is the target and persistent queue source of truth.
  App lifecycle and URLSession events enter through its coordinators rather than
  creating alternate workers.
- Downloads are source-scoped targets whose memberships may overlap. New work is
  admitted only when the provider capability and target scope allow it.
  Capability loss never disables removal of existing local data.
- Download rows, files, membership, and cleanup use exact source identity. Never
  collide libraries/accounts by rating key or display name.
- A merged download command enables every missing eligible source target. Only
  when every eligible target is enabled does the command remove them all.
- Removing a track's final target reference deletes its audio and derived
  artifacts. Preserve shared artifacts while another target references them,
  and delete only after explicit target removal or a complete authoritative
  source/playlist inventory proves the item absent.
- Failed, partial, malformed, or premature-empty inventories preserve download
  targets, rows, and files.
- Wi-Fi/wired is the default transfer policy. The shared cellular setting is
  reflected consistently wherever exposed. Device offline, Low Data Mode, Low
  Power Mode, user pause, and lifecycle constraints pause eligible work without
  losing resumability.
- A confirmed one-hour cellular/Low Data exception is temporary, never changes
  the saved setting, and cannot override device offline.
- OS background execution accelerates the persistent queue but is not its source
  of truth. Rejection, cancellation, expiration, or relaunch must leave work
  recoverable exactly once with its requested quality unchanged.
- Audio completion is the durable boundary. Artwork, frequency analysis, lyrics,
  and chords are derived, idempotent, best-effort artifacts repaired later from
  completed downloads rather than promoted into another durable job system.
- Offline audio and regenerable artwork remain nonpurgeable while installed but
  are excluded from device backups. Missing restored audio becomes retryable.
- Startup publishes target/queue state after lightweight repair. Expensive file
  healing, truncation scans, cleanup, and full progress computation are deferred
  and coalesced so downloads and playback stay responsive on constrained devices.
- Requested quality is preserved across retry and recovery. Refresh a completed
  file only when its stored quality differs. A server that cannot perform
  offline transcode may fall back to original quality without repeated failing
  transcode attempts.
- A completed playback artifact may satisfy a requested download only when its
  source revision and requested quality match exactly; Original requires a
  direct artifact. `OfflineDownloadService` validates and atomically copies the
  file into durable download storage before recording completion. Playback
  cache eviction never owns or removes the installed download.
- Lyric/chord unavailability is cached only for confirmed signature-scoped
  no-stream/404 outcomes and invalidated when the signature changes or the user
  retries. Transport, cancellation, parse, and server failures remain retryable.
- Bulk progress and completion publication is coalesced. Do not instantiate
  workers without pending work or emit per-item storms that compete with audio.
