# Repo Audit Baseline

Date: 2026-04-14

## Baseline Checks

- `swift test --package-path Packages/EnsembleAPI`: passed
- `swift test --package-path Packages/EnsembleCore`: passed
- `xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`: passed
- Simulator cold launch on `iPhone 17 Pro`: succeeded, landed on the authenticated Albums flow with a live mini-player
- Runtime interaction pass on `iPhone 17 Pro`: succeeded
  - Opened album detail for `After Laughter`
  - Started playback from the album
  - Opened Now Playing
  - Paused playback
  - Skipped to `Rose-Colored Boy`
  - Dismissed back to the album detail screen

## Verification Artifacts

- Startup OS log: `/tmp/ensemble-runtime-baseline/os-log.txt`
- Startup persistent session log: `/tmp/ensemble-runtime-baseline/persistent-session.log`
- Startup screenshot: `/tmp/ensemble-runtime-baseline/launch-screen.png`
- Interaction persistent session log: `/tmp/ensemble-runtime-baseline/interaction-persistent-session.log`

## Ranked Findings

### 1. Swift 6 concurrency hardening is still required in playback-facing code

- `PlaybackService` exposed a protocol/conformance isolation warning and an async dependency closure that captured `self` in concurrently executing code.
- `NowPlayingViewModel` used a detached blur-generation task that hopped back through a captured `self` inside `MainActor.run`.
- `ServerHealthChecker` carried redundant `MainActor.run` writes from inside an already-main-actor type.

This pass fixes the currently reported warning sites in the shipping iOS path, but the larger playback stack still needs incremental Swift 6 hardening as future compiler diagnostics surface.

### 2. Runtime baseline capture tooling was incomplete

- `scripts/capture_runtime_baseline.sh` previously only summarized an existing trace or log file.
- The baseline workflow needed a repeatable cold-launch capture path that could collect both the simulator OS log stream and the app's `PersistentLogService` session log.

This pass extends the script with a `--capture-startup` mode for repeatable simulator baselines.

### 3. Logging policy and implementation were out of sync

- Repo guidance says structured logger calls must not be compiled out in release/TestFlight builds.
- Package/app `debug` helpers still wrapped `logger.debug` calls in `#if DEBUG`, which reduced release-time observability.

This pass aligns the shared logger helpers with the documented policy so debug-level traces continue to reach OSLog and the persistent session sink in release builds.

### 4. Agent docs had drifted behind the active service graph

- `.claude/skills/project-structure/SKILL.md` and `.claude/skills/architecture/SKILL.md` were missing several active services and helpers, including mutation, Siri, local-network, and audio-engine components.
- Simulator guidance did not point agents at the repo's runtime-baseline capture script.

This pass refreshes the relevant skill docs so future sessions start from the current iOS architecture.

### 5. Oversized orchestration files remain the main architectural hotspot

Current line counts from the baseline:

- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift`: 5695
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift`: 3055
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift`: 2735
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift`: 2493
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift`: 1585

No decomposition was attempted in this pass. These remain the next architectural phases once warning cleanup and baseline tooling are stable.

### 6. Residual warnings are now narrow and mostly non-blocking

- `xcodebuild` still emits `warning: Metadata extraction skipped. No AppIntents.framework dependency found.` during the App Intents metadata processor step.
- `swift test --package-path Packages/EnsembleCore` still prints pre-existing Core Data test warnings about duplicate `NSEntityDescriptions` for generated subclasses in isolated test models.

Neither warning blocked the app build, simulator validation, or package tests in this pass.

## Implemented In This Pass

- Narrowed `PlaybackServiceProtocol` isolation to the `updateVisualizerPosition(_:)` requirement and removed the current `self` capture warning path in `PlaybackService`.
- Reworked blurred-artwork completion in `NowPlayingViewModel` to apply results through a main-actor helper instead of a captured `self` inside `MainActor.run`.
- Removed redundant `MainActor.run` writes from `ServerHealthChecker`.
- Cleaned the unused weak capture in `MediaTrackList`.
- Marked `OfflineDownloadService.downloadsDidChange` as `nonisolated` so non-main-actor observers can reference it safely.
- Removed dead reconnect/disconnect branches in `PlaybackService` that still assumed a non-local playback path.
- Updated shared logger helpers to keep debug logging active in release/TestFlight builds.
- Extended `scripts/capture_runtime_baseline.sh` to capture a cold-launch runtime baseline from Simulator.
- Updated architecture/project-structure/simulator skill docs to reflect the current workflow and service inventory.

## Remaining Work

- Re-run the full app build after each future phase and keep tracking new Swift 6 diagnostics as they surface.
- Decompose the large orchestration files one responsibility at a time, starting with `PlaybackService`.
- Expand baseline runtime verification beyond cold launch and playback smoke tests when touching sync, offline downloads, or Siri flows.
- Decide whether the App Intents metadata extraction warning reflects an intentional configuration gap or a missing dependency declaration.
- Investigate the duplicated Core Data entity warnings in package tests so future audits can distinguish real model problems from harness noise.
