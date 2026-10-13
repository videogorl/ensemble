# Ensemble surface checklist

Every surface the app presents, with a check of about one minute and an
explicit pass condition. It is the safety net for
[`rearchitecture-plan.md`](rearchitecture-plan.md): run it after each step so a
change in one area cannot silently break another.

## How to run

- Follow plan section 7. iPhone rows run on the physical iPhone 16 Pro through
  Device Hub, on a build proven to be the one just produced. Mac rows run on
  the explicitly launched built `.app`, after checking the PID's executable
  path and build version.
- Record one result per row: `pass`, `fail`, or `not run`. A row without the
  device it names is `not run`, never `pass`. Give a reason for every `fail`
  and `not run`.
- Mirrored input counts only when the phone UI or fresh Ensemble logs confirm
  it. For audio, say which evidence was used: advancing progress, system Now
  Playing, or render logs.
- Checks are non-destructive. Cancel every delete, remove, reset, and clear
  confirmation. Leave playback paused and the phone locked.
- Rows need a signed-in source with a synced library. Rows that need Apple
  Music, a downloaded item, or lyrics are `not run` when that data is absent.
- This is the short gate. For a deep visual sweep use the `surface-sweep` skill.

## Automation aids

From [`agent-runtime-testing.md`](agent-runtime-testing.md) and
`AutomationSupport.swift`. Launch arguments and the debug route work in Debug
builds only. They place the app near a surface; they do not replace the
interaction a row checks.

- Launch arguments: `-EnsembleAutomationMode YES`,
  `-EnsembleAutomationStartSurface <surface>`,
  `-EnsembleAutomationDisableAnimations YES`.
- Debug route: `ensemble://debug/open?surface=<surface>`. Surfaces: `home`,
  `songs`, `artists`, `albums`, `genres`, `playlists`, `favorites`, `search`,
  `downloads`, `settings`, `profile`, `profile-storage`, `add-source`.
- Media deep links: `ensemble://album/<id>`, `artist/<id>`, `playlist/<id>`,
  `song/<id>`, each with an optional `sourceKey` query item.
- Accepted commands log `USER_JOURNEY context=automation`.
- Accessibility identifiers: `sidebar.search`, `sidebar.library.<tab>`,
  `sidebar.playlists.all`, `sidebar.toolbar.downloads`,
  `sidebar.toolbar.profile`, `sidebar.browse`, `browse.artists`,
  `browse.genres`, `browse.playlists`, `info.lyrics`, `info.sources`,
  `toast.banner`, `toast.action`.

## iPhone

Device for every row unless stated: iPhone 16 Pro through Device Hub.

| Surface | How to reach | Check | Pass condition | Device needed |
|---|---|---|---|---|
| Launch and readiness | Kill the app, then launch it | Watch from icon tap to first usable screen | Shell appears with cached library content; no blank loader over a populated library; no crash | iPhone |
| Tab bar shell | After launch | Tap each tab: Feed, Artists, Playlists, Search, More (default set) | Each tab shows its own root, selection highlights, and re-tapping returns to that root | iPhone |
| More and Edit Tabs | More tab | Open Songs, Albums, Genres, Favorites, Downloads, Hidden; open Edit Tabs and cancel | Every row pushes its screen and Back returns to More; the tab editor opens and closes without changing tabs | iPhone |
| Feed (`HomeView`) | Feed tab, or `surface=home` | Scroll one hub sideways, open a card, go back; open the hub order sheet and cancel | Hubs show artwork and titles; the card opens the matching detail; the order sheet dismisses unchanged | iPhone |
| Songs (`SongsView`) | More > Songs, or `surface=songs` | Scroll to the bottom and back; tap a genre chip, then clear it; tap a track | List scrolls to the last row above the mini player; the chip filters and clears; the track starts playing | iPhone |
| Albums (`AlbumsView`) | More > Albums | Scroll the grid; open the sort and filter sheet and cancel; open an album | Artwork loads; the sheet dismisses unchanged; album detail opens | iPhone |
| Artists (`ArtistsView`) | Artists tab | Scroll; open an artist | The list is populated and artist detail opens | iPhone |
| Playlists (`PlaylistsView`) | Playlists tab | Open a regular playlist; open the New Playlist sheet and cancel | Playlist detail lists its tracks; the sheet dismisses and no playlist is created | iPhone |
| Genres (`GenresView`) | More > Genres | Open a genre | Genre detail lists tracks | iPhone |
| Moods (`MoodTracksView`) | Search tab, unfocused, Moods section | Open one mood | Mood track list opens with tracks, or the section is absent because the library has no moods | iPhone |
| Favorites (`FavoritesView`) | More > Favorites | Scroll; open one item | Favorites, or its empty state, render; the item opens or plays | iPhone |
| Hidden (`HiddenMediaView`) | More > Hidden | Open the screen | The Hidden list or its empty state renders | iPhone |
| Pins | Search tab, unfocused, Pinned section | Tap a pinned item | The pin opens its artist, album, or playlist detail; `not run` when nothing is pinned | iPhone |
| Album detail (`MediaDetailView`) | Any album, or `ensemble://album/<id>` | Check header, artwork, and track list; tap Play | Header and tracks render; playback starts with the album's first track | iPhone |
| Artist detail | Any artist | Scroll the sections; open an album from the artist | Sections render and the album opens | iPhone |
| Playlist detail | Any playlist; a merged one if present (`MergedPlaylistDetailView`) | Scroll; tap a track | Tracks render; the tapped track plays | iPhone |
| Item info (`LibraryItemInfoView`) | Get Info from a track or album menu | Open and dismiss | The info sheet shows metadata and dismisses | iPhone |
| Search (`SearchView`) | Search tab, or `surface=search` | Type a known artist name, open a result, clear the field | Results appear in sections; the result opens; clearing restores the explore state | iPhone |
| Mini player | Start any track, stay on a browse screen | Tap play/pause; tap next; scroll a long list to its end | State and title update; the mini player never covers the last row; it shows on every tab | iPhone |
| Now Playing: controls | Tap the mini player | Play/pause, next, previous, drag the scrubber | Each control changes state; elapsed time advances; artwork and title match the track | iPhone |
| Now Playing: queue | Swipe to the Queue page | Scroll; toggle History; toggle shuffle and repeat, then restore them | Upcoming tracks list with the current one marked; History shows played tracks; toggles change state | iPhone |
| Now Playing: lyrics | Swipe to the Lyrics page | Let a track with lyrics play for 20 seconds | The highlighted line advances, or "No Lyrics" shows for a track without them | iPhone |
| Now Playing: info | Swipe to the Info page | Read the metadata and streaming rows | Album, artist, duration, source, and server rows are filled, with no endless spinner | iPhone |
| Now Playing: dismiss and go-to | From Controls | Tap the artist name; reopen Now Playing; swipe it down | The artist detail opens on a tab; Now Playing dismisses back to the previous screen | iPhone |
| Lock Screen | Lock the phone during playback | Check artwork and title; pause, play, next, scrub | The Lock Screen shows the current item and every control changes playback | iPhone |
| Control Center | Open Control Center during playback | Check the media tile; pause, play, next | The tile shows the current item and controls change playback | iPhone |
| Background playback | Lock the phone near the end of a track | Wait for the natural track change | The next track starts and system Now Playing updates while locked | iPhone |
| StageFlow (`StageFlowView`) | Rotate to landscape on Songs, Albums, or Playlists | Swipe the carousel; open the track panel; rotate back | The carousel snaps to a centre item; tabs and mini player hide in landscape and return in portrait | iPhone |
| Share and song.link | Share from a track menu | Open the share sheet, read the link, cancel | The share sheet opens with a song.link URL, or the documented fallback URL or text when resolution fails | iPhone |
| Song permalink (`SongPermalinkLoader`) | Open `ensemble://song/<id>` for a known track | Wait for the route | The app opens the song's destination, not an error or a blank screen | iPhone |
| Downloads (`DownloadsView`) | More > Downloads, or `surface=downloads` | Open a library row and an item row; open pending changes (`PendingMutationsView`) if present | Download rows show state and size; drill-downs open; nothing starts or is deleted | iPhone |
| Download manager settings (`DownloadManagerSettingsView`) | Downloads toolbar | Open and go back without toggling | Servers and target toggles render with their current state | iPhone |
| Offline playback | Airplane Mode with one downloaded track | Play the downloaded track; tap a non-downloaded one | The downloaded track plays; the other is dimmed and blocked with a toast | iPhone |
| Profile (`ProfileView`) | Profile toolbar button, or `surface=profile` | Scroll every section: Music Sources, Appearance, Playback, Storage, Reset, Developer, About | Every section renders; no confirmation is accepted | iPhone |
| Music source detail | Profile > a source (`MusicSourceAccountDetailView`) | Open; read servers, libraries, and sync status; go back | Servers and libraries list with a sync state | iPhone |
| Add Source (`AddSourceView`) | Profile > Add Source, or `surface=add-source` | Open the chooser, then cancel | Plex and Apple Music options show; nothing is submitted | iPhone |
| Settings subpages | Profile > Playback and sync rows | Open Merging, Sync, SmartMix, Audio Quality, Connection Security, Track Swipe Actions | Each page opens with its current values and goes back | iPhone |
| Storage | Profile > Storage, or `surface=profile-storage` | Read the usage rows; tap Clear Artwork Cache and cancel | Usage figures show; the confirmation appears and cancel leaves data intact | iPhone |
| Logs (`LogsSettingsView`) | Profile > Developer > Logs | Open the newest session, then one entry (`LogDetailView`) | The session list is populated and the detail shows text from the current run | iPhone |
| Toasts | Any action that toasts, such as the offline block above | Watch the toast appear and dismiss | The toast shows above all content and dismisses without blocking touches | iPhone |
| Siri media request | "Play <album> in Ensemble" | Speak the request with the phone unlocked | Siri confirms and Ensemble plays the requested item, shown in system Now Playing | iPhone |
| Siri affinity and add | During playback, for example "I like this song" or "Add this to <playlist>" | Speak one request; decline the add if it asks to confirm | Siri routes to Ensemble and reports a result instead of an error | iPhone |
| App Shortcuts | Shortcuts app > Ensemble | Confirm Play Track, Play Album, Play Artist, Play Playlist, and Open Media are listed; run Play Album | All five appear; the run starts playback of the chosen album | iPhone |
| Focus filter | Settings > Focus > a Focus > Focus Filters | Confirm an Ensemble filter is offered; do not save | The Ensemble filter and its parameters appear | iPhone |
| Spotlight | Swipe down on the Home Screen, search a known album | Tap the Ensemble result | An Ensemble result shows and opens that item in the app | iPhone |
| External display Now Playing (`ExternalDisplayNowPlayingView`) | Screen Mirroring or a wired display during playback | None | **KNOWN BROKEN, PARKED by owner decision.** Record `not run`. Do not diagnose until asked | iPhone and external display |

## iPad

Device for every row: the paired iPad Pro. It is approved for plan steps 5 and
6; ask Felicity to connect it first. Before then, record these rows as
`not run`, or run them on a UUID-pinned simulator and say so.

| Surface | How to reach | Check | Pass condition | Device needed |
|---|---|---|---|---|
| Launch and readiness | Kill and launch | Watch to the first usable screen | Sidebar and detail appear with cached content; no crash | iPad Pro |
| Sidebar shell | After launch | Select Search, Feed, Songs, Artists, Albums, Genres, Favorites, All Playlists, one playlist, one pin, Hidden | Each selection highlights and replaces the detail column with its screen | iPad Pro |
| Sidebar collapse | Sidebar toggle | Collapse and expand from a root and from a pushed detail | Content reflows and the mini player recentres without overlap | iPad Pro |
| Browse split | Artists, Genres, or Playlists (`browse.artists`, `browse.genres`, `browse.playlists`) | Select two different list items | The detail pane changes to each selection while the list stays put | iPad Pro |
| Songs browser | Sidebar > Songs | Scroll; tap a track | The large-screen track table scrolls and the track plays | iPad Pro |
| Search | Sidebar > Search (`sidebar.search`) | Type a query and open a result | Results show and the result opens in the detail column | iPad Pro |
| Mini player | Start playback | Play/pause and next; rotate the iPad | Controls work and the mini player stays inside the content area in both orientations | iPad Pro |
| Now Playing wide layout (`NowPlayingWidePanelLayout`) | Tap the mini player | Use the controls; switch the detail panel through Queue, Lyrics, and Info | Controls and panel show side by side; each panel renders; dismissal restores the shell | iPad Pro |
| Profile and Downloads | Sidebar toolbar (`sidebar.toolbar.profile`, `sidebar.toolbar.downloads`) | Open each and dismiss | Each opens with populated sections and dismisses back to the same selection | iPad Pro |
| Lock Screen and Control Center | Lock during playback | Pause, play, next | The current item shows and controls change playback | iPad Pro |

## Mac

Device for every row: the Mac, running the explicitly launched built `.app`.

| Surface | How to reach | Check | Pass condition | Device needed |
|---|---|---|---|---|
| Launch and readiness | Quit, then open the built `.app` by path | Confirm the PID's executable path and version; watch the first frame | The main window appears with sidebar and cached content; the process is the build just produced | Mac |
| Sidebar (`MacBrowseSplitView`) | Main window | Select Search, each Library row, All Playlists, one playlist, one pin | Each selection highlights and shows its screen without an empty chrome-only frame staying on screen | Mac |
| Browse split | Artists, Genres, or Playlists | Select two list items | The picker pane keeps its place and the detail pane changes | Mac |
| Songs table | Sidebar > Songs | Scroll; play a track from its row; open a row context menu and dismiss | The AppKit table scrolls, the track plays, and the menu lists its actions | Mac |
| Detail screens | Open an album, an artist, and a playlist | Check header, artwork, and tracks | Each renders and its Play action starts playback | Mac |
| Feed | Sidebar > Feed | Scroll; open a card | Hubs render and the title stays readable over artwork while scrolling | Mac |
| Search | Sidebar > Search | Type a query and open a result | Results show and the result opens | Mac |
| Mini player | Start playback | Play/pause and next; resize the window narrow and wide | Controls work and nothing overlaps at either width | Mac |
| Now Playing (`NowPlayingViewportRoot`) | Click the mini player | Use the controls; open Queue, Lyrics, and Info; dismiss | The wide layout shows controls and panel; dismissal restores toolbar and window chrome | Mac |
| Menu commands | Menu bar | View > Refresh (Cmd-R); Playback > Play/Pause (Space) | Refresh runs on the active screen; Play/Pause toggles playback | Mac |
| Profile window | Ensemble > Settings… (Cmd-,) | Scroll every section; open Logs and one session | The Profile window opens with every section; Logs shows the current run | Mac |
| Downloads window | Downloads toolbar button | Open; drill into one row; close | The Downloads window opens with rows and closes without changing downloads | Mac |
| System Now Playing | Control Center > Now Playing during playback | Pause, play, next | The current item shows and controls change playback | Mac |
| Share and song.link | Share from a track menu | Open the sharing picker and dismiss | The picker opens with a song.link URL, or the documented fallback when resolution fails | Mac |

## Apple Watch

Device for every row: the paired Apple Watch. It is approved for plan step 5;
ask Felicity to connect it first. How the watch is driven for acceptance is
not yet decided (plan section 10), so record these rows as `not run` until it
is.

| Surface | How to reach | Check | Pass condition | Device needed |
|---|---|---|---|---|
| Launch and setup | Open Ensemble on the watch | Watch to the first screen | Home appears with restored credentials, or the Plex Link code screen appears with a code | Apple Watch |
| Watch Home | After launch | Scroll the pins grid and the category rows | Pins show artwork; Albums, Artists, Playlists, and Recently Added rows are present | Apple Watch |
| Category list and detail | Home > a category > an item | Open an album or playlist | The list is populated and the detail shows the hero and track rows | Apple Watch |
| Local playback | Detail > Play, with the target set to watch | Play, pause, turn the Crown | Audio plays from the watch, progress advances, and the Crown changes volume | Apple Watch with audio output |
| Now Playing and queue | Top-right Now Playing button | Open the sheet; open Queue; close | The current track shows and the queue lists upcoming tracks | Apple Watch |
| Phone remote | Now Playing target toggle set to phone, with the iPhone playing | Previous, play/pause, next, shuffle, repeat | Each command changes playback on the iPhone and the watch shows the phone's track | Apple Watch and iPhone |
| Remote unavailable | Target set to phone with the iPhone unreachable | Open Now Playing > Queue | "Reconnect to iPhone" shows instead of a stale queue | Apple Watch |
| Media actions | Swipe an item > More | Open Add to Playlist, then cancel | The action list and playlist picker open; nothing is added | Apple Watch |
| Watch Settings | Home > Settings | Open the source, Add Source, iCloud Sync, and Personalization | Each page opens; the source page lists libraries and Sync Libraries | Apple Watch |

## Recording a run

Copy the tables into the step's verification note under
`docs/investigations/` and add a `Result` column, or list
`Platform / Surface / Result / Evidence` per row. Record the source commit,
the built app path, and the installed version next to the results.
