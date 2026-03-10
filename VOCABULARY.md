# Ensemble UI Vocabulary Glossary

This document defines the canonical names for UI elements across the Ensemble app. Use these terms consistently in documentation, code comments, accessibility identifiers, and user-facing copy.

---

## NowPlayingView

- **View name:** `NowPlayingSheetView` (new card-based UI), `NowPlayingView` (legacy)
- **Canonical name:** NowPlayingView
- **Area:** Player
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Architecture

The Now Playing interface uses a **card-based carousel** layout with four swipeable pages:
- **Queue Card** (left): Scrollable queue list with shuffle/repeat/autoplay controls
- **Controls Card** (center-left, default): Primary playback controls and track metadata
- **Lyrics Card** (center-right): Karaoke-style time-synced lyrics display; shows loading spinner, "No Lyrics" state, or scrolling highlighted lines
- **Info Card** (right): Track metadata and streaming/connection details

On iPad/Mac (>768pt width), the layout switches to **side-by-side**: Controls on left, Lyrics/Queue carousel on right.

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Background gradient | region | Vibrant blurred artwork background with legibility overlay (30% dark, 50% light) | `backgroundView`, `BlurredArtworkBackground` |
| Dismiss pill | control | Capsule-shaped indicator at top for vertical swipe dismissal | `dismissPill` |
| Horizontal carousel | region | TabView-based page navigation between Lyrics/Controls/Queue | `NowPlayingCarousel` |
| Page indicator | indicator | Three-dot indicator showing current page (left/center/right icons) | `PageIndicator` |

#### Lyrics Card (Left)

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Lyrics header | text | "Lyrics" title pinned at top | `headerView` |
| Lyrics content area | region | Scrollable list with top/bottom fade masks | `contentView` |
| Loading state | state | Spinner shown while LyricsService fetches lyrics | `LyricsState.loading` |
| Not available state | state | Centered "No Lyrics" message with music note icon when track has no lyrics stream or fetch fails | `LyricsState.notAvailable` |
| Lyrics line | text | Individual lyric line; active line is full-opacity and larger, past/future lines are dimmed | `LyricsLine`, `currentLyricsLineIndex` |
| Active line highlight | indicator | The current line scrolled to center of the card and rendered at full opacity | `currentLyricsLineIndex` |

#### Controls Card (Center)

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Album artwork | artwork | Large centered artwork (capped at 400pt, max 40% height) | `ArtworkView`, `artworkSize` |
| Track metadata region | region | Title, artist, and album with navigation buttons | `trackMetadataView` |
| Track title | text | Scrolling marquee text showing current track name | `MarqueeText`, `track.title` |
| Artist button | control | Clickable artist name that navigates to artist detail | `track.artistName` |
| Album button | control | Clickable album name that navigates to album detail | `track.albumName` |
| Playback scrubber | control | Interactive waveform progress with vertical drag scrub rate | `progressView`, `WaveformView` |
| Elapsed time label | text | Current playback position timestamp (left side) | `formattedCurrentTime` |
| Remaining time label | text | Time remaining until track ends (right side, negative) | `formattedRemainingTime` |
| Scrub speed indicator | indicator | Shows scrubbing rate (Hi-Speed/Half/Quarter/Fine) | `scrubIndicator` |
| Previous button | control | Tap for previous track, long-press (300ms) for rewind seek | `backward.fill` |
| Play/Pause button | control | Primary playback toggle with loading spinner state | `play.circle.fill`, `pause.circle.fill` |
| Next button | control | Tap for next track, long-press (300ms) for fast-forward seek | `forward.fill` |
| Primary controls region | region | Main playback controls row (prev, play/pause, next) | `controlsView` |
| AirPlay button | control | System AirPlay route picker | `AirPlayButton` |
| Favorite button | control | Heart icon for loved/not loved toggle (accent when active) | `heart.fill`, `heart` |
| Add to playlist button | control | Plus icon for playlist picker sheet | `plus.circle` |
| More actions menu | menu | Overflow menu with playlist quick-add action | `ellipsis.circle` |
| Secondary controls region | region | Row with AirPlay, favorite, playlist, more | `secondaryControlsView` |
| Page indicator | indicator | Below secondary controls on Controls card | `PageIndicator` |

#### Queue Card (Right)

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Queue header | region | "Queue"/"History" title with history toggle and tertiary menu | `headerView` |
| History toggle | control | Switch between upcoming queue and playback history | `clock.arrow.circlepath` |
| Tertiary actions menu | menu | Three-dot menu with "Save Queue as Playlist" action | `ellipsis.circle` |
| Queue list | region | Scrollable track list with fade masks (5% top, 15% bottom) | `queueListView`, `QueueTableView` |
| Queue track cell | control | Swipeable cell with artwork, title, artist, duration | `QueueItemCell` |
| Playing indicator | indicator | Speaker icon on currently playing track | `speaker.wave.3.fill` |
| Autoplay indicator | indicator | Sparkles icon on auto-recommended tracks | `sparkles` |
| Drag handle | control | Three-line icon for reorder drag gesture | `line.3.horizontal` |
| Empty queue state | state | Centered icon + "Queue is empty" message | empty state |
| Recommendations exhausted | indicator | "End of recommendations" text when autoplay depleted | `recommendationsExhausted` |
| Shuffle button | control | Toggle shuffle mode (accent when active) | `shuffle` |
| Repeat button | control | Cycle repeat mode (off/all/one, accent when active) | `repeat`, `repeat.1` |
| Autoplay button | control | Toggle autoplay with cross-through when offline | `play.circle.fill`, `play.circle` |
| Secondary controls region | region | Bottom row with shuffle/repeat/autoplay | `secondaryControlsView` |
| Page indicator | indicator | Below secondary controls on Queue card | `PageIndicator` |

#### Info Card (Far Right)

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Info header | text | "Info" title pinned at top | `headerView` |
| Track metadata section | region | Album, artist, year, track/disc, duration, plays, date added | `trackMetadataSection` |
| Album row | control | Tappable row navigating to album detail | `handleAlbumTap` |
| Artist row | control | Tappable row navigating to artist detail | `handleArtistTap` |
| Year row | text | Album release year (from fetched album metadata) | `fetchedAlbum?.year` |
| Track/Disc row | text | Track number and disc number (if multi-disc) | `formatTrackDiscInfo` |
| Duration row | text | Track duration in mm:ss format | `track.formattedDuration` |
| Plays row | text | Play count for the track | `track.playCount` |
| Added row | text | Date track was added to library | `track.dateAdded` |
| Section divider | indicator | Visual separator between metadata and streaming sections | `Divider()` |
| Streaming header | text | "Streaming" section header | |
| Playback Quality row | text | Effective playback quality and format (`Downloaded` uses file token/container; `Streaming` uses selected streaming quality) | `resolvePlaybackQuality()` |
| Source row | text | Playback source indicator (`Downloaded` vs `Streaming`) | `resolvePlaybackSource()` |
| Server row | text | Name of the connected Plex server | `resolveServerName()` |
| Connection row | text | Connection URL with type (Local/Remote/Relay) | `resolveConnectionInfo()` |
| Status row | indicator | Connection status with colored dot | `resolveConnectionStatus()` |
| Network row | text | Current network type (Wi-Fi, Cellular, etc.) | `networkMonitor.networkState` |

### States & Overlays

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Error overlay | indicator | Modal error display with retry when playback fails | `errorOverlayView` |
| Loading state | state | Spinner shown during buffering/loading | `playbackState == .loading` |
| Buffering state | state | Progress indicator during stream buffering | `playbackState == .buffering` |

---

## HomeView

- **View name:** `HomeView`
- **Canonical name:** HomeView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Hub scroll region | region | Vertical scroll container for all hub sections | `hubsScrollView` |
| Hub section | region | Individual content hub with title and horizontal scroll | `HubSection` |
| Hub section title | text | Bold title for each hub (e.g., "Recently Added") | `hub.title` |
| Hub item card | control | Tappable card showing album/artist/track/playlist artwork and info | `HubItemCard` |
| Hub item artwork | artwork | Square artwork thumbnail for hub items (140x140) | `ArtworkView` |
| Hub item title | text | Primary title text on hub cards | `item.title` |
| Hub item subtitle | text | Secondary text (artist name, year) on hub cards | `item.subtitle` |
| Edit button | control | Toolbar button to enter hub ordering edit mode | `enterEditMode` |
| Hub ordering sheet | menu | Modal sheet to reorder and toggle hub visibility | `HubOrderingSheet` |
| Loading state | state | Spinner with "Loading..." text during initial load | `loadingView` |
| Empty state | state | Welcome message with action prompts when no content | `emptyView` |
| No sources message | indicator | Text shown when no music sources are connected | `hasConfiguredAccounts` |
| Add source button | action | Button to trigger add source flow | `Add Source` |
| Manage sources button | action | Button to open settings for library management | `Manage Sources` |
| Sync in progress indicator | indicator | Spinner with "Sync in progress..." text | `syncCoordinator.isSyncing` |
| Refresh action | gesture | Pull-to-refresh gesture to reload hub content | `.refreshable` |

---

## MainTabView

- **View name:** `MainTabView`
- **Canonical name:** MainTabView
- **Area:** Shared
- **Platform:** iOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Tab bar | region | Bottom navigation bar with up to 5 tabs | `TabView` |
| Tab item | control | Individual tab button with icon and label | `tabItem`, `Label` |
| More tab | control | Fifth tab that opens overflow menu | `ellipsis`, `MoreView` |
| Connection status banner | indicator | Top banner showing network/server connection status | `ConnectionStatusBanner` |
| Mini player | control | Floating persistent player widget above tab bar | `MiniPlayer` |
| Tab selection | state | Currently active tab | `navigationCoordinator.selectedTab` |
| Immersive mode | state | Hidden chrome state for cover flow views | `isImmersiveMode` |

---

## SidebarView

- **View name:** `SidebarView`
- **Canonical name:** SidebarView
- **Area:** Shared
- **Platform:** iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Sidebar | region | Left navigation column with section list | `NavigationSplitView`, `List` |
| Library section | region | Grouped section for library navigation items | `Section("Library")` |
| Pins section | region | Grouped section for user-pinned items | `Section("Pins")` |
| Other section | region | Grouped section for search/downloads/settings | `Section("Other")` |
| Sidebar item | control | Row with icon and label for navigation | `Label` |
| Detail area | region | Main content area showing selected section | `detailView` |
| Mini player | control | Bottom-aligned persistent player widget | `MiniPlayer` |
| Sidebar selection | state | Currently selected sidebar section | `selection: SidebarSection` |

---

## SearchView

- **View name:** `SearchView`
- **Canonical name:** SearchView
- **Area:** Search
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Search field | control | Text input for filtering/searching library content | `.searchable`, `searchQuery` |
| Explore view | region | Content shown when search field is empty (pins, moods) | `exploreView` |
| Pins section | region | Expandable/collapsible pinned items area | `isPinnedExpanded` |
| Pins header | control | "Pins" title with expand/collapse chevron | `chevron.up`, `chevron.down` |
| Pin item | control | Pinned album/artist/playlist card | `resolvedPins` |
| Edit pins button | control | Toggle edit mode for reordering/removing pins | `isEditingPins` |
| Moods section | region | Grid of mood-based genre shortcuts | `Moods` |
| Mood card | control | Tappable card linking to mood-filtered tracks | `MoodTracksView` |
| Search results region | region | Container for filtered search results | `resultsList` |
| Artists results section | region | Horizontally scrolling artist results | `Artists` |
| Albums results section | region | Horizontally scrolling album results | `Albums` |
| Playlists results section | region | Horizontally scrolling playlist results | `Playlists` |
| Songs results section | region | Vertical list of matching tracks | `Songs` |
| Compact artist row | control | Condensed artist result with artwork | `CompactArtistRow` |
| Compact album row | control | Condensed album result with artwork | `CompactAlbumRow` |
| Compact playlist row | control | Condensed playlist result with artwork | `CompactPlaylistRow` |
| Search result context menu | menu | Long-press menu for album/artist/playlist result actions | `albumContextMenu`, `artistContextMenu`, `playlistSearchContextMenu` |
| Download action | action | Toggle offline target for album/artist/playlist from result menus | `Download`, `Remove Download` |
| Empty state | state | Message when no results match query | (needs confirmation) |
| No sources message | indicator | Prompt to connect music sources | `hasAnySources` |

---

## SongsView

- **View name:** `SongsView`
- **Canonical name:** SongsView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Track list | list | Main scrollable list of all songs | `trackListView`, `MediaTrackList` |
| Section header | text | Alphabetical section divider (A, B, C...) | `sectionHeader` |
| Track row | control | Individual song row with artwork, title, artist, duration | `TrackRow` |
| Filter button | control | Toolbar button to open filter sheet (with badge) | `line.3.horizontal.decrease.circle` |
| Filter badge | indicator | Red dot showing active filters | `hasActiveFilters` |
| Sort menu | menu | Overflow menu with sort options and actions | `ellipsis.circle` |
| Shuffle all action | action | Menu item to shuffle play entire library | `Shuffle All` |
| Play all action | action | Menu item to play library in order | `Play All` |
| Scroll index | control | Right-edge alphabetical jump index | `ScrollIndex` |
| Cover flow view | region | Landscape-only 3D album browsing mode | `CoverFlowView` |
| Loading state | state | Spinner during initial song load | `loadingView` |
| Empty state | state | Message when no songs available | `emptyView` |

---

## AlbumsView

- **View name:** `AlbumsView`
- **Canonical name:** AlbumsView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Album grid | list | Grid layout of album cards | `AlbumGrid`, `albumGridView` |
| Album card | control | Album artwork with title and artist | `AlbumCard` |
| Section header | text | Alphabetical section divider | `sectionHeader` |
| Filter button | control | Toolbar button to open filter sheet | `line.3.horizontal.decrease.circle` |
| Filter badge | indicator | Red dot showing active filters | `hasActiveFilters` |
| Sort menu | menu | Menu with sort options (title, artist, year, etc.) | `arrow.up.arrow.down` |
| Scroll index | control | Right-edge alphabetical jump index | `ScrollIndex` |
| Cover flow view | region | Landscape-only 3D album browsing mode | `CoverFlowView` |
| Loading state | state | Spinner during initial album load | `loadingView` |
| Empty state | state | Message when no albums available | `emptyView` |

---

## AlbumDetailView

- **View name:** `AlbumDetailView`
- **Canonical name:** AlbumDetailView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Album header | region | Top area with artwork, title, artist, metadata | `MediaHeaderData` |
| Album artwork | artwork | Large album cover image | `artworkPath` |
| Album title | text | Album name heading | `album.title` |
| Artist name | text | Album artist with navigation link | `album.artistName` |
| Metadata line | text | Year, track count, total duration | `metadataLine` |
| Track list | list | Ordered list of album tracks | `MediaDetailView` |
| Disc grouping | region | Tracks grouped by disc number for multi-disc albums | `groupByDisc: true` |
| Track number | text | Track position within album/disc | `showTrackNumbers: true` |
| Pin menu | menu | Actions menu with pin/unpin and queue options | (needs confirmation) |
| Play next action | action | Add album tracks to front of queue | `onPlayNext` |
| Play last action | action | Add album tracks to end of queue | `onPlayLast` |

---

## MediaDetailView

- **View name:** `MediaDetailView`
- **Canonical name:** MediaDetailView
- **Area:** Library (shared)
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

Generic detail view used by Album, Playlist, Artist, and Favorites. Parameterized by `MediaDetailViewModelProtocol`.

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Header | region | Artwork, title, subtitle, metadata line | `headerView`, `MediaHeaderData` |
| Collapsing toolbar title | control | Title appears in toolbar when header scrolls out of view | `CollapsingToolbarTitleModifier`, `showToolbarTitle` |
| Sticky action buttons | region | Play/Shuffle/Radio buttons that pin when scrolled past | `stickyActionButtons`, `LazyVStack(pinnedViews:)` |
| Action buttons | region | Play, Shuffle, and optional Radio buttons | `actionButtons` |
| Track list | list | Ordered track list (UIKit-backed on iOS for swipe actions) | `tracksSection`, `MediaTrackList` |
| Background gradient | region | Blurred artwork background fading to content | `backgroundGradient`, `BlurredArtworkBackground` |
| Pin menu | menu | Toolbar overflow with pin/unpin, download, playlist actions | `pinMenuButton` |

---

## ArtistsView

- **View name:** `ArtistsView`
- **Canonical name:** ArtistsView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Artist grid | list | Grid layout of artist cards | `ArtistGrid`, `artistListView` |
| Artist card | control | Circular artist photo with name | `ArtistCard` |
| Section header | text | Alphabetical section divider | `sectionHeader` |
| Filter button | control | Toolbar button to open filter sheet | `line.3.horizontal.decrease.circle` |
| Sort menu | menu | Menu with sort options | `arrow.up.arrow.down` |
| Scroll index | control | Right-edge alphabetical jump index | `ScrollIndex` |
| Loading state | state | Spinner during initial artist load | `loadingView` |
| Empty state | state | Message when no artists available | `emptyView` |

---

## ArtistDetailView

- **View name:** `ArtistDetailView`
- **Canonical name:** ArtistDetailView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Background gradient | region | Blurred artwork background fading to content | `backgroundGradient`, `BlurredArtworkBackground` |
| Hero banner | region | Full-width artist photo with overlay info | `heroBanner` |
| Artist name | text | Large artist name heading | `viewModel.artist.name` |
| Statistics line | text | Album and song counts | `"X albums - Y songs"` |
| Play button | action | Play all artist tracks in order | `Play`, `play.fill` |
| Shuffle button | action | Shuffle play all artist tracks | `Shuffle`, `shuffle` |
| Radio button | action | Start artist radio with autoplay | `dot.radiowaves.left.and.right` |
| Primary actions region | region | Row containing play, shuffle, radio buttons | `actionButtons` |
| Albums section | region | Grid of artist's albums | `albumsSection`, `AlbumGrid` |
| Favorited tracks section | region | List of 4+ star rated tracks by this artist | `favoritedTracksSection` |
| Bio section | region | Expandable artist biography text | `bioSection` |
| Read more button | control | Expand truncated bio text | `isBioExpanded` |
| Pin menu | menu | Toolbar overflow menu with pin/unpin action | `artistPinMenuButton` |
| Artist download action | action | Toggle artist offline target from toolbar menu | `Download`, `Remove Download` |
| Collapsing toolbar title | control | Artist name appears in toolbar when hero banner scrolls out of view | `CollapsingToolbarTitleModifier`, `showToolbarTitle` |

---

## PlaylistsView

- **View name:** `PlaylistsView`
- **Canonical name:** PlaylistsView
- **Area:** Playlists
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Playlist list | list | Scrollable list of all playlists | `playlistListView` |
| Playlist row | control | Playlist item with artwork, title, track count | `PlaylistRow` |
| New playlist button | control | Toolbar button to create new playlist | `plus` |
| Sort menu | menu | Menu with sort options (title, date, track count) | `arrow.up.arrow.down` |
| Create playlist dialog | menu | Alert with text field for new playlist name | `showCreatePlaylistPrompt` |
| Server picker dialog | menu | Confirmation dialog to choose server for new playlist | `showCreateServerPicker` |
| Delete confirmation dialog | menu | Alert confirming playlist deletion | `Delete Playlist?` |
| Rename dialog | menu | Alert with text field to rename playlist | `Rename Playlist` |
| Playlist context menu | menu | Long-press menu with play, shuffle, pin, edit, delete | `playlistContextMenu` |
| Playlist download action | action | Toggle playlist offline target from context menu | `Download`, `Remove Download` |
| Delete swipe action | gesture | Swipe-to-delete for non-smart playlists | `standardDeleteSwipeAction` |
| Cover flow view | region | Landscape-only 3D playlist browsing mode | `CoverFlowView` |
| Loading state | state | Spinner during initial playlist load | `loadingView` |
| Empty state | state | Message when no playlists available | `emptyView` |
| Creating indicator | indicator | Toast showing playlist creation in progress | `Creating...` |

---

## PlaylistDetailView

- **View name:** `PlaylistDetailView`
- **Canonical name:** PlaylistDetailView
- **Area:** Playlists
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Playlist header | region | Top area with artwork, title, metadata | `MediaHeaderData` |
| Playlist artwork | artwork | Composite or single artwork image | `compositePath` |
| Playlist title | text | Playlist name heading | `playlist.title` |
| Smart playlist badge | indicator | "Smart Playlist" label for auto-generated playlists | `isSmart` |
| Track count and duration | text | Track count and total duration text | `metadataLine` |
| Track list | list | Ordered list of playlist tracks | `MediaDetailView` |
| Edit mode | state | Drag-to-reorder and delete mode for tracks | `isEditingPlaylist` |
| Edit track list | list | Editable list with drag handles and delete buttons | `inlinePlaylistEditor` |
| Save button | control | Toolbar button to save playlist edits | `Save` |
| Cancel button | control | Toolbar button to discard playlist edits | `Cancel` |
| Rename action | action | Opens rename dialog | `Rename...` |
| Edit playlist action | action | Enters edit mode | `Edit Playlist` |
| Delete action | action | Opens delete confirmation | `Delete Playlist` |
| Play next action | action | Add all tracks to front of queue | `onPlayNext` |
| Play last action | action | Add all tracks to end of queue | `onPlayLast` |

---

## GenresView

- **View name:** `GenresView`
- **Canonical name:** GenresView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Genre list | list | Scrollable list of all genres | `genreListView` |
| Genre row | control | Row with guitar icon and genre name | `genre.title` |
| Genre icon | artwork | Guitar icon for each genre | `guitars.fill` |
| Loading state | state | Spinner during initial genre load | `loadingView` |
| Empty state | state | Message when no genres available | `emptyView` |

---

## FavoritesView

- **View name:** `FavoritesView`
- **Canonical name:** FavoritesView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Favorites header | region | Top area with heart icon, title, statistics | header |
| Heart icon | artwork | Large red heart symbol | `heart.fill` |
| Track count and duration | text | Number of favorites and total duration | `filteredTracks.count`, `totalDuration` |
| Play button | action | Play all favorites in order | `Play`, `play.fill` |
| Shuffle button | action | Shuffle play all favorites | `Shuffle`, `shuffle` |
| Primary actions region | region | Row with play and shuffle buttons | action buttons |
| Track list | list | List of favorited tracks (4+ stars) | `trackListView` |
| Filter button | control | Toolbar button to open filter sheet | `line.3.horizontal.decrease.circle` |
| Empty state | state | Message when no favorites yet | `emptyView` |
| Empty state hint | text | Instructions to rate tracks 4-5 stars | `"Rate tracks 4 or 5 stars..."` |

---

## DownloadsView

- **View name:** `DownloadsView`
- **Canonical name:** DownloadsView
- **Area:** Library
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Libraries section | region | Section showing each sync-enabled library with toggle, download stats, and drill-in | `Section("Libraries")` |
| Library row | control | Row with library icon, server:library title, track counts, size estimates, toggle, and navigation to LibraryDownloadDetailView | `libraryRow(for:)` |
| Library toggle | control | Inline toggle to enable/disable library-wide offline download | `Toggle`, `setLibraryEnabled()` |
| Items section | region | Section listing non-library offline targets (playlist/album/artist) | `Section("Items")` |
| Downloaded item row | control | Offline target row with kind icon, title, status, counts, and size | `DownloadedItemRow` |
| Item metadata label | text | Track count summary and downloaded storage for the target | `metadataText` |
| Item progress bar | indicator | Linear progress for targets that are not complete | `ProgressView(.linear)` |
| Item detail navigation | action | Opens album/artist/playlist detail when target has valid ID | `destinationView(for:)` |
| Remove target swipe action | gesture | Swipe-to-remove offline target | `standardDeleteSwipeAction` |
| Manage downloads settings button | control | Toolbar button opening Manage Downloads quality controls | `slider.horizontal.3`, `DownloadManagerSettingsView` |
| Update quality action | action | Toolbar action that requeues completed downloads whose stored quality differs from Settings > Audio Quality > Download Quality; shows warning when server only supports original offline quality | `arrow.triangle.2.circlepath`, `refreshCompletedDownloadsForCurrentQuality()` |
| Loading state | state | Overlay spinner while loading first target snapshot | `loadingOverlay` |
| Empty state | state | Inline message when no playlist/album/artist targets exist | `No offline items selected` |

---

## SettingsView

- **View name:** `SettingsView`
- **Canonical name:** SettingsView
- **Area:** Settings
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Music sources section | region | Section listing connected accounts | `Section("Music Sources")` |
| Music source row | control | Row showing source type and account identifier | `MusicSourceAccountRow` |
| Add account button | control | Button to start add account flow | `Add Plex Account` |
| Accent color section | region | Section with color picker | `Section("Accent Color")` |
| Color option | control | Tappable color circle for accent selection | `Circle()` |
| Playback section | region | Section with playback-related settings | `Section("Playback")` |
| Autoplay toggle | control | Switch to enable/disable autoplay | `Toggle`, `isAutoplayEnabled` |
| Audio quality link | control | Navigation to audio quality settings | `Audio Quality` |
| Connection security link | control | Navigation to connection policy settings | `Connection Security` |
| Track swipe actions link | control | Navigation to swipe action customization | `Track Swipe Actions` |
| Storage section | region | Section with storage management | `Section("Storage")` |
| Clear all data button | action | Destructive button to clear library data | `Clear All Library Data` |
| Reset section | region | Section with account reset options | `Section("Reset")` |
| Remove all accounts button | action | Destructive button to remove all accounts | `Remove All Accounts` |
| About section | region | Section with app info | `Section("About")` |
| Version info | text | App version and build number | `appVersion` |
| Help & support link | control | External link to support website | `Help & Support` |
| Remove account dialog | menu | Confirmation alert for account removal | `Remove Account` |
| Clear data dialog | menu | Confirmation alert for clearing library data | `Clear All Library Data` |

---

## MusicSourceAccountDetailView

- **View name:** `MusicSourceAccountDetailView`
- **Canonical name:** MusicSourceAccountDetailView
- **Area:** Settings
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Server section | region | Section per server with library checkboxes and status | `Section(server.name)` |
| Library checkbox row | control | Toggle to enable/disable library sync | `libraryRow(library:server:)` |
| Library status indicator | indicator | Per-library sync status text (e.g., "Synced", "Offline") | `libraryStatusText` |
| Scan progress bar | indicator | Linear progress bar showing real-time library scan progress (0-100%) from WebSocket activity events | `ProgressView(value:total:)`, `scanProgressByServer` |
| Scan progress label | text | "Scanning library..." text with magnifying glass icon | `magnifyingglass` |
| Sync button | action | Triggers sync for all enabled libraries on this account | `Sync Enabled Libraries` |
| Reconcile button | action | Re-discovers servers/libraries from Plex API | `Reconcile` |
| Remove account button | action | Destructive button to remove the account | `Remove Account` |

---

## DownloadManagerSettingsView

- **View name:** `DownloadManagerSettingsView`
- **Canonical name:** DownloadManagerSettingsView
- **Area:** Downloads
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Downloads section | region | Section that mirrors Settings > Audio Quality > Download Quality | `Section("Downloads")` |
| Download quality selector | control | Menu picker for Original/High/Medium/Low quality | `Picker("Download Quality", selection: $downloadQuality)` |
| Download quality footer | text | Clarifies this control matches Audio Quality settings | `This matches Settings > Audio Quality > Download Quality.` |
| Cellular download toggle | control | Toggle to allow/disallow downloads over cellular data | `Toggle("Allow Downloading on Cellular")`, `allowCellularDownloads` |

---

## LibraryDownloadDetailView

- **View name:** `LibraryDownloadDetailView`
- **Canonical name:** LibraryDownloadDetailView
- **Area:** Downloads
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Library icon header | visual | Generic library icon with accent color gradient background | `building.columns` |
| Header subtitle | text | Track count and downloaded size summary | `headerSubtitle` |
| Progress bar | indicator | Linear progress bar shown when not all tracks are complete | `ProgressView(.linear)` |
| Play button | control | Plays all completed downloaded tracks | `nowPlayingVM.play(tracks:)` |
| Shuffle button | control | Shuffles all completed downloaded tracks | `nowPlayingVM.shufflePlay(tracks:)` |
| Track download row | control | Per-track row with artwork, title, status chip, retry | `TrackDownloadRowView` |
| Queue status banner | indicator | Banner when downloads are paused due to network | `queueStatusBanner` |
| Retry all button | control | Toolbar button to retry all failed downloads | `retryAllButton` |

---

## OfflineServersView

- **View name:** `OfflineServersView`
- **Canonical name:** OfflineServersView
- **Area:** Settings
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Server section | region | Section per server with account subtitle | `OfflineServerSection` |
| Library toggle row | control | Toggle enabling/disabling library-wide offline target | `Toggle`, `setLibraryEnabled` |
| Library source key label | text | Secondary source identifier label below library title | `library.sourceCompositeKey` |
| Empty state | state | Message shown when no libraries are sync-enabled | `No enabled libraries` |

---

## PendingMutationsView

- **View name:** `PendingMutationsView`
- **Canonical name:** PendingMutationsView
- **Area:** Downloads
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Architecture

A screen accessible from DownloadsView that displays pending and failed offline mutations (track ratings/loves, playlist adds) that could not be synced to the server. Provides retry and delete actions for each mutation.

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Title | text | Screen title | `Pending Mutations` |
| Pending mutations section | region | Section listing mutations awaiting sync | `Section("Pending")` |
| Failed mutations section | region | Section listing mutations that failed to sync | `Section("Failed")` |
| Mutation item row | control | Row showing mutation type, target (track/playlist name), and timestamp | `PendingMutationRow` |
| Mutation metadata label | text | Displays mutation type (e.g., "Marked as Loved", "Added to Playlist") and timestamp | `mutationDescription`, `formattedTimestamp` |
| Retry button | action | Attempts to sync mutation to server | `retry()`, `attemptSyncMutation()` |
| Delete button | action | Removes mutation from local queue without syncing | `delete()`, `removeMutation()` |
| Mutation detail disclosure | action | Optional expansion to show mutation details (track info, playlist name, error message) | `DisclosureGroup` |
| Offline state overlay | state | Dimmed overlay with message when device is offline | `Offline - mutations will sync when connection resumes` |
| Empty state | state | Inline message when no pending or failed mutations exist | `All mutations synced` |
| Loading state | state | Overlay spinner while loading mutations list | `loadingOverlay` |

---

## AddPlexAccountView

- **View name:** `AddPlexAccountView`
- **Canonical name:** AddPlexAccountView
- **Area:** Settings
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| App icon | artwork | Music note house icon at top | `music.note.house.fill` |
| Title | text | "Add Plex Account" heading | |
| Sign in button | action | Primary button to start Plex OAuth flow | `Sign in with Plex` |
| PIN code display | text | Large 4-character authorization code | `code`, `font(.monospaced)` |
| Copy PIN button | control | Tappable area to copy PIN to clipboard | `Tap to copy` |
| Open plex.tv link | action | External link to plex.tv/link | `Open plex.tv/link` |
| Waiting indicator | indicator | Progress spinner while polling for auth | `Waiting for authorization...` |
| Cancel auth button | action | Button to cancel ongoing auth | `Cancel` |
| Server selection region | region | List of discovered servers with libraries | `serverLibrarySelectionView` |
| Server row | control | Server name with platform info | `ServerRow` |
| Library selection row | control | Checkbox row for library enable/disable | `LibrarySelectionRow` |
| Server error message | indicator | Error text for server connection failures | `serverLibraryErrors` |
| Add account button | action | Confirm button to save selected libraries | `Add Account` |
| Error message | indicator | Red error text for auth failures | `viewModel.error` |
| Loading state | state | Spinner during server/library discovery | `isLoading` |

---

## MoreView

- **View name:** `MoreView`
- **Canonical name:** MoreView
- **Area:** Shared
- **Platform:** iOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Library section | region | Grouped library navigation items | `Section("Library")` |
| Other section | region | Grouped utility items (downloads, settings) | `Section("Other")` |
| Navigation row | control | Row linking to a view not in tab bar | `NavigationLink` |
| Edit button | control | Toolbar button to enter tab customization mode | `Edit` |
| Done button | control | Toolbar button to exit edit mode | `Done` |
| Tab bar items section | region | Draggable section of current tab bar items (edit mode) | `EditTabsView`, `tabBarSection` |
| Available items section | region | Draggable section of items not in tab bar (edit mode) | `availableSection` |
| Drag handle | control | Reorder handle for tab items | `line.3.horizontal` |
| Instructions text | text | Help text explaining tab customization | |
| Tab bar drop delegate | behavior | Accepts drops to add/reorder items in tab bar, bumps last if at 4 | `TabBarDropDelegate` |
| Available drop delegate | behavior | Accepts drops from tab bar to remove (min 1 enforced) | `AvailableDropDelegate` |

---

## MiniPlayer

- **View name:** `MiniPlayer`
- **Canonical name:** MiniPlayer
- **Area:** Player
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Glass background | region | Blurred artwork with ultra-thin material overlay | `BlurredArtworkBackground`, `.ultraThinMaterial` |
| Track artwork | artwork | Small thumbnail of current track (36x36) | `ArtworkView`, `.tiny` |
| Track title | text | Current track name (single line) | `track.title` |
| Artist name | text | Current artist name (single line) | `track.artistName` |
| Play/Pause button | control | Toggle playback with loading state | `play.fill`, `pause.fill` |
| Next button | control | Skip to next track | `forward.fill` |
| Progress bar | indicator | Thin progress indicator at bottom edge | `Rectangle()` |
| Error banner | indicator | Orange warning bar with error message and retry | `.failed` |
| Retry button | action | Retry playback after error | `Retry` |
| Nothing playing state | state | Placeholder shown when no track is playing | `Nothing Playing` |
| Swipe gesture | gesture | Horizontal swipe on track info for prev/next | `DragGesture` |
| Pull up gesture | gesture | Vertical drag up to open full player | `onTap` |
| Context menu | menu | Long-press menu with favorite, playlist, show now playing | `contextMenu` |
| Floating style | state | Rounded pill shape with shadow (iOS 18+) | `isFloating` |

---

## TrackRow

- **View name:** `TrackRow`
- **Canonical name:** TrackRow
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Track artwork | artwork | Small thumbnail for track (44x44 or 48x48) | `ArtworkView`, `.tiny` |
| Track number | text | Numeric position in album/playlist | `track.trackNumber` |
| Now playing indicator | indicator | Speaker icon when track is currently playing | `speaker.wave.2.fill` |
| Track title | text | Song name with accent color when playing | `track.title` |
| Autoplay indicator | indicator | Sparkles icon for auto-generated recommendations | `sparkles` |
| Artist name | text | Artist name subtitle | `track.artistName` |
| Download spinner | indicator | Spinning progress indicator for tracks being actively downloaded | `ProgressView()`, `isActivelyDownloading` |
| Downloaded indicator | indicator | Arrow icon for locally downloaded tracks | `arrow.down.circle.fill` |
| Duration | text | Track length in mm:ss format | `formattedDuration` |
| Context menu | menu | Long-press menu with queue and playlist actions | `contextMenu` |
| Play next action | action | Add track to front of queue | `Play Next` |
| Play last action | action | Add track to end of queue | `Play Last` |
| Add to playlist action | action | Open playlist picker sheet | `Add to Playlist...` |
| Add to recent playlist action | action | Quick-add to last used playlist | `Add to [playlist]` |
| Favorite toggle | action | Toggle track favorite status | `Favorite`, `Unfavorite` |
| Offline unavailable state | state | Row appears dimmed when offline and track is not downloaded | `isUnavailableOffline` |
| Offline blocked toast | indicator | Toast shown when tapping unavailable track while offline | `Not available offline` |

---

## FilterSheet

- **View name:** `FilterSheet`
- **Canonical name:** FilterSheet
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Title | text | "Filters" heading | |
| Done button | control | Dismiss the filter sheet | `Done` |
| Clear filters button | action | Reset all filters to default | `Clear Filters` |
| Year filter | control | Picker/slider for filtering by year range | `showYearFilter` |
| Artist filter | control | Selection for filtering by artist | `showArtistFilter`, `ArtistSelectionView` |
| Genre filter | control | Selection for filtering by genre | `GenreSelectionView` |
| Source filter | control | Selection for filtering by library source | (needs confirmation) |

---

## PlaylistPickerSheet

- **View name:** `PlaylistPickerSheet`
- **Canonical name:** PlaylistPickerSheet
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Title | text | Sheet title (e.g., "Add to Playlist") | `title` |
| Playlist list | list | Scrollable list of available playlists | |
| Playlist row | control | Selectable playlist with artwork and name | |
| Create new playlist button | action | Button to create and add to new playlist | `Create New Playlist` |
| Cancel button | control | Dismiss without action | `Cancel` |
| Incompatible indicator | indicator | Visual indication of cross-server incompatibility | (needs confirmation) |

---

## CoverFlowView

- **View name:** `CoverFlowView`
- **Canonical name:** CoverFlowView
- **Area:** Shared
- **Platform:** iOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| 3D carousel | region | Horizontally scrolling 3D artwork carousel | `CoverFlowView<Item, ItemView>` |
| Center item | artwork | Focused item displayed front and center | `selectedItem` |
| Side items | artwork | Angled items on either side of center | `CoverFlowRotationModifier` |
| Item title | text | Title of selected item below carousel | `titleContent` |
| Item subtitle | text | Subtitle of selected item | `subtitleContent` |
| Detail content | region | Additional content below selected item | `detailContent` |
| Swipe gesture | gesture | Horizontal swipe to navigate carousel | |
| Background | region | Black background for immersive effect | `Color.black` |

---

## ConnectionStatusBanner

- **View name:** `ConnectionStatusBanner`
- **Canonical name:** ConnectionStatusBanner
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Banner container | region | Top-aligned status bar | |
| Status icon | indicator | Icon representing connection state | |
| Status message | text | Description of current network/server status | `networkState` |
| Offline indicator | state | Shows when device is offline | |
| Server unreachable indicator | state | Shows when Plex server is unreachable | |

---

## ToastView

- **View name:** `ToastView` / `ToastBannerView`
- **Canonical name:** ToastView
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Toast container | region | Floating notification banner | `ToastBannerView` |
| Toast icon | indicator | SF Symbol representing toast type | `iconSystemName` |
| Toast title | text | Primary toast message | `title` |
| Toast message | text | Secondary descriptive text | `message` |
| Activity indicator | indicator | Spinner for persistent loading toasts | `showsActivityIndicator` |
| Success style | state | Green/checkmark styling for success messages | `style: .success` |
| Error style | state | Red/warning styling for error messages | `style: .error` |
| Warning style | state | Orange styling for warning messages | `style: .warning` |
| Info style | state | Blue/neutral styling for info messages | `style: .info` |

---

## ArtworkView

- **View name:** `ArtworkView`
- **Canonical name:** ArtworkView
- **Area:** Shared
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Image container | artwork | Cached artwork image display | `ArtworkView` |
| Placeholder | indicator | Music note icon shown while loading or missing | `music.note` |
| Corner radius | state | Rounded corners (configurable, circular for artists) | `cornerRadius` |
| Size variant | state | Predefined sizes: tiny, thumbnail, small, medium, large, extraLarge | `size: .small` |

---

## WaveformView

- **View name:** `WaveformView`
- **Canonical name:** WaveformView
- **Area:** Player
- **Platform:** iOS, iPadOS, macOS
- **Definition status:** Draft

### Elements

| Element name | Type | Description | Synonyms / code refs |
|--------------|------|-------------|---------------------|
| Waveform bars | artwork | Vertical bars representing audio amplitude | `heights` |
| Progress fill | indicator | Colored portion showing playback progress | `progress` |
| Buffered fill | indicator | Semi-transparent portion showing buffered content | `bufferedProgress` |
| Background bars | indicator | Unfilled/upcoming portion of waveform | |

---

## Element Types Reference

| Type | Description |
|------|-------------|
| **region** | Container or layout area grouping related elements |
| **control** | Interactive element (button, toggle, picker, row) |
| **action** | Specific action triggered by user interaction |
| **indicator** | Visual feedback element (badge, spinner, icon) |
| **text** | Static or dynamic text display |
| **artwork** | Image or visual media element |
| **list** | Scrollable collection of items |
| **menu** | Popup/sheet with multiple options |
| **gesture** | Touch/pointer interaction pattern |
| **state** | UI condition or mode |

---

## Maintenance

This document should be updated when:
- A new View is added to `Packages/EnsembleUI/Sources/Screens/` or `Components/`
- New UI elements are added to existing views
- Element names or behaviors change
- Elements are removed or deprecated

See `CLAUDE.md` for the update protocol.
