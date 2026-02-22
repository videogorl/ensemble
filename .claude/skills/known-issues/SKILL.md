---
name: known-issues
description: "Ensemble known issues and technical debt: critical bugs, feature gaps, infrastructure debt. Use when investigating bugs, planning work, or understanding limitations."
---

# Ensemble Known Issues & Technical Debt

## Critical

### watchOS Authentication Missing
- **Location:** `EnsembleWatch/Views/WatchRootView.swift:5`
- **Issue:** References `DependencyContainer.shared.makeAuthViewModel()` which does not exist
- **Impact:** watchOS app won't compile
- **Status (February 21, 2026):** Deferred by scope decision; not being fixed in current remediation pass
- **Root Cause:** iOS uses `AddPlexAccountViewModel`, watchOS was designed with different auth flow
- **Fix Options:**
  1. Create `AuthViewModel` in EnsembleCore and add factory method to DependencyContainer
  2. Refactor watchOS to use existing `AddPlexAccountViewModel`
  3. Create watchOS-specific auth flow that matches iOS patterns

## Feature Completeness Gaps

### Offline Playback Infrastructure Exists But Not Wired Up
- `DownloadManager` handles track file downloads
- `DownloadsView` shows download queue
- **Missing:** Wire up audio file downloads to `PlaybackService` for true offline playback

### Artwork Pre-Caching Not Automatic
- `ArtworkLoader.predownloadArtwork()` methods exist
- Not currently called during library sync
- Would improve offline experience if wired up to `SyncCoordinator`

## Resolved

### Infrastructure
- **Legacy CocoaPods Cleanup** -- Removed unused `ios/Pods/` directory

### Documentation
- **Documentation Fully Updated** -- CLAUDE.md and README.md reflect all implemented features

### Persistence SwiftPM Test Crash
- **Resolved (February 21, 2026)**
- `CoreDataStack` now loads bundled models with resilient `.momd`/`.mom` fallback candidates.
- `CoreDataStack.inMemory()` now uses a true in-memory store (`/dev/null`).
- Persistence tests use in-memory stack instead of `.shared`.
- SwiftPM model compilation workflow is documented and scripted (`scripts/compile_coredata_model.sh`).

### Network Handoff Endpoint Staleness + Health Check Overactivity
- **Resolved (February 21, 2026)**
- `PlaybackService` now heals upcoming queue items on reconnect/interface-switch transitions.
- `NetworkMonitor` lifecycle is restart-safe across background/foreground transitions.
- `SyncCoordinator` coalesces network-health refreshes and applies cooldown/staleness guards.
- `HomeViewModel` defers hub refresh/apply while users are scrolling to prevent feed jumps.

## Future Enhancements (Waveform System)

- Cache waveform data locally to reduce repeated API calls
- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming
