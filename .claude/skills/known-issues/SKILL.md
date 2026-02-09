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

## Future Enhancements (Waveform System)

- Cache waveform data locally to reduce repeated API calls
- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming
