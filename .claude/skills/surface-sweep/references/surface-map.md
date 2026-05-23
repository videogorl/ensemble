# Ensemble Surface Map

Use this checklist for broad visual sweeps. Data-dependent rows can vary by tester library; touch representative examples when available and record blockers when unavailable.

## Global Checks

- Cold launch: splash/initial shell, loading state, restored navigation state if present.
- Root chrome: status/toolbar/title behavior, mini-player visibility, offline/low-power indicators, toast placement.
- Profile toolbar: open Profile, dismiss, return to previous surface.
- Add account route: verify Add Plex Account opens from empty states and Profile; do not submit credentials unless explicitly requested.
- Refresh: pull-to-refresh or View > Refresh / refresh command on Feed and major library screens.
- Search chrome: focus, type query, clear, submit, navigate result if data exists.
- Context menus: track, album, artist, playlist, queue row, mini-player ellipsis. Exercise safe actions and cancel destructive actions.
- Swipe actions: on iOS/iPadOS, reveal and cancel representative row swipe actions for tracks, playlists, downloads, pending mutations, and settings rows where available; confirm destructive actions show a confirmation or are intentionally non-destructive before canceling.
- Sheets/popovers/alerts: sort/filter, hub order, add to playlist, edit metadata, get info, share, text input, delete confirmation. Capture and dismiss.
- Add to Playlist: open from track rows, album/detail menus, queue/history rows, mini-player/Now Playing menus, search results, and feed cards where available. Verify picker/window content, disabled/empty states, cancel path, and that no playlist mutation is completed unless requested.
- Go To navigation actions: from media detail, Now Playing viewport/sheet, queue/history rows, mini-player actions, feed cards, and search results, trigger safe "Go to Artist/Album/Playlist" actions where available and verify the expected detail route, back path, and sidebar/tab selection.
- Mini-player heightened scheme: verify position and spacing on every platform state that changes geometry: root view, pushed detail view, sidebar open/closed, iPad portrait/landscape when available, iPhone tab/More routes, keyboard/search active, macOS narrow/wide resize, and Now Playing dismissal. Capture before/after screenshots or video when the mini-player moves.
- Now Playing: controls, queue, history, lyrics, info panels, repeat/shuffle/radio/autoplay where visible, dismissal/back path.
- Queue and History: scroll Queue to bottom and back to top, open the History panel/list when present, exercise row menus and safe navigation actions, and check empty/long-list states.
- Lyrics: scroll timed/plain lyrics, verify current-line highlighting remains coherent, and watch for blur/gradient artifacts while scrolling, paging panels, and returning to controls.
- Appearance propagation: toggle aurora on/off, change accent colors, and verify mini-player, Now Playing, buttons, chips, selected rows, sheets/popovers, and macOS menu/toolbar accents update. Restore original values.
- Sorting/filtering: change and restore sort/filter settings in Songs, Albums, Artists, Favorites, Genres, Playlists, Downloads, and detail track lists where controls exist.
- Genre chips: verify spacing, wrapping/scrolling, selected/unselected state, reset behavior, and filtering on Songs, Genres, artist detail, favorites/mood/virtual collections, and compact vs regular layouts where data exists.
- Scroll boundaries: for every long list/grid/table, scroll to bottom and back to top, checking mini-player clearance, final-row reachability, section headers, scroll index overlays, and toolbar/search collapse behavior.
- Empty/data transition states: for every screen that can be empty, filtered empty, loading, syncing, offline, or no-results, capture at least one reachable representative state or record the blocker.

## iPhone Compact

Primary default tabs:
- Feed: loading/empty/hub state, Edit hub order sheet, first visible hub horizontal scroll, hub card to detail.
- Feed action paths: card context menu, add-to-playlist where applicable, go-to detail actions, and hub horizontal scroll to both ends.
- Artists: list/grid or empty state, sort/filter sheet, first artist detail, artist context menu.
- Playlists: list/empty state, create playlist sheet, first playlist detail, edit/rename/delete confirmation if available, playlist context menu.
- Search: empty explore state, recent searches if present, pins section, query results, no-results state.
- More: Songs, Albums, Genres, Favorites, Downloads, Edit Tabs.

More-routed library screens:
- Songs: genre chips, indexed scroll if visible, sort/filter sheet, track row context menu, row swipe actions, row tap/play path, bottom-of-list reachability.
- Albums: grid/list, sort/filter sheet, album detail, metadata/get-info sheet if available.
- Genres: genre list, genre detail, track list.
- Favorites: favorite tracks/albums/artists/playlists sections or empty state, sorting/filtering, genre/filter chips if present, row/card menus.
- Downloads: libraries section, items section, pending mutations if present, Download Manager settings.

iPhone-only/compact checks:
- Rotate Songs or Playlists to landscape and verify StageFlow if available.
- Expand Now Playing as a sheet/full-screen cover and test carousel paging.
- Verify keyboard presentation on Search and text-input sheets.
- Verify mini-player clearance with tab bar, More-pushed routes, Search keyboard, and a long list scrolled to the final row.

## iPad Regular

Sidebar root:
- Search top-level item.
- Library section: Feed, Songs, Artists, Albums, Genres, Favorites.
- Playlists section: All Playlists, representative regular playlist, representative smart playlist if present.
- Pins section if present.

Regular-width behavior:
- Sidebar collapse/expand if reachable.
- Sidebar collapse/expand from root and pushed detail views, including mini-player recentering and detail content width changes.
- Detail column placeholder or selected detail.
- Browse-list/detail splits inside Artists, Playlists, Genres.
- Sort/filter sheets and popovers from toolbar.
- Representative iPad row swipe actions in Songs, Playlists, Favorites, Downloads, and Pending Mutations where data exists.
- Now Playing wide sheet: controls plus Queue/History/Lyrics/Info detail panel, queue bottom scroll, lyric scroll/blur behavior, and safe row action menus.
- Drag/drop smoke where safe: start a drag from a track/album/playlist and cancel before dropping unless the user requested mutation coverage.
- Appearance changes: toggle aurora and accent color while Feed, media detail, mini-player, and Now Playing are visible; restore original values.

## macOS

Main window:
- Sidebar sections: Search, Library, Playlists, Smart Playlists, Pins.
- Feed with toolbar Edit and hub order sheet.
- Songs native AppKit table: scroll, columns, context menu, search/filter if available.
- Artists/Albums/Genres/Favorites/Playlists detail flows.
- Sort and filter changes for Songs, Albums, Artists, Favorites, Playlists, and detail track lists; restore original values.
- Playlist rows in sidebar: context menu, drag-over/drop target visual if safe, cancel destructive commands.
- Mini-player: compact controls, menu, click to Now Playing viewport.
- Now Playing viewport: controls branch, queue/history/lyrics/info availability, queue bottom scroll, lyric scroll/blur behavior, safe row action menus, toolbar/window chrome restoration after dismiss.
- Appearance changes: aurora toggle, accent color changes, sidebar selection, mini-player, Now Playing, sheets, and menu/toolbar accent propagation.

Auxiliary and utility surfaces:
- Profile window/sheet: profile header, music sources, iCloud Sync, appearance/accent, playback, storage, reset confirmations, developer/debug section, about/support links. Cancel destructive reset and account removal.
- Music Source detail: server/library rows, sync status, feature badges, account removal confirmation only.
- Add Plex Account: first screen and validation errors for empty submit if safe; do not enter real credentials unless requested.
- Downloads: libraries, pending changes, items, Download Manager settings, library/item drill-downs.
- Logs: session list and log detail if present.
- Settings subviews: Audio Quality, Connection Security, Track Swipe Actions, Sync Settings.
- Add-to-playlist windows/sheets: open from table row context menus, media detail menus, queue/history, search, and mini-player/Now Playing where available; cancel without mutation.

macOS command/menu checks:
- App menu opens standard Settings/About/Quit routes where applicable; do not quit during a sweep.
- View > Refresh dispatches to active screen.
- Playback menu commands are enabled/disabled consistently with current playback state.
- Window resizing: narrow and wide layouts do not overlap text or lose primary controls.

## Cross-Platform Parity

Compare these surfaces after platform sweeps:
- Feed toolbar/edit affordance.
- Sort/filter affordances on Songs, Albums, Artists, Favorites, and details.
- Track list row actions across iPhone UIKit table, iPad table, and macOS AppKit table.
- iOS/iPadOS swipe actions compared against macOS context-menu equivalents.
- Playlist creation/editing flows.
- Add-to-playlist presentation and safe cancel path.
- Go To Artist/Album/Playlist contextual navigation from Feed, Search, media detail, mini-player, Now Playing, Queue, and History.
- Profile and Downloads utility layout.
- Now Playing panels and mini-player action menus.
- Queue bottom, History panel, Lyrics scroll/blur behavior.
- Aurora/accent updates and restoration.
- Mini-player spacing/position across root, pushed detail, sidebar open/closed, keyboard/search, and resize/rotation.
- Genre chip spacing and filtering across compact, regular, and macOS table/header surfaces.
- Empty/error/loading states for no account, no enabled libraries, syncing, no results, and no downloads.
