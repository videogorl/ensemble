---
name: known-issues
description: "Active Ensemble limitations, watchlist items, and fragile areas. Use when investigating bugs, planning work, or touching known-risk behavior."
---

# Ensemble Known Issues

This skill is for active limitations and watchlist items only. Resolved history was archived to `docs/investigations/2026-05-13-known-issues-archive.md`.

## Critical

No unresolved critical issues are currently documented.

## Active Limitations

### Top-Level Navigation Pop-In During Playback

- **Area:** `SidebarView`, `HomeView`, `LibraryViewModel`, `AlbumsView`, `ArtistsView`, `SearchView`, `FavoritesView`
- **Status:** macOS sidebar navigation can show an intermediate empty/chrome-only state and may coincide with CoreAudio overload while music plays. Current evidence points to top-level subtree replacement plus delayed display projections/view-local caches, not Aurora cadence.
- **Rule:** Keep Aurora at 30fps unless Low Power Mode is active. Fix the pop-in by preserving or root-owning display-ready state, removing unused view-local models, and seeding display projections synchronously instead of pausing/reducing the root backdrop during navigation.

### macOS 26 Feed Toolbar Liquid Glass Sampling

- **Area:** `HomeView`, `CollapsingToolbar`, `ArtworkDetailBackground`
- **Status:** The Feed toolbar no longer uses an opaque custom background, but native Liquid Glass scroll-edge color bleed can still be less vivid until navigation invalidates the detail hierarchy.
- **Rule:** Keep the extension-backed `ArtworkDetailBackground` mounted from first render, keep macOS 26 toolbar background hidden, and avoid custom scroll padding/window-wide backgrounds. Look for root `NavigationSplitView`/detail-column ownership fixes instead of leaf toolbar shims.

### watchOS Standalone V1 Scope

- **Area:** `EnsembleDomain`, `EnsemblePlex`, `EnsembleWatchCore`, `EnsembleWatch/Views/WatchRootView.swift`
- **Status:** Watch has standalone Plex Link/iCloud credential bootstrap, selected-library browsing, watch-local playback, and phone remote Now Playing, but remains a compact V1 implementation.
- **Limitations:** Downloads are not included.
- **Build note:** Build/run Watch directly with `EnsembleWatch` for simulator testing. The iOS `Ensemble` target embeds the independent Watch app for device archives and TestFlight distribution.

### iOS 26 Keyboard Presenter Guardrails

- **Area:** Text input sheets, `MainTabView`, browse screens, metadata editors, filter screens.
- **Status:** Broad full-screen keyboard-safe presenters caused regressions. Ordinary short rename/create/filter flows should use native alerts or sheets.
- **Rule:** Parent screens may suppress only their own active navigation/search chrome while presenting a local modal if logs prove that parent chrome is the loop source. Do not reintroduce broad keyboard presenters, sheet-local navigation stacks for short editors, app-wide keyboard monitors, or StageFlow rotation ownership in child screens without a current repro.

### iOS 26 Simulator Keyboard Haptics Log Noise

- **Area:** Simulator runtime while software keyboard appears.
- **Status:** Repeated CoreHaptics errors from UIKit keyboard haptics are simulator noise, not Ensemble haptics.
- **Rule:** Ignore this in simulator logs unless accompanied by an app-owned haptics regression.

### iOS 26.5 Simulator Automation Gaps

- **Area:** `ios-simulator-mcp`/Homebrew `idb-companion`, XcodeBuildMCP list reordering and custom drag controls.
- **Status:** Homebrew `idb-companion` 1.1.8 does not start automatically for ios-simulator-mcp, but an explicit companion on port `10882` supports screenshots, coordinate taps, and real native `List.onMove` drags on the iOS 26.5 simulator. XcodeBuildMCP can capture and tap the runtime semantic tree, but its drag transport currently fails with `FBSimulatorHIDEvent does not support touch move events`. Its semantic tap can land on a combined row label instead of a trailing add/remove control, and its generic target list omits custom adjustable controls; a label-specific query finds the Now Playing scrubber as a slider but serializes its numeric value as `nan` even when the displayed clock and seek behavior are correct. During iPad viewport Now Playing, Xcode snapshots can also retain covered root descendants even when `accessibilityHidden` and hit testing are active; Computer Use exposes only the modal controls and covered Xcode actions have no effect.
- **Rule:** When ios-simulator-mcp reports connection failure on `localhost:10882`, start `idb_companion --udid <simulator-udid> --grpc-port 10882 --log-level info` and keep that process alive for the interaction run. Use Xcode runtime snapshots for semantic discovery, then ios-simulator-mcp screenshots and coordinates for trailing controls or native reorder handles. For labels beginning with `-`, refresh the snapshot and use Xcode `touch` on the element reference. Query custom adjustable controls by label and verify their behavior from visible state changes rather than trusting the serialized numeric value. For viewport Now Playing modal-focus checks, use Computer Use's Simulator accessibility tree and confirm a covered Xcode action has no visible effect.

### Device Hub Suppresses Apple Music Audio

- **Area:** Physical-device MusicKit playback verification in Device Hub 27.
- **Status:** Device Hub mirrors Ensemble and Apple's Music app UI, but protected Apple Music audio is silent and the system waveform remains inactive while mirroring. Plex audio still passes through, and Apple Music resumes audibly after disconnecting Device Hub. iPhone Mirroring carries the Apple Music audio channel correctly.
- **Rule:** Do not use Device Hub to judge Apple Music audibility. Use the physical iPhone or iPhone Mirroring for MusicKit playback and Plex/Apple provider-boundary verification; Device Hub remains valid for visual-only checks.

### macOS Instrumental Mode Quality Gap

- **Area:** `AudioPlaybackEngine` instrumental/vocal attenuation path.
- **Status:** macOS `AUSoundIsolation` isolates vocals only; direct instrumental output is not equivalent to iOS.
- **Current approach:** Use high-quality voice model plus complement (`wetDryMix=-100`) and dereverb. Expect occasional vocal bleed during loud sections.
- **Rule:** Revisit only if Apple ships direct instrumental output on macOS or new model files change behavior.

### Lyrics Stream 404s

- **Area:** `LyricsService`, `PlexAPIClient.getLyricsContent(streamKey:)`
- **Status:** Some tracks report a lyrics stream in metadata but `/library/streams/{streamKey}` returns 404.
- **Rule:** Treat persistent 404s as server-side absence. Keep retry/negative-cache behavior defensive and user-facing state non-crashing.

### Background Downloads Are Best-Effort

- **Area:** `OfflineBackgroundExecutionCoordinator`, `OfflineDownloadService`
- **Status:** iOS 26 continued-processing requests can be rejected, cancelled, or expired by the OS.
- **Rule:** Treat background execution as an accelerator. Persistent queue state remains source of truth and must resume under normal foreground/background opportunities.

### Offline Transcode Availability Varies By Server

- **Area:** Offline downloads and Plex universal transcode endpoints.
- **Status:** Some PMS configurations reject offline transcode even when direct original downloads work.
- **Rule:** Mark unsupported servers and avoid repeated failing transcode attempts. Original-quality fallback is valid for those servers.

### Plex WebSocket Limitations

- **Area:** `PlexWebSocketManager`, `PlexWebSocketCoordinator`
- **Status:** Library notifications require owner/admin Plex Pass, some server/network setups reject WebSocket, and some close immediately with code `1001`.
- **Rule:** WebSocket events are acceleration hints. Polling timers and circuit breakers must remain as fallback.

### Artwork Pre-Caching Is Sync-Path Only

- **Area:** `ArtworkLoader.predownloadArtwork`
- **Status:** Artwork is pre-cached only for items that pass through sync. Browsing an uncached item may still require network.

### Library Visibility Selector Not Shipped

- **Area:** `LibraryVisibilityProfile`, `LibraryVisibilityStore`
- **Status:** Core filtering seams exist, but user-facing selector/editor UI is not shipped.
- **Rule:** Visibility profiles hide/show browse content only; they do not change sync enablement.

## Watchlist

### AirPlay Glitch During Health Probes

- **Area:** `ServerHealthChecker`, AirPlay playback.
- **Status:** One observed mid-track AirPlay glitch correlated with foreground health probes.
- **Mitigation if reproducible:** Limit concurrent health probes while AirPlay is active or defer health checks during active AirPlay playback.

### Wall-Clock Boundary Timer Over High-Latency Routes

- **Area:** `PlaybackService` wall-clock boundary fallback.
- **Status:** Timer may fire early for the last track over high-latency outputs. Gapless transitions are protected.
- **Mitigation if reproducible:** Increase grace period or route-aware suppression.

### First-Play Visualizer Delay

- **Area:** `AudioAnalyzer`, sidecar frequency analysis.
- **Status:** Tracks without cached `.freq` sidecars may show no visualizer data until analysis completes. Playback is unaffected.

## When To Update This Skill

Add entries only for active bugs, limitations, fragile platform behavior, or watchlist items. Resolved incident writeups belong in `docs/investigations/`.
