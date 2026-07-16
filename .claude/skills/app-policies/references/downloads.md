# Downloads Policy

Load this reference for offline download targets, download queue behavior, transfer retry/fallback, background execution, quality refresh, progress publication, or download UI status.

## Policies

- `OfflineDownloadService` is the target and queue source of truth. Platform lifecycle events route through offline coordinators and then into the service.
- Downloads are target-based. Library, album, artist, playlist, and favorites targets resolve memberships, enqueue missing tracks, and clean up shared tracks by reference count.
- Removing the final target reference for a track must evict its audio file, frequency sidecar, and offline lyrics/chord caches. Preserve those artifacts while another target still references the same source-scoped track. Target removal and reconciliation must resolve memberships, delete download records/files, and clear lyrics in bounded background batches, with UI progress updates coalesced rather than emitted once per track.
- Download lookup, persistence, and deletion must be source-aware: use `ratingKey + sourceCompositeKey` so libraries and servers do not collide.
- Queue policy is Wi-Fi/wired only by default. Active downloads pause on cellular or offline network state unless settings explicitly allow the path.
- Low Data Mode pauses downloads on constrained network paths without treating the device as offline; pending work resumes when the path is no longer constrained.
- User pause, Low Power Mode, app backgrounding, and iOS continued-processing windows all feed the same scheduler. The queue should pause aggressively on constrained devices without losing resumability.
- A user-paused queue keeps its Resume control visible until the user resumes it, including when only library targets have pending work or other target summaries report failures.
- Background execution is an accelerator, not the source of truth. Persistent queue state must resume under normal foreground/background opportunities when OS background execution is rejected, cancelled, or expired. Queue completion and expiration must cancel stale unlaunched continued-processing requests; granted tasks complete successfully even when individual tracks fail because failures remain represented in the persistent queue.
- Launch recovery is lightweight: repair stale `.downloading` records and publish target shells first, then defer file healing, truncation scans, cleanup, and full progress recomputation.
- Deferred launch/foreground healing, truncation scans, cleanup, sidecar analysis, and expensive full-progress recomputation route through `ForegroundWorkScheduler` while the app is foreground active. Downloads themselves may continue when network/settings allow; the scheduler throttles reconciliation and analysis work, not user-requested transfer execution.
- Foreground recovery immediately after launch should coalesce with launch recovery instead of repeating the same startup sweep.
- Some Plex servers reject offline transcode even when original downloads work. Mark unsupported servers, avoid repeated failing transcode attempts, and allow original-quality fallback for those servers.
- Quality refresh requeues completed downloads only when stored quality differs from the current download quality and the server supports the requested mode.
- Full target progress recomputation is coalesced during playback/background load. Per-track completion may refresh owning targets for UI accuracy without rebuilding every target on each queue event.
- Offline lyric sidecar work includes chord streams. Chord caches are stream-specific and separate from normal lyrics, persist raw sidecar content for offline playback, and revalidate against Plex stream metadata when online. When online, chord streams should try to fetch fresh raw sidecar content before using memory or disk cache; disk cache is a fallback for raw fetch failures and offline playback. Treat online local chord caches as soft with a 24-hour expiry.

## Owners

- `OfflineDownloadService` owns targets, queue facade state, progress publication, recovery entry points, and download source of truth.
- `DownloadQueueCoordinator` owns queue task lifecycle, worker fan-out, background wake handling, and wind-down/restart decisions.
- `DownloadRetryPolicy` owns transfer retry accounting and direct-original fallback gating.
- `DownloadTransferExecutor` owns download-queue vs direct-original transfer execution, validation, completion recovery, and post-processing.
- `DownloadTargetReconciler`, `OfflineDownloadCleanupCoordinator`, and `OfflineDownloadTargetProgressController` own membership reconciliation, orphan cleanup, and progress refresh.
- `OfflineBackgroundExecutionCoordinator` owns OS background execution windows and URLSession completion-handler handoff.

## Implementation Hooks

- Route user-facing target toggles, removals, remove-all, pause, and resume through `DownloadMutationWorkflow` when views or view models initiate them.
- Use debounced `downloadsDidChange` fan-out through `OfflineDownloadNotificationBridge`; avoid per-track publish storms during bulk downloads.
- Keep FFT, artwork, and lyrics sidecar work background priority and serialized where needed so downloads do not starve playback or low-RAM devices. On A9/iOS 15-class devices, sidecar/analysis work should pause during startup sync, share sheets, Now Playing interaction, and audio-critical sections.
- Include chord stream pre-cache in the same best-effort sidecar path as lyrics downloads; retry or cache-clearing actions for a track/source should evict both normal lyric and chord caches.
- Do not instantiate download workers when there are no pending downloads.

## Verification

- Run focused `EnsembleCore` download tests after policy changes: queue coordinator, retry policy, service policy, transfer executor, target reconciler, cleanup, progress controller, and view model tests as applicable.
- Use simulator or device evidence for user-visible Downloads queue behavior, especially pause/resume, network transitions, quality refresh, or background recovery.
- Use performance gates when changing Downloads queue behavior or high-frequency progress publication.
