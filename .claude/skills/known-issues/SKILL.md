---
name: known-issues
description: "Active Ensemble limitations, watchlist items, and fragile areas. Use when investigating bugs, planning work, or touching known-risk behavior."
---

# Ensemble Known Issues

This skill is for active limitations and watchlist items only. Resolved history was archived to `docs/investigations/2026-05-13-known-issues-archive.md`.

## Critical

No unresolved critical issues are currently documented.

## Active Limitations

### macOS 26 Feed Toolbar Liquid Glass Sampling

- **Area:** `HomeView`, `CollapsingToolbar`, `ArtworkDetailBackground`
- **Status:** The Feed toolbar no longer uses an opaque custom background, but native Liquid Glass scroll-edge color bleed can still be less vivid until navigation invalidates the detail hierarchy.
- **Rule:** Keep the extension-backed `ArtworkDetailBackground` mounted from first render, keep macOS 26 toolbar background hidden, and avoid custom scroll padding/window-wide backgrounds. Look for root `NavigationSplitView`/detail-column ownership fixes instead of leaf toolbar shims.

### watchOS Standalone V1 Scope

- **Area:** `EnsembleDomain`, `EnsemblePlex`, `EnsembleWatchCore`, `EnsembleWatch/Views/WatchRootView.swift`
- **Status:** Watch has standalone Plex Link/iCloud credential bootstrap, selected-library browsing, watch-local playback, and phone remote Now Playing, but remains a compact V1 implementation.
- **Limitations:** Downloads are not included. KVS pins/library flags require watchOS 9+; watchOS 8 degrades to local cached/default behavior.
- **Build note:** The iOS `Ensemble` scheme no longer embeds the watch app during simulator builds. Build/run watch with `EnsembleWatch`.

### iOS 26 Keyboard Presenter Guardrails

- **Area:** Text input sheets, `MainTabView`, browse screens, metadata editors, filter screens.
- **Status:** Broad full-screen keyboard-safe presenters caused regressions. Ordinary short rename/create/filter flows should use native alerts or sheets.
- **Rule:** Parent screens may suppress only their own active navigation/search chrome while presenting a local modal if logs prove that parent chrome is the loop source. Do not reintroduce broad keyboard presenters, sheet-local navigation stacks for short editors, app-wide keyboard monitors, or StageFlow rotation ownership in child screens without a current repro.

### iOS 26 Simulator Keyboard Haptics Log Noise

- **Area:** Simulator runtime while software keyboard appears.
- **Status:** Repeated CoreHaptics errors from UIKit keyboard haptics are simulator noise, not Ensemble haptics.
- **Rule:** Ignore this in simulator logs unless accompanied by an app-owned haptics regression.

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

### Classic iPod Sync Requires External Helper

- **Area:** `ExternalDeviceSyncService`, `IPodDatabaseAdapting`, `Packages/EnsembleUI/Sources/Screens/Devices/`
- **Status:** Ensemble has mapped-only sync planning, persistence, and macOS UI scaffolding, but the App Store app exposes devices only when a separately distributed iPod helper is detected. Actual iPod database reads/writes remain blocked until that helper protocol is implemented.
- **Rule:** Keep sync behavior additive, Plex-authoritative, and silent when the helper is missing. Do not add helper-install copy to the App Store app, import unmapped iPod data, fuzzy-match orphan files, or bypass PMS transcoding while filling in the helper/export implementation.

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
