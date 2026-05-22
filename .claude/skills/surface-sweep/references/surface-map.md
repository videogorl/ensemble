# Ensemble Surface Map

Use this checklist for broad visual sweeps. Data-dependent rows can vary by tester library; touch representative examples when available and record blockers when unavailable.

## Global Checks

- Cold launch: splash/initial shell, loading state, restored navigation state if present.
- Root chrome: status/toolbar/title behavior, mini-player visibility, offline/low-power indicators, toast placement.
- Profile toolbar: open Profile, dismiss, return to previous surface.
- Add account route: verify Add Plex Account opens from empty states and Profile; do not submit credentials unless explicitly requested.
- Refresh: pull-to-refresh or View > Refresh / refresh command on Feed and major library screens.
- Search chrome: focus, type query, clear, submit, navigate result if data exists.
- Context menus: track, album, artist, playlist, queue row, mini-player ellipsis. Cancel destructive actions.
- Swipe actions: on iOS/iPadOS, reveal and cancel representative row swipe actions for tracks, playlists, downloads, pending mutations, and settings rows where available; confirm destructive actions show a confirmation or are intentionally non-destructive before canceling.
- Sheets/popovers/alerts: sort/filter, hub order, add to playlist, edit metadata, get info, share, text input, delete confirmation. Capture and dismiss.
- Mini-player: visible/resting state, play/pause, next/previous if enabled, swipe/expand on iOS, menu/popover on iPad/macOS.
- Now Playing: controls, queue, lyrics, info panels, repeat/shuffle/radio/autoplay where visible, dismissal/back path.

## iPhone Compact

Primary default tabs:
- Feed: loading/empty/hub state, Edit hub order sheet, first visible hub horizontal scroll, hub card to detail.
- Artists: list/grid or empty state, sort/filter sheet, first artist detail, artist context menu.
- Playlists: list/empty state, create playlist sheet, first playlist detail, edit/rename/delete confirmation if available, playlist context menu.
- Search: empty explore state, recent searches if present, pins section, query results, no-results state.
- More: Songs, Albums, Genres, Favorites, Downloads, Edit Tabs.

More-routed library screens:
- Songs: genre chips, indexed scroll if visible, sort/filter sheet, track row context menu, row swipe actions, row tap/play path.
- Albums: grid/list, sort/filter sheet, album detail, metadata/get-info sheet if available.
- Genres: genre list, genre detail, track list.
- Favorites: favorite tracks/albums/artists/playlists sections or empty state, filter sheet.
- Downloads: libraries section, items section, pending mutations if present, Download Manager settings.

iPhone-only/compact checks:
- Rotate Songs or Playlists to landscape and verify StageFlow if available.
- Expand Now Playing as a sheet/full-screen cover and test carousel paging.
- Verify keyboard presentation on Search and text-input sheets.

## iPad Regular

Sidebar root:
- Search top-level item.
- Library section: Feed, Songs, Artists, Albums, Genres, Favorites.
- Playlists section: All Playlists, representative regular playlist, representative smart playlist if present.
- Pins section if present.

Regular-width behavior:
- Sidebar collapse/expand if reachable.
- Detail column placeholder or selected detail.
- Browse-list/detail splits inside Artists, Playlists, Genres.
- Sort/filter sheets and popovers from toolbar.
- Representative iPad row swipe actions in Songs, Playlists, Favorites, Downloads, and Pending Mutations where data exists.
- Now Playing wide sheet: controls plus Queue/Lyrics/Info detail panel.
- Drag/drop smoke where safe: start a drag from a track/album/playlist and cancel before dropping unless the user requested mutation coverage.

## macOS

Main window:
- Sidebar sections: Search, Library, Playlists, Smart Playlists, Pins.
- Feed with toolbar Edit and hub order sheet.
- Songs native AppKit table: scroll, columns, context menu, search/filter if available.
- Artists/Albums/Genres/Favorites/Playlists detail flows.
- Playlist rows in sidebar: context menu, drag-over/drop target visual if safe, cancel destructive commands.
- Mini-player: compact controls, menu, click to Now Playing viewport.
- Now Playing viewport: controls branch, queue/lyrics/info availability, toolbar/window chrome restoration after dismiss.

Auxiliary and utility surfaces:
- Profile window/sheet: profile header, music sources, iCloud Sync, appearance/accent, playback, storage, reset confirmations, developer/debug section, about/support links. Cancel destructive reset and account removal.
- Music Source detail: server/library rows, sync status, feature badges, account removal confirmation only.
- Add Plex Account: first screen and validation errors for empty submit if safe; do not enter real credentials unless requested.
- Downloads: libraries, pending changes, items, Download Manager settings, library/item drill-downs.
- Logs: session list and log detail if present.
- Settings subviews: Audio Quality, Connection Security, Track Swipe Actions, Sync Settings.

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
- Profile and Downloads utility layout.
- Now Playing panels and mini-player action menus.
- Empty/error/loading states for no account, no enabled libraries, syncing, no results, and no downloads.
