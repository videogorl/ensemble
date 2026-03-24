---
name: recent-changes
description: "Changelog of recent major features and subsystem changes. Load when debugging, investigating prior work, understanding how a feature was implemented, or before touching an area that was recently modified. Covers: feature availability per account/server/library, cold launch optimization, low power mode, app performance optimization, live lyrics, sharing, startup/sync performance, playback/scroll performance, frequency visualizer, WebSocket enhancements, network resilience, offline downloads, universal transcode, Siri intents, account management, sync system, playlist mutations, gesture actions, network health, Plex connectivity, adaptive playback."
user-invocable: true
---

# Recent Major Changes

### External Output Sync Compensation (Mar 24, 2026)

Aurora visualization and live lyrics now follow a presentation clock instead of raw transport time when playback is actively flowing. `PlaybackService` estimates external output latency for AirPlay and Bluetooth routes from the audio session, publishes `presentationTime`, and keeps transport time untouched for seek/reporting/scrobble paths. `NowPlayingViewModel` now drives lyric highlighting from the presentation clock, and the visualizer analyzer receives the adjusted timeline so the UI better matches what the user actually hears on buffered routes.

**Key files:**
- `PlaybackService.swift` -- Presentation clock, route classification, latency estimation, adjusted analyzer feed
- `NowPlayingViewModel.swift` -- Lyrics highlight/restore now consume presentation time
- `LyricsService.swift` -- Added debug-only test seam for view-model timing coverage
- `PlaybackServiceTests.swift` -- Route kind, latency estimate, and presentation time tests
- `NowPlayingViewModelFavoriteTests.swift` -- Lyrics timing regression coverage
- `README.md` -- Playback feature list updated for external-output sync compensation

### Instrumental Mode / Vocal Attenuation (Mar 20, 2026)

Apple Music Sing-style feature using AUSoundIsolation AudioUnit for on-device vocal removal. Hybrid engine switching: AVQueuePlayer stays active for normal playback; toggling instrumental mode switches to an AVAudioEngine pipeline with AUSoundIsolation, then switches back when toggled off.

**Key behaviors:**
- Binary toggle (on/off) on LyricsCard header
- Persists across track skips within the same queue
- Resets when a new queue is injected (play new album/playlist)
- Only available on iOS 16+ / A13+ devices (button hidden on unsupported)
- Brief ~100-300ms audio gap when toggling

**Key files:**
- `InstrumentalModeCapability.swift` -- Static AUSoundIsolation probe
- `InstrumentalAudioEngine.swift` -- AVAudioEngine wrapper with sound isolation
- `PlaybackService.swift` -- Engine switching, seek/play/pause routing, track-change re-engagement
- `NowPlayingViewModel.swift` -- Published state, binding, toggle action
- `LyricsCard.swift` -- Toggle button (mic.circle / mic.slash.circle)
- `ProgressiveStreamLoader.swift` -- Added `isDownloadComplete` public accessor

### Bug Fix Batch: Hubs, Wikipedia, Progress Bar (Mar 20, 2026)

Four fixes from beta feedback:

1. **Miniplayer progress bar removed:** Deleted `PlaybackProgressBar` struct from `MiniPlayer.swift` and its rendering from `MainTabView.swift`. Key files: `MiniPlayer.swift`, `MainTabView.swift`

2. **Wikipedia album URL fixed:** Now uses `{Album}_({Artist}_album)` format per Wikipedia convention instead of just `{Album}_(album)`, avoiding disambiguation pages. Falls back to `_(album)` for "Various Artists" or unknown artist. Key file: `DomainModels.swift`

3. **Hub cross-library merging fixed:** Added normalized title to grouping key and merged hub IDs. Contextual hubs ("More by X") no longer incorrectly merge across libraries, while generic hubs ("Recently Added") still do. Key file: `HomeViewModel.swift`

4. **Hub ordering persistence fixed:** Added order migration that remaps stale saved hub IDs when ID format changes (single <-> merged) after libraries are added/removed. Matches by raw hub type + normalized title with type-only fallback. Key files: `HomeViewModel.swift`, `HubOrderManager.swift`

### UI Cleanup Batch (Mar 20, 2026)

Six UI improvements across the app:

1. **Info card reorder:** Playing and Original (combined codec + file size) rows now appear at top of File section, followed by Source, Quality, Lyrics, then Bitrate/Sample Rate/Bit Depth. Key file: `InfoCard.swift`

2. **Source view reorganization:** Sync buttons moved below server/library sections. New feature legend section explains badge icons (Plex Pass, Lyrics, Radio). Key file: `MusicSourceAccountDetailView.swift`

3. **Favorite heart icon:** Pink `heart.fill` indicator shown for favorited tracks in both SwiftUI `TrackRow` and UIKit `TrackTableViewCell`. Heart appears at leading edge, shifting content right by 14pt. Key files: `TrackRow.swift`, `MediaTrackList.swift`

4. **Offline indicator simplification:** Replaced ~300 lines of private API code (DynamicIslandIndicator, NotchIndicator, NotchOutlinePath, ClassicStatusBarIndicator, DeviceStyle enum, UIScreen extensions) with a single `LinearGradient` using only the public `topInset` API. Future-proof across all device types. Key file: `OfflineIndicatorOverlay.swift`

5. **Mood tracks UIKit migration:** Replaced SwiftUI `TrackRow`/`TrackSwipeContainer` with `MediaTrackList` (UITableView). Header scrolls as `tableHeaderContent`, loading/error/empty states via `tableFooterContent`. Added targeted observation state for downloads/availability/current track. Key file: `MoodTracksView.swift`

6. **Album detail rich metadata:** Full-stack feature across all 4 packages. `PlexAlbumDetail` API model + `getAlbumDetail` method. `AlbumDetail` domain model with genres, styles, studio/label, summary, Wikipedia URL. `AlbumDetailViewModel` loads detail + related albums. `MediaDetailView` accepts `additionalFooterContent`. Album detail UI shows facts section, collapsible description, Wikipedia link, and horizontal related albums section below the track list. Key files: `PlexModels.swift`, `PlexAPIClient.swift`, `DomainModels.swift`, `ModelMappers.swift`, `MusicSourceSyncProvider.swift`, `PlexMusicSourceSyncProvider.swift`, `SyncCoordinator.swift`, `AlbumDetailViewModel.swift`, `MediaDetailView.swift`, `AlbumsView.swift`

### Genre Filtering Chips (Mar 19, 2026)

Added inline genre filtering across library views (Albums, Songs, Artists) and PlaylistDetailView. Genre data parsed from Plex API on albums (`PlexAlbum.genre`), copied to tracks during sync. Reusable `GenreChipBar` component with OR multi-select, capsule-styled chips. Also wired into FilterSheet for full filter sheet support.

Key files: `GenreChipBar.swift`, `PlexModels.swift` (PlexAlbum.genre), `DomainModels.swift` (genres on Album/Track), `LibraryRepository.swift` (genreNames upsert), `PlexMusicSourceSyncProvider.swift` (genre wiring), `LibraryViewModel.swift` (filter logic + available genres), `PlaylistViewModel.swift`, `AlbumsView.swift`, `SongsView.swift`, `ArtistsView.swift`, `PlaylistsView.swift`

### Now Playing Info Card Restructure + Track Artist Fix (Mar 19, 2026)

**Track artist fix:** Now Playing and all track displays now show the track artist (`originalTitle`) instead of the album artist (`grandparentTitle`). Fixed in sync provider (both incremental and full sync paths) and hub/search mapper — the previous commit only fixed `ModelMappers` but missed the CoreData write paths.

**Info card restructure:** Info card reorganized into three sections:
- **Track:** Album, Artist (tappable), Track Artist (when different, plain text), Year, Track/Disc, Duration, Plays, Added, Source, Quality, Lyrics
- **File (new):** Codec, Bitrate, Sample Rate, Bit Depth, File Size — fetched on demand from Plex API
- **Server (renamed from Streaming):** Server, Library, Connection, Status, Network

**New domain model:** `AudioFileInfo` struct holds audio format metadata. `NowPlayingViewModel.fetchAudioFileInfoForCurrentTrack()` fetches via `PlexAPIClient.getTrack()` on demand. New fields decoded in `PlexStream`: `bitrate`, `bitDepth`, `samplingRate`, `channels`.

**Album detail track rows:** Album name hidden in track row subtitle when viewing album detail (redundant). `showAlbumName` parameter added to `MediaTrackList` and `TrackTableViewCell`.

**Track model:** Added `albumArtistName` field to `Track` domain model (always `grandparentTitle`), populated in all mapper paths. `originalTitle` added to `PlexHubMetadata`.

**Key files:**
- `Packages/EnsembleAPI/Sources/Models/PlexModels.swift` — PlexStream new fields, PlexHubMetadata.originalTitle
- `Packages/EnsembleCore/Sources/Models/DomainModels.swift` — AudioFileInfo, Track.albumArtistName
- `Packages/EnsembleCore/Sources/Models/ModelMappers.swift` — AudioFileInfo mapper, albumArtistName population
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` — fetchAudioFileInfoForCurrentTrack()
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` — originalTitle in sync paths
- `Packages/EnsembleUI/Sources/Components/NowPlaying/InfoCard.swift` — 3-section layout, File section
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` — showAlbumName parameter
- `Packages/EnsembleUI/Sources/Screens/MediaDetailView.swift` — passes showAlbumName: false for albums

---

### Queue Skipping Cascade Fix + iOS 26 Search Bar Crash (Mar 18, 2026)

Fixed two bugs: (1) Rapid previous()/next() taps caused a cascade where AVPlayer XPC corruption triggered phantom auto-advance via `handleQueueExhausted()`, making the queue unrecoverable — even starting a new queue failed. (2) `NavigationView` + `.searchable()` on iOS 26 crashed with 997+ "Observation tracking feedback loop" errors from `ScrollPocketCollectorModel`.

Queue cascade fixes: Guards in `handleQueueExhausted()` for skip-in-progress and loading states; `previous()` now cancels/replaces `skipTransitionTask`; failure counter reset removed from skip entry (only resets on confirmed audio). Recovery: `recreatePlayer()` method for corrupted AVPlayer, called when starting new queue from failed state; 15s stuck-loading watchdog recreates player if loading stalls.

Search crash fix: `PlaylistPickerSheet` now uses `NavigationStack` on iOS 16+ instead of `NavigationView`.

**Key files:** `PlaybackService.swift`, `PlaylistActionSheets.swift`

---

### Feature Availability Per Account/Server/Library (Mar 18, 2026)

Added capability detection during server discovery so the app knows per-account subscription status, per-server capabilities, and per-library sync permissions. Enables gating features (e.g., lyrics require Plex Pass, offline sync requires `allowSync`) based on what the account/server/library actually supports.

- New API types: `PlexSubscription`, `PlexServerCapabilities` in `PlexModels.swift`
- New API method: `PlexAPIClient.getServerCapabilities()` (fetches `GET /` root endpoint)
- Extended `PlexAccountConfig` with `subscription: PlexSubscription?`
- Extended `PlexServerConfig` with `capabilities: PlexServerCapabilities?`
- Extended `PlexLibraryConfig` with `allowSync: Bool?`
- Discovery protocol extended with `getServerCapabilities`; discovery flow fetches capabilities per-server alongside library sections
- `ServerSection` ViewModel gains `capabilities` and `hasPlexPass` fields
- `LibraryRow` ViewModel gains `allowSync` field
- New `ServerFeatureBadges` private view in `MusicSourceAccountDetailView.swift` shows capability badges
- Download badge (arrow.down.circle.fill) on library rows when `allowSync` is true

**Key files:** `PlexModels.swift`, `PlexAPIClient.swift`, `PlexAccountDiscoveryService` (discovery protocol), `MusicSourceAccountDetailView.swift`, `PlexAccountConfig`/`PlexServerConfig`/`PlexLibraryConfig` (EnsembleCore models)

---

### Device-Specific Offline Indicator (Mar 18, 2026)

Replaced `ConnectionStatusBanner` (full-width orange bar that pushed content down) with `OfflineIndicatorOverlay` — a subtle, device-aware indicator that uses hardware features to communicate connectivity status without consuming layout space.

- **Dynamic Island devices:** 1.5pt capsule stroke around the DI cutout
- **Notch devices:** Stroke path tracing screen corners and notch outline
- **Classic devices (SE/8):** Solid color fill of the status bar area
- Uses private `_displayCornerRadius` and `_exclusionArea` APIs with fallbacks
- Renders as overlay (no layout shift), hidden in landscape and immersive mode

**Key files:** `OfflineIndicatorOverlay.swift` (new), `MainTabView.swift` (modified), `ConnectionStatusBanner.swift` (deleted)

---

### Artist Flicker + Playlist Stutter + Sync Lag — Run 6/7 (Mar 18, 2026)

**Issue 1 — Artists flickering into different rows (Run 6 + Run 7):**
- **Contributing cause (Run 6):** `sortByCachedKey()` used Swift's unstable `.sorted()`. Added ID tiebreaker across all 3 ViewModels.
- **Contributing cause (Run 6):** `cachedArtistSections` reassigned even when identical. Added `sectionsEqual()` guard to ArtistsView and AlbumsView.
- **Root cause (Run 7 trace):** `applyVisibilityToPublishedCollections()` unconditionally assigned to `@Published artists/albums/tracks/genres` even when content was identical. Each assignment fires `objectWillChange`, causing ALL `@ObservedObject var libraryVM` subscribers to re-evaluate body. On iOS 15, LazyVGrid re-layout during these spurious evaluations causes visible cell rearrangement.
- **Fix (Run 7):** Added `idsEqual()` guard to each assignment in `applyVisibilityToPublishedCollections()`. Only publishes when the ID sequence actually differs.

**Issue 2 — Playlist/Album searchable reveal stutter (Run 6 + Run 7):**
- **Contributing cause (Run 6):** `displayedFilteredPlaylists` computed on every body eval; PlaylistViewModel pipeline had no debounce. Cached as @State; added debounce.
- **Root cause (Run 7 trace):** Both PlaylistsView and AlbumsView wrapped their entire body (including all `.alert`, `.onReceive`, `.toolbar` modifiers) in a `GeometryReader` for cover flow detection. `GeometryReader` re-evaluates its closure on ANY geometry change — including every pixel of `.searchable` bar reveal animation. Each re-eval ran full body with heavy Swift type demangling overhead.
- **Fix (Run 7):** Replaced wrapping `GeometryReader` with lightweight `.background(GeometryReader { ... })` overlay that only updates `@State isCoverFlowActive`. Body now re-evaluates only when orientation actually changes (portrait ↔ landscape).

**Issue 3 — UI lag during sync (Run 6):**
- Added `.removeDuplicates()` to all 4 filtered pipelines in LibraryViewModel. Prevents cascading no-op publishes.

**Key files:** `LibraryViewModel.swift`, `PlaylistViewModel.swift`, `FavoritesViewModel.swift`, `ArtistsView.swift`, `AlbumsView.swift`, `PlaylistsView.swift`

---

### iOS 15 Performance & Stability Fixes (Mar 18, 2026)

**4 bugs fixed from iOS 15 / iPhone 6s log analysis:**

1. **Lyrics 404 on iOS 15:** Increased retries from 2→3 with longer delays (2s, 3s). Added background retry after 10s that updates UI if lyrics arrive late. PMS LyricFind cache expiration is more problematic on iOS 15.
2. **PlaylistPickerSheet search fix (all iOS):** Reverted to `@ObservedObject var nowPlayingVM` + simple `NavigationView { List { ... }.searchable() }` from develop. The `@ObservedObject` → `let` conversion (Run 5) broke `.searchable()` in nested sheet contexts; subsequent NavigationStack/TextField workarounds were unnecessary.
3. **WebSocket continuation leak:** Replaced recursive `CheckedContinuation` + `scheduleReceive()` pattern with `AsyncStream` bridge. Old pattern leaked continuations when `URLSessionWebSocketTask` was cancelled externally (completion handler never fires on iOS 15).
4. **FrequencyAnalysis running when disabled:** `object(forKey:) as? Bool` fails `NSNumber→Bool` bridging on iOS 15, causing `?? true` fallback. Switched to `.bool(forKey:)` + registered defaults at startup.

**Key files:** `PlexAPIClient.swift` (getLyricsContent), `LyricsService.swift` (background retry), `PlaylistActionSheets.swift` (inline TextField), `PlexWebSocketManager.swift` (AsyncStream receive loop), `PlaybackService.swift` (isVisualizerEnabled), `AppDelegate.swift` (register defaults)

---

### Deep Observation + Diffing Optimization — Run 5 (Mar 18, 2026)

**Root cause:** Run 5 trace (100s, iPhone 6s, iOS 15.8.7) showed "Serious" thermal state for entire trace with pervasive CPU pressure causing jank. No individual hangs >250ms, but NVM cascade from MainTabView, remaining @ObservedObject NVM views, and auto-synthesized struct equality caused cumulative CPU waste.

**Phase 1 — MainTabView NVM cascade fix:**
- `nowPlayingVM.currentTrack != nil` read in `.miniPlayerContainerInset()` caused full TabView tree re-evaluation on every NVM @Published change (~28 props fire during playback). Replaced with `@State hasCurrentTrack` + `.onReceive(nowPlayingVM.$currentTrack)`. Body still re-evaluates from @StateObject but produces identical view tree → SwiftUI short-circuits.

**Phase 2 — Remaining @ObservedObject NVM → let (6 views):**
- FavoritesView, MoodTracksView, MediaDetailView, PlaylistPickerSheet, SearchView, TrackSwipeContainer all had `@ObservedObject var nowPlayingVM` causing body re-evaluation on every NVM publish. Converted to `let` with targeted `@State` + `.onReceive` for body-path reads (currentTrackId, lastPlaylistTarget, isPlaylistMutationInProgress). TrackSwipeContainer also converted settingsManager and toastCenter to `let`.

**Phase 3 — Custom Equatable for Album (8 fields) and Playlist (6 fields):**
- Swift's auto-synthesized Equatable compared all 14 Album fields and 12 Playlist fields. Album.__derived_struct_equals consumed 60 profiler samples, Playlist 28. Custom Equatable compares only UI-visible fields (id, title, artistName, etc.), skipping internal fields (key, artPath, dateAdded, dateModified, sourceCompositeKey). Custom hash(into:) uses only id.

**Phase 4 — HomeView/FavoritesView/SearchView singleton removals:**
- Removed @ObservedObject for syncCoordinator and accountManager from HomeView, FavoritesView, SearchView. Only empty/no-results states read these values. Replaced with @State + .onReceive targeting $plexAccounts and $isSyncing.

**Phase 5 — FavoritesViewModel filteredTracks → @Published:**
- `filteredTracks` was a computed property running filter + O(n log n) sort on every body evaluation. Converted to @Published with Combine pipeline: tracks/sortOption/filterOptions changes debounce 100ms then filter+sort on background queue. totalDuration also derived from stored filteredTracks.

**Phase 6 — sortingKey caching via sortByCachedKey():**
- String.sortingKey creates a lowercased copy + 3 hasPrefix checks per call. During sort: 2 calls × O(n log n) comparisons (~4,400 calls for 277 albums). Added `sortByCachedKey()` helper that pre-computes sort keys once (O(n)) then sorts using cached values. Applied to all string-based sort paths in LibraryViewModel, PlaylistViewModel, FavoritesViewModel.

**Key files:** `MainTabView.swift`, `FavoritesView.swift`, `MoodTracksView.swift`, `MediaDetailView.swift`, `PlaylistActionSheets.swift`, `SearchView.swift`, `TrackSwipeContainer.swift`, `HomeView.swift`, `DomainModels.swift`, `FavoritesViewModel.swift`, `LibraryViewModel.swift`, `PlaylistViewModel.swift`

### Observation Blast Radius + Section Caching — Run 4 (Mar 18, 2026)

**Root cause:** Run 4 trace (5 min, iPhone 6s, music playing) showed artists/songs items jumping/disappearing while scrolling, laggy scrolling in playlists/downloads/albums, and album filter keyboard failing. Multiple high-traffic views subscribed to `offlineDownloadService` (5 @Published) and `navigationCoordinator` (14 @Published) via `@ObservedObject`, but only needed 1-2 specific values. ANY @Published change triggered full body re-evaluation of ALL subscribing views.

**Phase 1 — offlineDownloadService/trackAvailabilityResolver `.onReceive`:**
- Replaced `@ObservedObject` with `@State` + `.onReceive` targeting only `activeDownloadRatingKeys` and `availabilityGeneration` in 6 views: SongsView, FavoritesView, SearchView, ArtistDetailView, MediaDetailView, CoverFlowDetailView. Eliminates ~60-80% of spurious re-evals during downloads.

**Phase 2 — navigationCoordinator removal:**
- Removed `@ObservedObject private var navigationCoordinator` from 6 views that only write `showingAddAccount = true` in button closures (never read in body): ArtistsView, SongsView, AlbumsView, PlaylistsView, FavoritesView, SearchView. Use `DependencyContainer.shared.navigationCoordinator` directly in closures instead.

**Phase 3 — Section caching:**
- Replaced `albumSections` and `artistSections` computed properties (Dictionary grouping + map + sorted on every body eval) with `@State` cached values updated via `.onReceive` on `libraryVM.$filteredAlbums`/`$albumSortOption`/`$filteredArtists`. Avoids O(n log n) recomputation with 277 albums / 193 artists.

**Phase 4 — ArtistDetailView + CoverFlowDetailView NVM `.onReceive`:**
- Changed `@ObservedObject var nowPlayingVM` → `let nowPlayingVM` + `@State` + `.onReceive` targeting only `currentTrack` and `lastPlaylistTarget`. NVM has ~25 @Published properties publishing frequently during playback — reduces body re-evals from ~25/s to ~1/track change.

**Key files:** `SongsView.swift`, `FavoritesView.swift`, `SearchView.swift`, `ArtistsView.swift`, `AlbumsView.swift`, `PlaylistsView.swift`, `MediaDetailView.swift`, `CoverFlowDetailView.swift`

### Download CPU Contention + NVM Observation Cascade Fix — Run 3 (Mar 18, 2026)

**Root cause:** Instruments Run 3 trace revealed two remaining issues: (1) download tasks running at default priority competed with UI for CPU on dual-core A9, and (2) eight more views still declared `@ObservedObject var nowPlayingVM` unnecessarily, cascading NVM publishes into full body re-evaluations.

**Phase 1-2 — Download priority & concurrency:**
- Lowered download tasks to `.utility` priority and reduced max concurrent downloads from 3 to 2 in `OfflineDownloadService.swift`. Frees main-thread budget for UI on resource-constrained devices.

**Phase 3 — 8 more `@ObservedObject` → `let` conversions:**
- Converted `@ObservedObject var nowPlayingVM` → `let nowPlayingVM` on DownloadsView, DownloadTargetDetailView, LibraryDownloadDetailView, ArtistDetailLoader, AlbumDetailLoader, PlaylistDetailLoader, PlaylistDetailView, and AlbumDetailView. These views only pass the reference through; child views that need reactivity own their own `@ObservedObject`.

**Phase 4 — MainTabNowPlayingOverlay extraction:**
- Extracted `MainTabNowPlayingOverlay` sub-view from `MainTabView` to isolate NVM-dependent branching (MiniPlayer visibility, now-playing sheet) from the tab bar body. `MainTabView.body` no longer re-evaluates when NVM publishes.

**Key files:** `OfflineDownloadService.swift`, `MainTabView.swift` (+ `MainTabNowPlayingOverlay`), `DownloadsView.swift`, `DownloadTargetDetailView.swift`, `LibraryDownloadDetailView.swift`, `ArtistDetailLoader.swift`, `AlbumDetailLoader.swift`, `PlaylistDetailLoader.swift`, `PlaylistDetailView.swift`, `AlbumDetailView.swift`

### MiniPlayer Observation Storm Fix (Mar 18, 2026)

**Root cause:** `MiniPlayer` declared `@ObservedObject var viewModel: NowPlayingViewModel` (28+ @Published properties). During playback, `currentTimePublisher` fires at 0.5s intervals updating `duration`, `currentLyricsLineIndex`, etc. Each publish triggered full body re-evaluation including `BlurredArtworkBackground` (blur/contrast/saturation), `ArtworkView` init, `LinearGradient` construction, gesture recognizers, and context menu rebuilds. On the dual-core A9 with iOS 15's less efficient SwiftUI diffing, this created a death spiral — 14,212 samples/trace of MiniPlayer.body.getter, causing complete app hangs.

**Phase 1 — MiniPlayer `@ObservedObject` → `let` + scoped sub-views:**
- Changed `@ObservedObject var viewModel` → `let viewModel` on MiniPlayer. Body no longer re-evaluates on NVM publishes.
- Extracted `MiniPlayerTrackInfo` (artwork + text + swipe gesture + error banner), `MiniPlayerControls` (play/pause + next buttons), and `MiniPlayerBackground` (legacy blur/material stack) as private sub-views, each owning their own `@ObservedObject`. Only the relevant slice of UI re-renders.

**Phase 2 — PlaybackProgressBar `@ObservedObject` → `let`:**
- `TimelineView(.periodic(from: .now, by: 0.5))` already drives its own refresh cadence to read `viewModel.progress`. The `@ObservedObject` was redundant and cascaded unnecessary NVM observation re-renders.

**Phase 3 — MiniPlayerContainer `@ObservedObject` → `let`:**
- Container only passes viewModel through to MiniPlayer. No observation needed.

**Key files:** `MiniPlayer.swift`

### Playlist & General Scroll Performance Fix Round 2 (Mar 18, 2026)

**Root cause:** `NowPlayingViewModel` publishes `currentTime` every 0.5s during playback. Six container views (PlaylistsView, HomeView, ArtistsView, AlbumsView, SongsView, MoreView) declared `@ObservedObject var nowPlayingVM` but never read any `@Published` property in their body — they only passed the reference. Every publish triggered full body re-evaluation of ALL tabs, causing playlist stutter on the dual-core A9.

**Phase 1 — Stop nowPlayingVM observation cascade:**
- Changed `@ObservedObject var nowPlayingVM` → `let nowPlayingVM` on all 6 container views. Child views that need reactivity declare their own `@ObservedObject`.

**Phase 2 — Scoped toolbar observation on PlaylistsView:**
- Changed `@ObservedObject` → `let` for `syncCoordinator` and `accountManager` on PlaylistsView (only used in empty state).
- Extracted "New Playlist" button into `PlaylistsNewButton` sub-view that owns the `@ObservedObject syncCoordinator` for the `isOffline` check. Only the button re-renders on sync state changes.

**Phase 3 — Cached filteredPlaylists with Combine pipeline:**
- Replaced computed `sortedPlaylists`/`filteredPlaylists` on `PlaylistViewModel` with a Combine `CombineLatest3` pipeline that caches the result as `@Published`. Sort+filter now only runs when inputs change, not on every body evaluation during scroll.

**Phase 4 — ArtworkView body optimization:**
- Cached `size.cgSize` in a local `let` to avoid 4x `CGSize` recomputation per body call.
- Extracted fallback logic into `usesFallback`, `effectivePath`, `effectiveRatingKey` computed properties, eliminating duplicated nil/empty checks across `loadID`, `loadArtworkURL`, and the invalidation handler.

**Key files:** `PlaylistsView.swift`, `HomeView.swift`, `ArtistsView.swift`, `AlbumsView.swift`, `SongsView.swift`, `MoreView.swift`, `PlaylistViewModel.swift`, `ArtworkView.swift`

### iPhone 6s Albums View Scroll Performance Fix (Mar 18, 2026)

**Phase 1 — Quick wins:**
- **Guard `loadTimeline` behind visualizer setting** — All 5 FFT analysis call sites now check `isVisualizerEnabled` (reads `UserDefaults` directly for thread safety) before dispatching work. Prevents CPU starvation on dual-core A9 when visualizer is disabled (~471ms eliminated).
- **`CDArtist.newestAlbum`** — O(n) `max(by:)` replaces O(n log n) `albumsArray.first` sort for fallback artwork lookup in `Artist(from: CDArtist)` (~418ms eliminated).
- **CoreData prefetching** — `fetchArtists/Albums/Tracks` now set `relationshipKeyPathsForPrefetching` (albums, artist, album+artist respectively) to batch-fault relationships instead of individual SQLite hits.
- **`stalenessInterval = 5.0`** — Replaced `0` (always refetch) with 5s; `automaticallyMergesChangesFromParent` + `refreshContext()` already ensure freshness.

**Phase 2 — Off-main-thread mapping (~3.7s eliminated):**
- **`fetchAndMapInBackground()`** — New `nonisolated static` method on `LibraryViewModel` creates a background `NSManagedObjectContext`, fetches all 4 entity types with prefetching, and maps to domain models. Only final `@Published` assignment happens on `@MainActor`.
- **Batch `FileManager` checks** — `Track(from:downloadedFilenames:)` initializer accepts a pre-computed `Set<String>` from a single `contentsOfDirectory` call instead of 1400+ individual `fileExists` calls.
- **Background sort/filter pipelines** — `setupComputedPipelines()` debounces and computes on a `userInitiated` background queue via `Self.computeQueue`. Results are `receive(on: .main)`.

**Phase 3 — Lazy context menus (~1,068ms eliminated):**
- **Extracted context menu View structs** — `AlbumContextMenu`, `ArtistContextMenu` (AlbumCard.swift, ArtistCard.swift), `SearchAlbumContextMenu`, `SearchArtistContextMenu`, `SearchPlaylistContextMenu` (SearchView.swift).
- **Removed `@ObservedObject pinManager`** from `AlbumGrid`, `ArtistGrid`, and `SearchView`. Pin observation is now scoped per-menu, preventing wholesale grid re-renders.

**Phase 4 — Logging audit:** All `EnsembleLogger` calls in hot paths already behind `#if DEBUG`. No changes needed.

**Key files:** `PlaybackService.swift`, `ManagedObjects.swift`, `ModelMappers.swift`, `LibraryRepository.swift`, `CoreDataStack.swift`, `LibraryViewModel.swift`, `AlbumCard.swift`, `ArtistCard.swift`, `SearchView.swift`

### Playback Hardening & Lock Screen Fixes (Mar 18, 2026)

**Defensive hardening:**
- **`EnsembleLogger.playback()`** — new `.info`-level logger with `"playback"` category, NOT behind `#if DEBUG`. Persists in unified log for post-hoc device diagnostics via `log stream --predicate 'category == "playback"'`.
- **Public log points:** `playbackState` transitions (via `didSet`), track changes in `playCurrentQueueItem`, `handleQueueExhausted` invocations, stall recovery triggers/timeouts, skip commands.
- **Rapid-advance rate limiter:** `handleQueueExhausted` tracks call timestamps; >3 calls in 2s stops playback to prevent cascade.
- **Stuck-playing watchdog:** `resumePlayerFromBuffering` starts a 3s watchdog. If `playbackState == .playing` but `player.timeControlStatus != .playing` after 3s, transitions to `.buffering` and triggers stall recovery.
- **Skip transition safety:** 10s timeout auto-resets `isSkipTransitionInProgress` if stuck.

**Shuffle prefetch fix:** `toggleShuffle()` now calls `clearPrefetchedItems()` + re-prefetch after reshuffling the queue. Previously AVQueuePlayer's internal prefetch kept the pre-shuffle next track, causing gapless transition to play the wrong song.

**Lock screen Now Playing fixes:**
- `next()`/`previous()` now set `playbackState = .loading` BEFORE calling `updateNowPlayingProgress()` so `playbackRate=0.0` is pushed and accepted by `MPNowPlayingInfoCenter` (previously skipped as "identical" because state was still `.playing`).
- New track info (`currentTrack`, `currentTime=0`) is pushed immediately in the skip Task, before `playCurrentQueueItem` runs (saves ~0.5s).

**Download removal safety:**
- `refreshQueueDownloadState()` now evicts cached player items AND cancels in-flight `itemCreationTasks` for ALL non-current tracks with download state changes (previously only handled download completion, not removal).
- After any download state change, `clearPrefetchedItems()` + `prefetchUpcomingItems()` ensures AVQueuePlayer has no stale items referencing deleted local files.
- **Root cause:** Removing downloads for queued tracks left stale `AVPlayerItem`s in AVQueuePlayer pointing to deleted files. Gapless transition to these items corrupted AVPlayer's internal state, causing perpetual buffering of the current track.

**Key files:** `EnsembleLogger.swift`, `PlaybackService.swift`

---

### Progressive Transcode Streaming (Mar 2026)

**Problem:** When PMS transcodes (e.g., FLAC at "low" quality), we downloaded the entire ~5MB file (~8s) before AVPlayer could start. PMS's `start.mp3` returns `Transfer-Encoding: chunked` with no `Content-Length` and `Accept-Ranges: none`, which AVPlayer's CFHTTP stack can't handle (error -16845).

**Solution:** `ProgressiveStreamLoader` (AVAssetResourceLoaderDelegate + URLSessionDataDelegate) bridges PMS's chunked response to AVPlayer. A custom URL scheme (`ensemble-transcode://`) triggers the delegate instead of CFHTTP. Data is written to a growing temp file and served to AVPlayer as it arrives (~1-2s startup).

**Routing strategy (resolveStreamURL):**
- **Original quality + stream key** → direct file URL, no decision call (~<1s startup)
- **Non-original + directplay/copy decision** → direct file URL (~<1s startup)
- **Transcode decision** → progressive stream via ProgressiveStreamLoader (~1-2s startup)

**Fallback:** Tracks that fail with direct stream are tracked in `directStreamFailedKeys` and automatically skip to the full download path. Cleared on connection refresh.

**Types:**
- `StreamResolution` enum: `.directStream(URL)` / `.downloadedFile(URL)` / `.progressiveTranscode(ProgressiveStreamConfig)`
- `ProgressiveStreamConfig`: URLRequest + ratingKey + estimatedContentLength + metadataDuration
- `TranscodeDecisionResult`: parsed decision + part key from PMS

**Post-download processing:** XING header injection + frequency analysis run via `onDownloadComplete` callback when the full file finishes downloading.

**Gapless preservation:** `forwardPlaybackEndTime` set from `track.duration` on all progressive items. Prefetch creates next 2 items concurrently.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/ProgressiveStreamLoader.swift` — AVAssetResourceLoaderDelegate + URLSessionDataDelegate bridge
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` — `resolveStreamURL()`, `buildProgressiveStreamConfig()`, `estimateTranscodeSize()`, `callTranscodeDecision()`
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — `createPlayerItemImpl()` handles `.progressiveTranscode`, `streamLoaders` dict, cleanup in stop/evict/clear
- `Packages/EnsembleCore/Sources/Services/PlexMusicSourceSyncProvider.swift` — returns `StreamResolution` directly
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` — `getStreamURL()` returns `StreamResolution`
- `Packages/EnsembleCore/Sources/Services/MusicSourceSyncProvider.swift` — protocol returns `StreamResolution`

### Offline Artwork Mismatch Fix + Pre-Buffer Race Fix (Mar 2026)

**Artwork mismatch fix:** `ArtworkLoader.artworkURLAsync()` now checks local cache (`ArtworkCache/`) before connectivity checks. All callers (ArtworkView 300px, NowPlayingViewModel 600px) get the same `file://` URL regardless of size, eliminating cache-lottery between independent Nuke data cache entries when offline. `ArtworkView.previousImage` cleared on artwork path change to prevent stale art from previous album.

**Pre-buffer race fix:** `PlaybackService` now tracks the deferred pre-buffer as a `preBufferTask: Task`. When `resume()` is called while pre-buffer is downloading, it awaits the in-progress task instead of starting a redundant ~10s transcode download. Previously, both downloads raced and one was discarded.

**Artwork cleanup on de-sync:** `cleanupRemovedSource()` and `cleanupServerPlaylists()` now collect ratingKeys before deleting CoreData records, then delete cached artwork files via `ArtworkDownloadManager.deleteArtwork(forRatingKeys:)`.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/ArtworkLoader.swift` — local-first artwork URL resolution
- `Packages/EnsembleUI/Sources/Components/ArtworkView.swift` — previousImage + serversBecameAvailable fixes
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` — clear stale artwork on Nuke failure
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — preBufferTask tracking, resume() awaits
- `Packages/EnsembleCore/Sources/Services/SyncCoordinator.swift` — artwork cleanup in cleanupRemovedSource/cleanupServerPlaylists
- `Packages/EnsemblePersistence/Sources/Downloads/ArtworkDownloadManager.swift` — bulk deleteArtwork(forRatingKeys:)

### Cold Launch Startup Optimization (Mar 2026)
Three independent bottleneck fixes. Verified on simulator (iPhone 17 Pro):

**Before:** Restoration complete at T+4.3s, sync starts at T+5.1s.
**After:** Restoration complete at T+0.9s, sync starts at T+0.1s, deferred pre-buffer at T+4.1s.

1. **Deferred stream pre-buffer:** `restoreQueueFromItems()` no longer immediately creates an `AVURLAsset` + `AVPlayerItem` for streaming tracks. The UI only needs track metadata (already restored from QueueItem JSON). Local files still pre-buffer instantly. Streaming tracks schedule a 3s-deferred pre-buffer either from `restoreQueueFromItems` (when server already reachable) or from `handleHealthCheckCompletion()` (when waiting for health checks). `resume()` handles the no-player-item case via `playCurrentQueueItem()`.

2. **Removed 5s unconditional sync delay:** The blanket `Task.sleep(5s)` before startup sync is removed. Normal launches start sync immediately. Siri launches retain a 2s delay for audio session setup. Sync runs at `.utility` priority so it doesn't compete with the Siri audio path.

3. **MainActor task sequencing:** Siri media index rebuild and WebSocket coordinator start now `await earlyHealthCheckTask?.value` before beginning, giving health checks uncontested MainActor time during the critical launch window. Note: `EnsembleApp.swift` scene phase handler also calls `webSocketCoordinator.start()` on `.active`, so WebSocket may start slightly before health checks complete on cold launch via that path — this is acceptable as `start()` does minimal MainActor work.

**Verified simulator timeline (iPhone 17 Pro):**
```
T+0ms      didFinishLaunching
T+108ms    didFinishLaunching returns
T+111ms    Startup sync starts (was T+5111ms)
T+468ms    Health checks start
T+830ms    Health checks complete (0.36s)
T+853ms    restorePlaybackState starts
T+926ms    Restoration complete — paused, NO stream download (was T+4300ms)
T+1722ms   Startup sync complete
T+4119ms   Deferred pre-buffer fires (3s after restore)
T+6096ms   Pre-buffer complete
```

**Key files:**
- `Ensemble/App/AppDelegate.swift` — sync delay removal, MainActor sequencing
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — deferred pre-buffer in `restoreQueueFromItems()` and `handleHealthCheckCompletion()`

### HomePod Siri AirPlay Routing — FIXED (Mar 2026)
Fixed HomePod Siri → Ensemble playback routing to HomePod (previously played on iPhone speaker).

**Root cause:** Both the app and extension declared `INPlayMediaIntent` in their Info.plists. iOS always chose the in-app handler via `INAppIntentDeliverer`, bypassing the Siri extension entirely. The extension returning `.handleInApp` is the signal iOS needs to establish AirPlay routing from HomePod — without the extension in the loop, no routing context existed.

**Fix (3 pieces):**
1. **Removed `INPlayMediaIntent` from app's Info.plist `INIntentsSupported`** — Forces iOS to route through the extension. The extension returns `.handleInApp` which triggers AirPlay route establishment.
2. **In-app handler returns `.success` immediately** — On cold launch, server health checks + playback take 5-8s, exceeding Siri's ~8s timeout. The handler now calls `completion(.success)` immediately and starts playback in the background.
3. **Extension writes Darwin notification fallback** — Belt-and-suspenders: writes payload to App Group and posts Darwin notification before returning `.handleInApp`, in case `UISIntentForwardingAction` delivery fails.

**Flow:** Extension invoked → `.handleInApp` → AirPlay route established → intent forwarded to app → immediate `.success` → background playback starts → audio plays on HomePod.

**Cold launch latency:** ~14s from Siri trigger to audio (10s is app startup overhead). Optimization opportunity: start server health checks during `didFinishLaunching`.

### HomePod Siri Cold Launch Failures — Earlier Fixes (Mar 2026)
Fixed three failure modes when HomePod Siri cold-launches Ensemble:
1. **Session activation denied (error -16980)** — `setActive(true)` called before audio session category configured. Fixed by calling `ensureAudioSessionConfigured()` first.
2. **Playback started on iPhone instead of HomePod** — `setActive(true)` called after route poll. Fixed by activating before polling, extending poll from 6s to 10s.
3. **AirPlay starts but immediately pauses** — `unexpectedPauseCount` carried over from previous track. Fixed by resetting counters at gapless transitions and extending AirPlay settle window to 4s.

Also removed `.allowBluetooth` from audio session options (caused error -12981 on iOS 26).

**Key files:**
- `Ensemble/App/AppDelegate.swift` — `application(handlerFor:)`, `InAppPlayMediaIntentHandler`, `executeSiriPlaybackInBackground`
- `Ensemble/Info.plist` — NO `INIntentsSupported` (only in extension)
- `EnsembleSiriIntentsExtension/PlayMediaIntentHandler.swift` — `handle()` with Darwin fallback
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — `ensureAudioSessionConfigured()`, `nudgeForAirPlayRoute()`

### Crash Fix: Duplicate Hub IDs in HubOrderManager (Mar 2026)
Fixed a P0 crash affecting all users: `HubOrderManager.applyOrder(to:for:)` and `applyDefaultOrder(to:for:)` called `Dictionary(uniqueKeysWithValues:)` which Swift fatally traps on duplicate keys. Duplicate hub IDs entered CoreData via a concurrent-save race: both `HomeViewModel` and `SearchViewModel` call `saveHubs` via detached background Tasks that each do a delete-all + insert in separate CoreData contexts; when they run concurrently, both insert a full hub list → 2× rows with identical IDs in the store. The next launch reads those duplicates, calls `applyOrder`, and crashes immediately (3–4s after launch) with `EXC_BREAKPOINT` / `_assertionFailure`.

**Fixes:**
- `HubOrderManager.applyOrder` and `applyDefaultOrder`: changed `Dictionary(uniqueKeysWithValues:)` to `Dictionary(uniquingKeysWith:)` — crash guard against any future duplicates
- `HubRepository.fetchHubs`: deduplicate by hub ID at read time so existing corrupt CoreData rows no longer reach `applyOrder`
- `HubRepository.saveHubs`: deduplicate input by hub ID before inserting, so the race can no longer write duplicate rows

**Key files:**
- `Packages/EnsembleCore/Sources/Services/HubOrderManager.swift` — `applyOrder`, `applyDefaultOrder`
- `Packages/EnsembleCore/Sources/Services/HubRepository.swift` — `fetchHubs`, `saveHubs`

### Background Playback Pause Bug Fix (Mar 2026)
Fixed an inconsistent bug where a track ending in the background would queue the next track but immediately pause it, requiring the user to press Play from system controls to resume.

**Root cause:** In the gapless transition path (`handleItemChange()`), `unexpectedPauseCount` and `lastUnexpectedPauseAt` were never reset when AVQueuePlayer auto-advanced to the next prefetched item. Stale pause counts from the previous track carried over. At gapless item boundaries, `timeControlStatus` briefly oscillates through `.paused`. If `unexpectedPauseCount` was already >0 from prior network stalls, the boundary pause could push it past the 3-pause loop-detection threshold, triggering the backoff (`playbackState = .buffering` + 5s stall recovery). The non-gapless path was unaffected because `loadAndPlay()` always resets the counter before calling `player?.play()`.

**Fix:** Reset `unexpectedPauseCount = 0` and `lastUnexpectedPauseAt = nil` in `handleItemChange()` when a gapless track transition occurs, mirroring what `loadAndPlay()` already does. Also improved debug logging at the `loadAndPlay()` deferred-start path.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` — `handleItemChange()` counter reset; `loadAndPlay()` improved deferral log

### Low Power Mode Awareness (Mar 2026)
`PowerStateMonitor` observes iOS Low Power Mode and automatically reduces GPU and network work across the app:

- **PowerStateMonitor:** New `@MainActor ObservableObject` that listens for `NSProcessInfoPowerStateDidChange` notifications and publishes `isLowPowerMode: Bool`. Injected via `DependencyContainer`.
- **Aurora visualizer throttling:** When LPM is active, aurora drops to 1 glow pass at 15fps (from 3 passes at 30fps in normal mode). `isLowPowerMode` plumbed through `MainTabView`, `NowPlayingSheetView`, and `NowPlayingCarousel` to `AuroraVisualizationView`.
- **LyricsCard blur disabled:** Progressive blur returns 0 for all lines when LPM is active, eliminating expensive `GaussianBlur` filter applications on the lyrics surface.
- **Download auto-pause:** `DependencyContainer` wiring auto-pauses active downloads when LPM activates and auto-resumes when LPM deactivates.

**Key files:**
- `Packages/EnsembleCore/Sources/Services/PowerStateMonitor.swift` - LPM observer, publishes isLowPowerMode
- `Packages/EnsembleCore/Sources/DI/DependencyContainer.swift` - wires PowerStateMonitor, auto-pauses/resumes downloads
- `Packages/EnsembleUI/Sources/Components/AuroraVisualizationView.swift` - 1 glow pass at 15fps in LPM
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - progressive blur disabled in LPM
- `Packages/EnsembleUI/Sources/Components/NowPlaying/NowPlayingCarousel.swift` - plumbs isLowPowerMode to cards
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift` - plumbs isLowPowerMode to aurora and Now Playing
- `Packages/EnsembleUI/Sources/Screens/NowPlayingSheetView.swift` - plumbs isLowPowerMode to carousel

### App Performance Optimization (Mar 2026)
Multi-phase optimization pass targeting GPU waste, download system queries, SwiftUI invalidation cascades, scroll performance, lyrics rendering, download queue polling, MediaTrackList layout waste, WebSocket event spam, singleton observer cascades, download toast bugs, artwork flashing, large playlist hangs, and queue performance:

- **Aurora visualizer:** Capped at 30fps (was 60fps -- band data already updates at 30fps). Reduced glow passes from 6 to 3 (blur=18, 12, 8). Pauses when Now Playing sheet covers it. Display timer uses `MainActor.assumeIsolated` instead of `Task { @MainActor }`. Identical frequency band publishes are skipped.
- **Download query batching:** After download completion, only owning targets are refreshed (not all). Batch `IN` predicate query replaces per-track `fetchDownload()` loops. Dynamic debounce: 3s when >3 downloads pending, 1s otherwise.
- **PlaybackService objectWillChange:** `frequencyBands` moved from `@Published` to `CurrentValueSubject<[Double], Never>` so `objectWillChange` no longer fires at 30Hz. `NowPlayingViewModel.applyLyricsPosition()` guards against no-change assignments of 4 `@Published` properties.
- **TrackRow availability decoupling:** `@ObservedObject availabilityResolver` (singleton) replaced with `@State private var cachedAvailability` + `.onReceive` that only updates when THIS track's availability changed. Applied to `TrackRow` and `CompactTrackRow`.
- **Songs view layout fix:** Non-indexed sort renders `MediaTrackList` directly without ScrollView wrapper or fixed-height frame (was defeating UITableView cell recycling). Search text filtering debounced at 150ms.
- **LyricsCard line isolation:** Extracted `LyricsLineView` as `Equatable` struct wrapped in `EquatableView`. SwiftUI skips unchanged lines (~2 re-renders per tick instead of N).
- **Download queue polling:** Fixed 1s polling in `PlexAPIClient.downloadTranscodedMediaViaQueue()` replaced with exponential backoff (1s->2s->4s->8s, capped 15s). WebSocket `media.download ended` events now routed through `PlexWebSocketCoordinator` to restart the download queue, fixing a bug where only 1 of N downloads stored.
- **MediaTrackList deferred layout:** `DeferredLayoutTableView` subclass skips `layoutSubviews()` before being in a window, eliminating early layout warnings from eagerly-created navigation destinations.
- **WebSocket settings debounce:** `PlexWebSocketCoordinator` debounces settings-changed events per server (5s window) to coalesce rapid bursts.
- **WebSocket scan progress throttle:** `serverScanProgress` only publishes when progress changes by >=5% (was every ~10ms). Cuts ~95% of scan-related objectWillChange events.
- **MediaTrackList singleton decoupling:** Removed 3 `@ObservedObject` singletons from `MediaTrackList`. Parent views observe once and pass `availabilityGeneration` + `activeDownloadRatingKeys` as value params. Eliminates N*3 subscriptions (26 sections * 3 singletons) in SongsView.
- **activeDownloadRatingKeys batching:** Removed per-track `refreshActiveDownloadRatingKeys()` from `refreshTargetsForTrack()`. The debounced `scheduleDownloadChangeNotification()` (1-3s) already handles it, batching spinner updates.
- **Download toast race fix:** `queueTask` is nil'd before the 500ms grace period re-check, so WebSocket `handleDownloadQueueCompleted()` can restart the queue. Re-checks for pending downloads before showing "Downloads Complete" toast.
- **Downloads view artwork stability:** `DownloadedItemSummary` made `Equatable`; `items` only assigned when values actually differ. Prevents ForEach from re-rendering all rows (and flashing artwork) on progress-only changes.
- **Large playlist layout fix:** `MediaTrackList` gains `managesOwnScrolling: Bool`. Track lists >200 items use self-scrolling UITableView with cell recycling. Removes `.frame(height:)` that forced all 1436 cells to render at once.
- **Queue performance fix:** `QueueTableView` replaced `IntrinsicTableView` with regular `UITableView` (scroll enabled). Removed `ScrollView` wrapper in `QueueCard`. `QueueItemCell` uses `configureGeneration` counter to prevent stale artwork during rearrange.

**Key files:**
- `Packages/EnsembleUI/Sources/Components/AuroraVisualizationView.swift` - 30fps cap, 3 passes, isPaused, state dedup
- `Packages/EnsembleUI/Sources/Screens/MainTabView.swift` - passes isPaused to aurora
- `Packages/EnsembleCore/Sources/Services/AudioAnalyzer.swift` - no-change guard, MainActor.assumeIsolated
- `Packages/EnsembleCore/Sources/Services/OfflineDownloadService.swift` - targeted refresh, dynamic debounce, toast race fix, activeDownloadRatingKeys batching
- `Packages/EnsemblePersistence/Sources/Downloads/DownloadManager.swift` - fetchDownloadsBatch
- `Packages/EnsemblePersistence/Sources/Downloads/OfflineDownloadTargetRepository.swift` - fetchTargetKeys(containing:)
- `Packages/EnsembleCore/Sources/Services/PlaybackService.swift` - CurrentValueSubject for frequencyBands
- `Packages/EnsembleCore/Sources/ViewModels/NowPlayingViewModel.swift` - no-change guard in applyLyricsPosition
- `Packages/EnsembleUI/Sources/Components/TrackRow.swift` - @State cached availability
- `Packages/EnsembleUI/Sources/Components/CompactSearchRows.swift` - @State cached availability
- `Packages/EnsembleUI/Sources/Screens/SongsView.swift` - removed fixed-height frame for unsorted case
- `Packages/EnsembleCore/Sources/ViewModels/LibraryViewModel.swift` - 150ms search debounce
- `Packages/EnsembleUI/Sources/Components/NowPlaying/LyricsCard.swift` - Equatable LyricsLineView
- `Packages/EnsembleAPI/Sources/Client/PlexAPIClient.swift` - exponential backoff for download queue polling
- `Packages/EnsembleCore/Sources/Services/PlexWebSocketCoordinator.swift` - media.download routing, settings debounce, scan progress throttle
- `Packages/EnsembleUI/Sources/Components/MediaTrackList.swift` - DeferredLayoutTableView, managesOwnScrolling, singleton decoupling
- `Packages/EnsembleUI/Sources/Screens/MediaDetailView.swift` - large playlist self-scrolling threshold
- `Packages/EnsembleCore/Sources/ViewModels/DownloadsViewModel.swift` - Equatable diff before assigning items
- `Packages/EnsembleUI/Sources/Components/QueueTableView.swift` - regular UITableView, configureGeneration guard
- `Packages/EnsembleUI/Sources/Components/NowPlaying/QueueCard.swift` - removed ScrollView wrapper

### Live Lyrics (Mar 2026)
Karaoke-style time-synced lyrics fetched from Plex and displayed in the Now Playing Lyrics Card:

- **LRC parser:** `LRCParser` (static) parses LRC-format files into timestamped `LyricsLine` structs. Falls back to plain-text (unsynced) parsing for tracks without timestamps.
- **LyricsService:** @MainActor ObservableObject that runs a three-step fetch pipeline: in-memory cache -> `.lrc` sidecar file -> Plex API. Cache is keyed by `ratingKey:sourceCompositeKey` with ~20-entry LRU eviction.
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

- **Inline libraries section:** Downloads tab shows a "Libraries" section with each sync-enabled library as a rich row (toggle, download stats, drill-in navigation), replacing the previous "Bulk Downloads" -> `Servers` drill-in.
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
- **Account detail:** shows server-grouped libraries (checked + unchecked), per-library sync/connection status, and a single "sync enabled libraries" action.
- **Reconciliation behavior:** newly discovered libraries default unchecked; removed libraries are auto-disabled and purged.
- **Purge semantics:** unchecking a library purges only that library's cache; if the last enabled library for a server is removed/disabled, server-level playlists are purged.
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
- **Action catalog:** `Play Next`, `Play Last`, `Add to Playlist...`, favorite toggle (Loved on/off)
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
