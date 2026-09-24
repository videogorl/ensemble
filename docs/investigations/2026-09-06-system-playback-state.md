# System playback state cleanup — 2026-09-06

## Delivered changes

- Native progress carries track identity, playback generation, and a timeline revision. Seek, resume, pause, and gapless/repeat re-anchoring invalidate older queued samples. The presentation timer now runs on main with normal transport callbacks, without polling the audio render lock. The former 750 ms stale-position heuristic is removed.
- The existing Now Playing bridge publishes the supplied transport state without remembering or forcing a separate playing state. Loading/buffering use rate zero. State changes schedule publication after the caller's mutations; explicit track/seek updates remain immediate. Reload publication follows the loading-state change.
- Artwork completion and cache reset obtain the current transport snapshot. Timeline revisions prevent a repeated track's zero-position snapshot from being discarded as an exact duplicate.
- Pause and toggle accept loading; Pause cancels pending skip work. A stale prebuffer-resume completion cannot resume after a newer Pause. Native pause/resume publication uses the engine's captured position. Play/Seek availability matches supported states, and nonfinite seek/progress values are rejected.
- Both engines use the same playable-successor/Repeat All decision; wrapping takes precedence over replacing an autoplay suffix with an Apple station. Native Repeat One keeps the current queue occurrence even when the same track appears elsewhere. MusicKit still owns Apple Repeat One; its loop cannot arm Ensemble's Previous inference. Apple rewind events re-anchor Now Playing and progress now uses the existing persistence checkpoint.
- Remote seek events timestamped before the current track are rejected at any track age, without a five-second or seek-distance heuristic. This cannot identify a stale accessory position delivered in a newly timestamped event.

These changes address completion/progress findings in the September 4 review. They do not replace either engine, change MusicKit's disposable finite queue, or claim to fix the separate native render/completion-clock findings.

## Verification

- 164 focused tests passed: PlaybackService, PlaybackNowPlayingBridge, PlaybackHandoffCoordinator, AudioPlaybackEngineStreaming, and AppleMusicPlaybackOperationCoordinator.
- Signed iOS Simulator workspace build passed, including the iOS-only MusicKit implementation. The workspace's EnsembleCore scheme has no test action; package tests ran on macOS.
- Native simulator checks on iOS 26.5, UUID `C0C6CF8B-7B59-4402-9D8D-CB4CFBF5D64D`: resume, advancing progress, pause, Next, Previous restart then previous item, seek, and Repeat One. UI and session logs agreed on track/reset state. Installed executable and debug dylib hashes were compared to the produced build before runtime evidence was accepted.
- Unsigned simulator startup initially trapped in CloudKit before playback; rebuilding with normal simulator signing restored launch. No CloudKit source changes were made.
- Control Center rendered an empty surface in this simulator. The physical iPhone 16 Pro was unavailable. Real Apple Music audio, Lock Screen commands/progress, locked mixed-provider transitions, Bluetooth, and AirPlay remain unverified. Passing policy tests and compiling MusicKit are not substitutes for those physical checks.

Local artifacts: `/tmp/ensemble-playback-tests.log`, `/tmp/ensemble-system-playback-build.log`, `/tmp/ensemble-system-playback-runtime.log`, `/tmp/ensemble-system-playback-repeat-runtime.log`.
