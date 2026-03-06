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

### BG Continued Processing Is Best-Effort (iOS 26+)
- `OfflineBackgroundExecutionCoordinator` submits `BGContinuedProcessingTaskRequest` for user-initiated bulk offline work.
- The OS may reject queued requests, cancel queued work if the app is removed from switcher, or expire active tasks.
- **Current behavior:** `OfflineDownloadService` treats BG execution as an accelerator only; persistent queue state remains source of truth and resumes in normal foreground/background opportunities.

### Offline Transcode Availability Varies by Plex Server
- Some Plex server configurations reject all `/music|audio/:/transcode/universal/*` download requests with HTTP `400` even when direct `/library/parts/...` access succeeds.
- **Current behavior:** `OfflineDownloadService` treats this as a server capability limitation, marks the server as `offline-transcode-unsupported`, and skips repeated transcode attempts by downloading original quality directly.
- **User impact:** Download quality settings (`high/medium/low`) may not be attainable for affected servers; downloaded files remain original quality.

### WebSocket Library Notifications Require Plex Pass
- `PlexWebSocketManager` maintains one `URLSessionWebSocketTask` per server with exponential backoff reconnect.
- **Plex Pass limitation:** Library change notifications (`timeline`, `activity`) are only delivered to server owner/admin accounts with Plex Pass. Non-Plex Pass shared users only receive session-level notifications (e.g., `playing`). The WebSocket still provides implicit health signals for all account types.
- Some Plex server configurations (especially behind strict NATs or reverse proxies) may not support WebSocket connections at all.
- **Current behavior:** `PlexWebSocketCoordinator` treats WS events as acceleration hints; polling-based sync timers remain active as fallback for all account types. If a WebSocket connection fails repeatedly, the backoff cap prevents excessive reconnect attempts.

### Artwork Pre-Caching Not Automatic
- `ArtworkLoader.predownloadArtwork()` methods exist
- Not currently called during library sync
- Would improve offline experience if wired up to `SyncCoordinator`

### Library Visibility Profile Selector UI Not Shipped Yet
- `LibraryVisibilityProfile` + `LibraryVisibilityStore` groundwork exists in `EnsembleCore`
- `LibraryViewModel`, `SearchViewModel`, and `HomeViewModel` already support source-key visibility filtering seams
- **Missing:** user-facing selector/editor UI to switch and manage profiles in Settings
- **Current behavior:** filtering is foundation-only; sync-enable state remains unchanged

## Resolved

### HomePod Siri Media Intents handle() Never Called
- **Resolved (February 26, 2026)**
- **Issue:** For HomePod requests, iOS's SiriKit never calls `handle()` after `confirm()` returns `.ready`. This appears to be an iOS limitation affecting third-party media apps.
- **Workaround:** Extension writes playback payload to App Group and posts a Darwin notification; app listens for the notification and executes playback directly, bypassing the broken `handle()` flow.
- **Key files:** `PlayMediaIntentHandler.swift` (confirm + Darwin post), `AppDelegate.swift` (Darwin listener)

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

### Plex Endpoint Policy + Auth Lifecycle Parity
- **Resolved (February 22, 2026)**
- Discovery requests now include IPv6 resource candidates and common Plex headers.
- Endpoint selection now follows local-first, relay-last policy with settings-driven insecure fallback rules.
- Failover now triggers only for transport/connectivity failures, avoiding probe storms on HTTP semantic errors.
- Server health now reports classified failure reasons instead of generic offline.
- Auth cutover now enforces token metadata lifecycle and forced re-login migration.

### Residual Risk: Forced Re-Login After Auth/Account Migrations
- **Status:** Expected behavior
- **Impact:** Existing beta users are signed out once when migration version bumps (auth lifecycle and account-schema cutovers).
- **Mitigation:** Add release-note callout for one-time sign-in requirement.

## Performance Notes

### Incremental Sync ratedAfter Fetch Returns All Rated Tracks
- **Location:** `PlexMusicSourceSyncProvider.syncLibraryIncremental()`
- **Issue:** The `lastRatedAt>=` API filter matches all tracks that have *ever* been rated (not just recently rated), effectively doubling the track fetch for incremental sync.
- **Impact:** Extra API traffic (~1400 tracks fetched redundantly). Correctness is unaffected — rating comparison still works.
- **Potential fix:** Only fetch `ratedAfter` when the since-timestamp is very recent, or compare ratings against the `updatedAt` result set only.

## Future Enhancements (Waveform System)

- Cache waveform data locally to reduce repeated API calls
- Implement waveform seeking (jump to specific parts of track)
- Show visual indicators for silent portions or hidden tracks
- Extract colors from waveform for additional UI theming
