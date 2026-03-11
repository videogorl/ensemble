# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Skills (MUST load before starting work)

Detailed reference material lives in `.claude/skills/`. **Always load the relevant skill(s) before beginning any non-trivial task** — these files contain project-specific rules that override general Swift/SwiftUI defaults.

| Skill | Load when… |
|-------|-----------|
| `architecture` | Designing a feature, adding a service, understanding data flow, anything touching multiple packages |
| `ui-conventions` | Building or modifying any SwiftUI view, navigation, loading states, iOS 15 compat |
| `project-structure` | Locating a file, deciding where a new file belongs, understanding what exists |
| `code-style` | Writing any Swift code — contains mandatory rules (e.g. `#if DEBUG` for all prints, edge case handling) |
| `known-issues` | Investigating a bug, planning work, or before touching any area with known problems |
| `common-tasks` | Adding a ViewModel, view, CoreData entity, hub, music source, playlist mutation, or sync trigger |
| `testing` | Writing tests, implementing a major feature, or verifying nothing is broken after a refactor |
| `plex-api` | Implementing or debugging Plex API calls — library sync, playback tracking, playlists, hubs, search, transcoding |

**When in doubt, load all of them.** They are small and the cost of reading them is far lower than making a wrong decision.


## Workflow (MUST follow for every task)

**Commit discipline:**
- Git commit after each logical "step" when implementing a plan
- Always commit before waiting for the user to test (so changes can be rolled back if context is lost or something breaks)

**Testing discipline:**
- After implementing a non-trivial feature or refactor, run `swift test --package-path Packages/<affected-package>` before committing
- If tests fail, fix them before committing — never commit a broken test suite
- For major architectural changes, write tests for new services/repositories first (see `testing` skill)


## Troubleshooting

When a problem is mentioned, **interview the user first** to help hone in on where the problem is originating from -- don't jump straight to code changes. Ask clarifying questions about when it happens, what they see, and what they expect.

When investigating, add logs to the appropriate files so debugging can be more efficient. Remove or reduce log verbosity once the issue is resolved.

### Plex Streaming Issues — MUST READ

**ALWAYS test Plex endpoints with curl BEFORE making code changes.** A `.env` file at the project root contains `PLEX_ACCESS_TOKEN` for testing. Load the `plex-api` skill for endpoint details and testing patterns.

**DO NOT "disable universal endpoint" as a fix for playback failures.** Curl testing has confirmed:
- **Universal transcode endpoint WORKS** (200, valid audio/mpeg)
- **Direct file stream returns 503** — falling back to direct stream makes things WORSE
- The "resource unavailable" error is an **AVPlayer-specific issue**, not a server problem
- See the `plex-api` skill for the full diagnosis and testing patterns


## Using the Gemini CLI

You have access to the Gemini CLI (`gemini -p`) which leverages Google Gemini's massive context window. Use it as a complementary tool in the following situations:

**When to use Gemini:**
- **Large codebase analysis:** When you need to analyze many files or large amounts of code that might strain your context limits, pipe content to `gemini -p` to take advantage of its large context capacity.
- **UI implementation:** Gemini excels at identifying UI patterns and implementing SwiftUI views. When implementing UI changes, **plan the approach here in Claude first**, then delegate the implementation to Gemini. Review and integrate what it produces.

**When NOT to use Gemini:**
- **Architectural decisions:** Do not delegate architectural changes, structural refactors, or design decisions to Gemini. All architectural planning and decisions must stay in Claude.
- **Planning:** Claude handles all planning. Gemini is an implementation tool, not a planning tool.

**Typical workflow for UI changes:**
1. **Claude:** Plan the UI change (what views to create/modify, what patterns to follow, what components to reuse)
2. **Gemini:** Implement the planned UI code via `gemini -p` with the plan and relevant context
3. **Claude:** Review the output, integrate it, and ensure it follows project conventions


## Project Overview

Ensemble is a universal Plex Music Player built with SwiftUI, targeting iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It streams music from Plex servers using PIN-based OAuth authentication. It is very important features work on iOS 15, and are memory and speed optimized for devices with 2GB or less of RAM.

Right now, this app is in beta testing. We should account for edge cases as we're developing the CoreData model. We have a little bit of leeway with regards to asking our testers to reset their app if needed.

The goal of this app is to provide a beautiful, information-dense, and customizable native experience for the Plex server.


## Recent Major Changes

### Live Lyrics (Mar 2026)
Karaoke-style time-synced lyrics fetched from Plex and displayed in the Now Playing Lyrics Card:

- **LRC parser:** `LRCParser` (static) parses LRC-format files into timestamped `LyricsLine` structs. Falls back to plain-text (unsynced) parsing for tracks without timestamps.
- **LyricsService:** @MainActor ObservableObject that runs a three-step fetch pipeline: in-memory cache → `.lrc` sidecar file → Plex API. Cache is keyed by `ratingKey:sourceCompositeKey` with ~20-entry LRU eviction.
- **API endpoint:** `PlexAPIClient.getLyricsContent(streamKey:)` fetches raw LRC text from `/library/streams/{streamKey}`. `PlexStream` extended with lyrics fields; `PlexTrack.lyricsStream` returns the first stream with `streamType == 4`.
- **NowPlayingViewModel integration:** Subscribes to `LyricsService.lyricsState` and `PlaybackService.currentTimePublisher`. Binary search over the lines array produces `currentLyricsLineIndex` for the active line.
- **LyricsCard rewrite:** Three states -- loading spinner, "No Lyrics" empty state, and a scrollable karaoke list (active line highlighted, auto-scrolled to center; past/future lines dimmed).
- **Offline sidecar:** `OfflineDownloadService` generates `.lrc` sidecar after download when the track has a lyrics stream. `DownloadManager` cleans it up on removal.
- **API accessor:** `SyncCoordinator.apiClient(for:)` and `PlexMusicSourceSyncProvider.exposedAPIClient` allow `LyricsService` to make direct API calls for lyrics content without going through the full sync path.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/LyricsService.swift` - LRCParser, LyricsLine, ParsedLyrics, LyricsState, LyricsService
- `Packages/EnsembleCore/Tests/LyricsServiceTests.swift` - LRC parser tests
- `Packages/EnsembleAPI/Sources/Models/PlexModels.swift` - PlexStream lyrics fields, PlexTrack.lyricsStream
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - getLyricsContent(streamKey:)
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires LyricsService
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - lyricsState, currentLyricsLineIndex
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - apiClient(for:) accessor
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` - exposedAPIClient
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - .lrc sidecar generation
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - .lrc sidecar cleanup
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - three-state lyrics UI

### Sharing: song.link URLs + Audio File Sharing (Mar 2026)
Tracks and albums can now be shared via universal song.link links or as audio files:

- **Universal link resolution:** Two-step chain: MusicKit catalog search (no subscription needed) -> song.link API for universal sharing link. Falls back to Apple Music URL or plain text.
- **Audio file sharing:** Downloaded tracks share local file directly. Non-downloaded tracks download to temp directory via Plex universal stream URL, then present share sheet.
- **Context menu integration:** "Share Link..." and "Share Audio File..." in all track context menus (TrackRow, MediaTrackList). "Share Link..." in album context menu (AlbumCard).
- **Now Playing:** Share link button in secondary controls + share actions in ellipsis menu.
- **Drag and drop (iPad):** Downloaded tracks can be dragged from track lists to other apps (Files, GarageBand, etc.) via `NSItemProvider` on both SwiftUI and UIKit surfaces.
- **In-memory caching:** SongLinkService caches positive and negative results to avoid re-querying MusicKit/song.link.
- **Toast feedback:** Progress toast for non-downloaded file sharing, fallback toast when sharing as text.
- **Platform guards:** `#if canImport(MusicKit)` for watchOS 8 compatibility; `NoOpMusicCatalogSearcher` fallback produces text-only payloads.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/SongLinkService.swift` - MusicKit search + song.link API + caching
- `Packages/EnsembleCore/Sources/Services/ShareService.swift` - Share payload coordinator + temp download
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - Service wiring
- `Packages/EnsembleUI/Sources/Components/ShareSheet.swift` - UIActivityViewController / NSSharingServicePicker wrapper
- `Packages/EnsembleUI/Sources/Components/ShareActions.swift` - Static share action helpers with toast feedback
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - Share context menu + onDrag
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - UIKit share menu + drag delegate
- `Packages/EnsembleUI/Sources/Components/AlbumCard.swift` - Album share link in context menu
- `Packages/EnsembleUI/Sources/Components/NowPlaying/ControlsCard.swift` - Share button + menu items
- `Ensemble/Info.plist` - NSAppleMusicUsageDescription
- `Ensemble/Ensemble.entitlements` - MusicKit entitlement

### Startup & Sync Performance Optimization (Mar 2026)
Eleven-item optimization pass targeting startup latency, network traffic, CPU waste, and temp storage:

- **Persisted failed hub keys:** `failedHubKeys` saved to UserDefaults so 404-returning hub endpoints are skipped across app launches. Cleared on pull-to-refresh or account changes.
- **Quality change debounce (2s):** Rapid quality setting changes debounce the expensive stream reload. Stale prefetch items are invalidated and re-fetched at the new quality.
- **Tighter stream cache eviction:** Cache files limited to playback neighborhood (current + next 2 + previous 1) instead of all cached player item IDs.
- **Faster FFT cancellation:** Cancellation checks every 2 keyframes (~0.2s) instead of 10 (~1s). Cancelled tasks no longer block callers.
- **Waveform fetch guard:** Skip waveform API call when track has no stream ID (reduces log noise, avoids unnecessary codepath).
- **Optimistic network state:** Last-known `NetworkState` cached to UserDefaults and restored on launch, so dependents begin immediately instead of waiting ~5s for NWPathMonitor.
- **Deferred audio session:** `configureAudioSession()` moved from `didFinishLaunching` to first playback (`ensureAudioSessionConfigured()`), avoiding Code=-50 errors. Adds `setActive(true)`.
- **ratedAfter optimization:** Skips the `lastRatedAt>=` fetch when sync timestamp is >10 minutes old, eliminating ~1MB of redundant API traffic per hourly sync.
- **CoreData merge policy:** `replaceMemberships()` uses `mergeByPropertyObjectTrumpMergePolicy` with single retry for concurrent target writes referencing shared tracks.

**Key files:**
- `Packages/EnsembleCore/Sources/ViewModels/HomeViewModel.swift` - persisted failedHubKeys
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - quality debounce, stream cache, audio session deferral, waveform guard
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - faster FFT cancellation
- `Packages/EnsembleCore/Sources/Services/NetworkMonitor.swift` - cached network state
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` - ratedAfter optimization
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift` - merge policy + retry
- `Ensemble/App/AppDelegate.swift` - removed configureAudioSession from launch

### Playback & Scroll Performance Optimization (Mar 2026)
Three-phase optimization targeting tap-to-play latency, visualizer timing, and scroll performance:

- **Fire-and-forget FFT analysis:** `loadTimeline()` is no longer `await`ed before `loadAndPlay()`. Uses `Task.detached` to avoid MainActor contention during multi-second FFT analysis. Visualizer shows zeros until analysis completes, then smoothly starts. Current-track analysis runs at `.userInitiated` priority; prefetch uses `.utility`.
- **Visualizer timing fix:** `activateTimeline()` now starts paused (`isPaused = true`). Visualizer only begins interpolating when `resumeUpdates()` is called after `timeControlStatus == .playing` is confirmed. Gapless transitions call `resumeUpdates()` immediately since audio is already playing.
- **Selective player item cache:** Queue start paths use `evictPlayerItemsNotIn()` instead of `clearPlayerItemCache()`, preserving prefetched items that overlap with the new queue.
- **Scroll performance:** Artwork URL cache TTL increased from 5s to 60s. `TrackAvailabilityResolver.bumpGeneration()` debounced at 100ms to coalesce rapid launch-time bumps.
- **Gapless over AirPlay:** Wall-clock boundary timer suppressed when AVQueuePlayer has items queued, preventing premature `handleQueueExhausted()` that caused gaps over AirPlay.
- **Memory alignment fixes:** FFT analysis uses `withUnsafeBufferPointer` on `[Float]` for aligned DSPComplex reinterpretation. Sidecar loading uses `loadUnaligned()` for `Data` buffer reads.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - fire-and-forget loadTimeline, visualizer resume on .playing, selective cache eviction, wall-clock boundary suppression
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - activateTimeline starts paused, priority-aware analysis, alignment fixes
- `Packages/EnsembleCore/Sources/Services/ArtworkLoader.swift` - increased URL cache TTL
- `Packages/EnsembleCore/Sources/Services/TrackAvailabilityResolver.swift` - debounced bumpGeneration

### Pre-Computed Frequency Visualizer (Mar 2026)
Replaced the MTAudioProcessingTap-based real-time audio visualizer with a pre-computed frequency analysis system, fully decoupling the visualizer from the audio pipeline:

- **Accelerate FFT analysis:** Audio files are analyzed on disk using a 1024-pt FFT with 24 log-spaced frequency bands (60Hz-16kHz). Results stored as `FrequencyTimeline` (time-indexed snapshots at 30fps, ~216KB per 5-min song).
- **Display timer:** A 30Hz timer reads `player.currentTime()` and looks up the matching frame from the active timeline -- no audio tap or mix required.
- **Binary sidecar files:** `.freq` files are generated alongside offline downloads for instant visualizer load on cached tracks. `DownloadManager` cleans up sidecars on download removal.
- **Removed:** `MTAudioProcessingTap`, `audioMix`, fade timers, and simulated frequency bands are all gone from `PlaybackService`.
- **Scrubber sync:** Scrubber drag in `ControlsCard` calls `NowPlayingViewModel.updateVisualizerPosition()` so the visualizer tracks seek position in real time.
- **Extension probing:** `FrequencyAnalysisService` probes unrecognized file extensions to determine if they are readable audio before attempting analysis.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - FrequencyTimeline model, FrequencyAnalysisService, FrequencyTimelinePersistence
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - removed tap/fade/simulated-bands; wires loadTimeline/activateTimeline/evictTimeline/updatePlaybackPosition
- `Packages/EnsembleUI/Sources/Components/NowPlaying/ControlsCard.swift` - scrubber drag syncs visualizer
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - updateVisualizerPosition method
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - swapped AudioAnalyzer for FrequencyAnalysisService
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - .freq sidecar cleanup
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - sidecar generation after download

### WebSocket Enhancements + Download Spinners (Mar 2026)
Six improvements building on the WebSocket infrastructure:

- **Playlist auto-update:** `PlaylistViewModel` now subscribes to `syncCoordinator.$sourceStatuses` (1s debounce) as defensive fallback for WebSocket-triggered playlist changes.
- **Download spinners:** `OfflineDownloadService` publishes `activeDownloadRatingKeys: Set<String>`. `TrackRow` and `MediaTrackList` show a spinner for actively downloading tracks, replaced by download icon on completion.
- **Scan progress indicator:** `PlexWebSocketCoordinator` tracks `serverScanProgress: [String: Int]` from activity events. `MusicSourceAccountDetailView` shows a linear progress bar per server during library scans.
- **Smart playlist auto-refresh:** `SyncCoordinator.rateTrack()` triggers a debounced (5s) playlist sync after rating changes so smart playlists reflect new state.
- **Artwork cache invalidation:** WebSocket album/artist metadata updates (type=9/8, state=5) fire `onArtworkInvalidation`. `ArtworkLoader.invalidateArtwork()` clears URL cache + local file + Nuke cache and posts notification. `ArtworkView` re-triggers load on invalidation.
- **Incremental sync timestamp buffer:** 5s subtracted from `since` timestamp to avoid missing near-boundary changes.

**Key files:**
- `Packages/EnsembleCore/Sources/ViewModels/PlaylistViewModel.swift` - sourceStatuses observer
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - activeDownloadRatingKeys
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - download spinner
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - UIKit download spinner
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - serverScanProgress, onArtworkInvalidation
- `Packages/EnsembleCore/Sources/ViewModels/MusicSourceAccountDetailViewModel.swift` - scanProgressByServer
- `Packages/EnsembleUI/Sources/Screens/MusicSourceAccountDetailView.swift` - scan progress bar UI
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - post-rating playlist sync, 5s timestamp buffer
- `Packages/EnsembleCore/Sources/Services/ArtworkLoader.swift` - invalidateArtwork, artworkDidInvalidate notification
- `Packages/EnsemblePersistence/Sources/Downloads/ArtworkDownloadManager.swift` - deleteArtwork
- `Packages/EnsembleUI/Sources/Components/ArtworkView.swift` - invalidation listener
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - onArtworkInvalidation wiring

### Network Resilience & Offline Architecture v1 (Mar 2026)
Five-phase overhaul of network resilience, push-based server updates, reactive track availability, queue resilience, and unified error handling:

- **Phase 1 -- ServerConnectionRegistry:** New actor (`ServerConnectionRegistry`) is the single source of truth for per-server endpoints. `PlexAPIClient` reports failover results back to the registry; `ServerHealthChecker` writes probe results; `SyncCoordinator` subscribes to registry changes; `AccountManager` owns the registry; `DependencyContainer` wires it.
- **Phase 2 -- PlexWebSocketManager + PlexWebSocketCoordinator:** `PlexWebSocketManager` (actor) manages one `URLSessionWebSocketTask` per server with exponential backoff reconnect. `PlexWebSocketCoordinator` (@MainActor) routes WS events to sync and health systems. `SyncCoordinator` gains adjustable timer policy and incremental section-level sync. `AppDelegate` starts/stops WebSocket connections on foreground/background.
- **Phase 3 -- TrackAvailabilityResolver:** New @MainActor ObservableObject publishes per-track availability by combining per-server connection state with per-track download state. `TrackAvailability` enum (`.available`, `.availableDownloadedOnly`, `.unavailableServerOffline`, `.unavailableNetworkOffline`) replaces inline offline checks in `TrackRow`, `CompactSearchRows`, and `MediaTrackList`.
- **Phase 4 -- Queue Resilience:** `PlaybackService` circuit breaker scans for downloaded alternatives; `retryCurrentTrack()` falls back to local downloads; cache eviction for newly downloaded queue items; auto-resume on health check completion.
- **Phase 5 -- Mutation Queue Hardening:** `PlexErrorClassification` provides unified error taxonomy (transport vs. semantic). `PlexAPIClient` and `MutationCoordinator` use it for failover/retry decisions. `MutationCoordinator` queues failed scrobbles as `CDPendingMutation` (`.scrobble` type). `PlaybackService` routes scrobbles through the mutation coordinator via `SyncCoordinator.scrobbleTrackThrowing()`. `PendingMutationsViewModel` and `PendingMutationsView` display queued scrobbles.

**Key files:**
- `Packages/EnsembleAPI/Sources/Client/ServerConnectionRegistry.swift` - actor, per-server endpoint truth
- `Packages/EnsembleAPI/Sources/Client/PlexWebSocketManager.swift` - actor, per-server WebSocket with backoff
- `Packages/EnsembleAPI/Sources/Client/PlexErrorClassification.swift` - unified error taxonomy
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - failover reports to registry, uses error classification
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - routes WS events to sync/health
- `Packages/EnsembleCore/Sources/Services/TrackAvailabilityResolver.swift` - reactive per-track availability
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` - registry subscription, adjustable timers, scrobbleTrackThrowing
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - queue resilience, download fallback, scrobble routing
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires registry, WS coordinator, availability resolver
- `Packages/EnsemblePersistence/Sources/CoreData/ManagedObjects.swift` - CDPendingMutation .scrobble type
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Components/CompactSearchRows.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - uses TrackAvailabilityResolver
- `Packages/EnsembleUI/Sources/Screens/PendingMutationsView.swift` - shows queued scrobbles
- `Ensemble/App/AppDelegate.swift` - WS start/stop on foreground/background

### Offline Download Manager v1 (Settings-Managed, Target-Based) (Mar 2026)
Offline downloads now use target-based management with source-safe reconciliation and optional iOS 26 continued background processing acceleration:

- **Inline libraries section:** Downloads tab shows a "Libraries" section with each sync-enabled library as a rich row (toggle, download stats, drill-in navigation), replacing the previous "Bulk Downloads" → `Servers` drill-in.
- **Library detail view:** tapping a library row shows all downloaded tracks for that library regardless of which target type (library, album, playlist, artist) triggered the download.
- **Target types:** albums, artists, and playlists can be toggled via context/detail menus (`Download` / `Remove Download`).
- **Reference-counted memberships:** shared tracks are retained until all referencing targets are removed; orphaned downloads are removed automatically.
- **Source-safe identity:** track downloads and target memberships are keyed by `ratingKey + sourceCompositeKey` to avoid cross-server/library collisions.
- **Quality-aware downloads:** download queue uses Audio Quality setting (`downloadQuality`) and universal streaming URL generation for quality-aware fetches.
- **Network policy:** queue defaults to Wi-Fi/wired only; optional "Allow Downloading on Cellular" toggle in Manage Downloads settings enables cellular downloads.
- **Sync-triggered reconciliation:** library/playlist targets re-evaluate after source sync updates and playlist refresh completion events.
- **Optional iOS 26 BG accelerator:** `BGContinuedProcessingTask` path is best-effort for user-initiated bulk work; persistent queue remains source of truth and fallback.
- **Offline UX hardening:** when offline, non-downloaded tracks are dimmed and taps are blocked with toast feedback.

**Key files:**
- `Packages/EnsemblePersistence/Sources/CoreData/Ensemble.xcdatamodeld/Ensemble.xcdatamodel/contents`
- `Packages/EnsemblePersistence/Sources/CoreData/ManagedObjects.swift`
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift`
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift`
- `Packages/EnsemblePersistence/Sources/Repositories/LibraryRepository.swift`
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift`
- `Packages/EnsembleCore/Sources/Services/OfflineBackgroundExecutionCoordinator.swift`
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift`
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift`
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift`
- `Packages/EnsembleCore/Sources/ViewModels/DownloadsViewModel.swift`
- `Packages/EnsembleCore/Sources/ViewModels/LibraryDownloadDetailViewModel.swift`
- `Packages/EnsembleUI/Sources/Screens/DownloadsView.swift`
- `Packages/EnsembleUI/Sources/Screens/DownloadManagerSettingsView.swift`
- `Packages/EnsembleUI/Sources/Screens/LibraryDownloadDetailView.swift`
- `Packages/EnsembleUI/Sources/Components/TrackDownloadRowView.swift`
- `Ensemble/App/AppDelegate.swift`
- `Ensemble/Info.plist`

### Universal Transcode Endpoint + Quality Settings (Mar 2026)
Streaming now uses Plex's universal transcode endpoint with quality settings support, fixing playback for non-Plex Pass accounts:

- **Universal endpoint:** All streaming routes through `/music/:/transcode/universal/start.mp3` with `protocol=http` (progressive download). Falls back to direct file URLs if the universal endpoint fails (URL construction error).
- **Decision endpoint required:** The `/music/:/transcode/universal/decision` endpoint MUST be called before `/start.mp3` to warm up the transcode session. Without this, PMS returns 400. The `getUniversalStreamURL()` method handles this automatically.
- **Quality-aware routing:** "Original" quality uses `directPlay=0&directStream=1` (PMS direct-streams original codec through its pipeline); reduced qualities add `musicBitrate`/`audioBitrate` params and PMS transcodes to MP3 at the target bitrate.
- **Non-Plex Pass fix:** Direct file URLs were cut off at ~655KB for non-Plex Pass users; universal endpoint streams through PMS's pipeline and works for all account types.
- **Quality mapping:** original=direct-stream, high=320kbps MP3, medium=192kbps MP3, low=128kbps MP3.
- **Client profile:** `transcodeClientProfileExtra()` declares both transcode output codecs (AAC, MP3) and direct-play codecs (AAC, MP3, FLAC, ALAC) so PMS knows what the client can handle natively.
- **Settings integration:** `streamingQuality` AppStorage value (from Settings -> Audio Quality) is respected during playback via `PlexMusicSourceSyncProvider.getStreamURL()`.

**Key files:**
- `PlexAPIClient.swift` - `StreamingQuality` enum, `getUniversalStreamURL()` method, `callTranscodeDecision()`, `transcodeClientProfileExtra()`
- `PlexMusicSourceSyncProvider.swift` - quality-aware routing through universal endpoint with direct-stream fallback
- `SyncCoordinator.swift` - quality parameter routing to provider
- `PlaybackService.swift` - reads `streamingQuality` from UserDefaults and passes to stream URL generation

### Siri Media Intents v1.1 (In-App-First) (Feb 2026)
Siri playback now supports **track, album, artist, and playlist** phrases through SiriKit Media Intents with in-app execution:

- **Thin extension:** `INPlayMediaIntentHandling` resolves/ranks candidates and uses Siri disambiguation when confidence is low.
- **In-app execution:** extension returns `handleInApp`; the app decodes a versioned payload and executes playback via a dedicated coordinator.
- **Indexing path:** shared App Group JSON index includes track/album/artist/playlist candidates with ranking metadata.
- **Precision search:** repositories now expose scoped title/name search methods for deterministic Siri matching.
- **Routing + outcomes:** deterministic ranking (exact > prefix > contains), tie-breakers, and Siri-friendly failure mapping.
- **HomePod workaround:** For HomePod requests, iOS never calls `handle()` after `confirm()` returns `.ready`. As a workaround, `confirm()` writes the payload to App Group and posts a Darwin notification; the app listens for this notification and executes playback directly, bypassing the broken `handle()` flow.

**Key files:**
- `EnsembleSiriIntentsExtension/IntentHandler.swift` + `PlayMediaIntentHandler.swift` + `Info.plist` - Siri media extension entry and intent handling
- `SiriIntentPayload.swift` + `SiriMediaIndex.swift` - versioned handoff payload + compact index models
- `SiriMediaIndexStore.swift` - App Group index persistence/rebuild notification hooks
- `SiriPlaybackCoordinator.swift` - in-app execution for track/album/artist/playlist intents
- `AppDelegate.swift` + `DependencyContainer.swift` - lifecycle routing + DI wiring + Darwin notification listener
- `LibraryRepository.swift` + `PlaylistRepository.swift` - precision search methods used by Siri matching

### Siri App Intents Fallback for Album/Playlist (Feb 2026)
Siri playback now also includes an App Intents fallback path for album/playlist phrases when SiriKit media-domain routing does not invoke Ensemble:

- **App shortcut phrases:** explicit album/playlist phrases are registered via `AppShortcutsProvider`.
- **Dynamic entity resolution:** shortcut entity queries read album/playlist candidates from the shared Siri media index (App Group JSON derived from cached library data).
- **In-app execution reuse:** fallback intents execute playback through `SiriPlaybackCoordinator` using the same payload contract as SiriKit.
- **Vocabulary refresh:** app launch now refreshes App Shortcuts parameter metadata after index availability checks so Siri phrase resolution stays current.

**Key files:**
- `Ensemble/App/EnsembleAppShortcuts.swift` - App Intents entities/queries/intents and shortcut phrases
- `Ensemble/App/AppDelegate.swift` - startup App Shortcuts parameter refresh

### Account-Centric Source Management + Sign-In Redesign (Feb 2026)
The Plex source flow now centers on accounts (not individual server rows), and sync controls live in account detail:

- **Add-account flow:** PIN can be copied on tap; discovery returns account identity plus all available servers/libraries in one checklist.
- **Music Sources settings:** list now shows account-level sources (`Plex` + account identifier subtitle), and navigation opens account detail.
- **Account detail:** shows server-grouped libraries (checked + unchecked), per-library sync/connection status, and a single “sync enabled libraries” action.
- **Reconciliation behavior:** newly discovered libraries default unchecked; removed libraries are auto-disabled and purged.
- **Purge semantics:** unchecking a library purges only that library’s cache; if the last enabled library for a server is removed/disabled, server-level playlists are purged.
- **Navigation cleanup:** legacy standalone Sync Panel routes were removed from tab/more/sidebar flows.
- **Visibility groundwork:** `LibraryVisibilityProfile` + `LibraryVisibilityStore` are in place, and `LibraryViewModel`/`SearchViewModel`/`HomeViewModel` now support source-level visibility filtering (without changing sync enablement).

**Key files:**
- `AddPlexAccountViewModel.swift` + `AddPlexAccountView.swift` - account discovery, grouped selection, PIN copy UX
- `SettingsView.swift` + `MusicSourceAccountDetailView.swift` + `MusicSourceAccountDetailViewModel.swift` - account-level source list and detail flow
- `AccountManager.swift` + `SyncCoordinator.swift` + `PlaylistRepository.swift` - reconciliation, selective purge, server playlist cleanup
- `MainTabView.swift` + `MoreView.swift` - Sync Panel entry-point removal
- `LibraryVisibilityProfile.swift` + `LibraryVisibilityStore.swift` - visibility profile foundation
- `LibraryViewModel.swift` + `SearchViewModel.swift` + `HomeViewModel.swift` - visibility filter seams

### Sync System Overhaul (Feb 2026)
The sync system now supports **incremental sync** using Plex API timestamp filters (`addedAt>=`, `updatedAt>=`):

- **Pull-to-refresh:** Library views perform incremental sync (fast), HomeView refreshes hubs only
- **Startup sync:** Full sync if >24h old, incremental if >1h old, skip if fresh (<1h)
- **Background refresh (iOS):** `BGAppRefreshTask` refreshes hubs every ~15min (system-controlled)
- **Routine updates:** Incremental library sync every 1h, hubs every 10min while app is active
- **Offline-first:** All syncs respect offline state, fall back to CoreData cache

**Key files:**
- `SyncCoordinator.swift` - `syncAllIncremental()`, `performStartupSync()`, periodic timers
- `PlexMusicSourceSyncProvider.swift` - `syncLibraryIncremental(since:)`
- `PlexAPIClient.swift` - Filtered fetch methods (e.g., `getArtists(sectionKey:addedAfter:)`)
- `BackgroundSyncScheduler.swift` - iOS background refresh scheduling

### Playlist Mutations Rollout (Feb 2026)
Playlist management now supports server-backed mutations with local cache refresh:

- **Now Playing:** add current track to playlist, save current queue snapshot
- **Playlist Detail:** rename and edit playlist track ordering/removals
- **Album Detail:** add full filtered album track list to playlist from the pin menu
- **Consistency:** all successful playlist mutations trigger server refresh + CoreData update
- **Smart playlists:** treated as read-only for mutation operations

**Key files:**
- `PlexAPIClient.swift` - Create/rename/add/remove/move playlist mutation endpoints
- `SyncCoordinator.swift` - Playlist mutation orchestration + post-mutation playlist refresh
- `NowPlayingViewModel.swift` - Queue snapshot logic and shared playlist action methods
- `PlaylistViewModel.swift` - Playlist detail rename/edit mutation hooks
- `PlaylistActionSheets.swift` - Shared add/create playlist UI sheets

### Gesture Actions v1 (Feb 2026)
Library and search surfaces now support configurable swipe actions for track rows plus long-press menus for album/artist/playlist items:

- **Track swipe actions (iOS/iPadOS):** shared 2 leading + 2 trailing layout with customizable slot assignment
- **Action catalog:** `Play Next`, `Play Last`, `Add to Playlist…`, favorite toggle (Loved on/off)
- **Full swipe:** executes slot 1 on each edge
- **Long-press menus:** album/artist/playlist menus on cards/rows; playlist menus respect smart-playlist mutation guards
- **Settings:** Playback section includes `Track Swipe Actions` customization with reset to defaults

**Key files:**
- `SettingsManager.swift` - `TrackSwipeAction`/`TrackSwipeLayout` model + persisted/sanitized slot configuration
- `TrackSwipeContainer.swift` - Shared SwiftUI swipe layer for track rows
- `MediaTrackList.swift` - UIKit leading/trailing swipe actions aligned to shared layout
- `TrackSwipeActionsSettingsView.swift` - Slot customization UI in Settings
- `NowPlayingViewModel.swift` - Per-track favorite mutation methods used by swipe/context actions

### Network Health + Hub Refresh Hardening (Feb 2026)
Network transition handling now coalesces health checks, repairs stale endpoint usage after interface handoff, and avoids Home feed jumps while users scroll:

- **Network monitor lifecycle safety:** `NetworkMonitor` recreates `NWPathMonitor` instances on restart so background/foreground cycles continue publishing connectivity changes.
- **Transition-aware health orchestration:** `SyncCoordinator` classifies reconnect/interface-switch transitions, applies 30s cooldown + 60s foreground staleness guards, and coalesces concurrent refreshes into a single run.
- **Scoped health checks:** only servers with enabled libraries are checked during sync health refresh runs.
- **Probe fan-out reduction:** `ConnectionFailoverManager` tries a recent healthy URL first, then falls back to parallel probing if needed.
- **Home scrolling stability:** `HomeViewModel` defers auto-refresh and hub snapshot application while users are interacting, then applies once idle.
- **Lifecycle routing:** foreground health refresh now flows through `SyncCoordinator.handleAppWillEnterForeground()` so app lifecycle and monitor transitions share one policy path.

**Key files:**
- `NetworkMonitor.swift` - restart-safe monitor lifecycle and debounce testing seams
- `SyncCoordinator.swift` - transition classification, cooldown/staleness policy, coalesced refresh path
- `ServerHealthChecker.swift` - per-server TTL cache, forced refresh support, cancellation fixes
- `ConnectionFailoverManager.swift` - preferred recent connection fast-path
- `HomeViewModel.swift` - deferred auto-refresh + idle apply policy
- `HomeView.swift` - visibility and scroll interaction callbacks

### Plex Connectivity Spec Parity Cutover (Feb 2026)
Plex endpoint discovery/routing/auth now follows a stricter spec-parity path to avoid stale routing and generic "server unavailable" failures:

- **Discovery parity:** resource discovery requests now include IPv6 candidates and shared Plex headers.
- **Policy-driven endpoint ordering:** connection selection now prefers local/direct endpoints before remote and relay, with secure-first behavior and configurable insecure fallback policy.
- **Failover discipline:** endpoint failover now triggers on transport/connectivity failures only (not arbitrary HTTP semantic errors).
- **Structured refresh outcomes:** server connection refresh returns typed outcomes instead of swallowing failures, and call sites now react explicitly.
- **Failure taxonomy:** server checks classify failures (local-only reachable, remote access unavailable, relay unavailable, TLS policy blocked, offline) for clearer user-facing messages.
- **Auth lifecycle cutover:** account token metadata stores JWT `iat`/`exp`; a migration version bump forces re-login and expired tokens are rejected on load/foreground.

**Key files:**
- `PlexAPIClient.swift` - resources request contract, transport-only failover policy, structured refresh
- `PlexConnectionPolicy.swift` - endpoint descriptors, selection policy, connection refresh result types
- `ConnectionFailoverManager.swift` - policy-aware probing and probe failure classification
- `PlexAuthService.swift` + `PlexAuthTokenMetadata.swift` - auth token metadata parsing and lifecycle helpers
- `AccountManager.swift` - auth migration cutover and expiry enforcement
- `ServerHealthChecker.swift` - classified health failure reasons

### Adaptive Playback Stability (Feb 2026)
Playback buffering now uses an internal adaptive profile tuned by network conditions and recent stall history to reduce skip/seek buffering loops:

- **Adaptive profile defaults:** Wi-Fi/wired uses low-latency buffering with deeper prefetch (`prefetchDepth=2`), while cellular/other uses anti-stall waits with deeper forward buffering (`prefetchDepth=1`).
- **Stall escalation:** repeated stalls in a short window temporarily switch playback into a conservative recovery profile.
- **Windowed prefetch:** upcoming queue prefetch is depth-based instead of single-item, and queue rebuild paths refill using the active profile depth.
- **Seek stability:** pending seek progress gate now stays active longer while buffering to prevent scrubber/audio drift during unbuffered seeks.
- **Recovery throttling:** stall retries use profile-based timeout and a retry cooldown to avoid rapid reload thrash on weak links.

**Key files:**
- `PlaybackService.swift` - adaptive buffering profile, stall escalation/cooldown logic, windowed prefetch, seek-progress gating
- `PlaybackServiceTests.swift` - adaptive profile/escalation and seek-gate helper coverage


This project is connected to Xcode's MCP server: please use it to inform you of how best to operate.

Please comment code so that it's understandable. Don't over comment, just comment on what each "piece" does. Do not use emojis (except in debugging).

As you make changes, keep the following documents in sync:

| What changed | What to update |
|---|---|
| New service, subsystem, or major pattern | `architecture` skill + CLAUDE.md Recent Major Changes |
| New file added anywhere | `project-structure` skill |
| New recipe, pattern, or call convention | `common-tasks` skill |
| New UI component, navigation pattern, or visual rule | `ui-conventions` skill |
| New coding rule, naming convention, or mandatory practice | `code-style` skill |
| New known bug, limitation, or tech debt | `known-issues` skill |
| Feature shipped or roadmap item completed | `README.md` |
| Anything that changes how agents should work in this repo | `CLAUDE.md` |
| New View or UI element added/renamed/removed | `VOCABULARY.md` |

When in doubt: if a future agent session wouldn't know about it by reading the skills, document it.

Please don't remove existing functionality (unless directed) when re-architecting parts of the code. I've had to re-implement multiple things that I had asked for and that were removed.


## Build & Test Commands

**Build the full app (iOS simulator):**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**Build a single package:**
```bash
swift build --package-path Packages/EnsembleAPI
swift build --package-path Packages/EnsembleCore
swift build --package-path Packages/EnsemblePersistence
swift build --package-path Packages/EnsembleUI
```

**Run tests for a single package:**
```bash
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
```

**Run all tests via Xcode:**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

**IMPORTANT:** Always open `Ensemble.xcworkspace` (not `.xcodeproj`) when working in Xcode.


## Architecture (Brief)

Layered modular architecture via four Swift Packages under `Packages/`:

```
Layer 3: EnsembleUI (SwiftUI views & components)
              |
Layer 2: EnsembleCore (ViewModels, services, domain models)
              |
Layer 1: EnsembleAPI (Networking) + EnsemblePersistence (CoreData)
```

For detailed architecture, invoke the `architecture` skill.


## External Dependencies

- **KeychainAccess** (4.2.0+) -- Secure token storage (EnsembleAPI). SPM: `https://github.com/kishikawakatsumi/KeychainAccess.git`
- **Nuke** (12.0.0+) -- Image loading and caching (EnsembleCore + EnsembleUI via NukeUI). SPM: `https://github.com/kean/Nuke.git`
