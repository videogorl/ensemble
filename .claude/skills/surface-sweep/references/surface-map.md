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

## Multi-Source And Apple Music Journeys

Run this section on iOS/iPadOS when Apple Music or another non-Plex source is enabled. Use a physical device for authorization, DRM playback, AirPlay, Siri, background playback, and live mutations. Record which checks used cached data versus the live provider.

Source lifecycle:
- Open Profile > Music Sources. Verify every source has its official icon, provider name, sync state, and a navigable source-detail sheet.
- Open Add Source. Verify the chooser has no phantom controls, Plex and Apple Music are distinct options, and unsupported OS/platform states are gated without affecting Plex. Check the supported iOS/iPadOS version plus one unsupported OS or platform when feasible.
- Verify Apple Music enablement is device-local: it must not appear as a synced source on another device, macOS, or Watch, while Plex source synchronization remains unchanged.
- Add Apple Music and confirm the app returns to usable UI before the initial sync finishes. Browse another surface during sync; progress must advance, complete, or surface an actionable error rather than sticking indefinitely.
- Refresh and relaunch during or after sync. Confirm provider state, enabled-library scope, and cached content converge without duplicating media.
- If removal is explicitly authorized, inventory Apple-scoped rows, provider state, artwork, and queue references before removal. Remove Apple Music, confirm its content and caches disappear without deleting Plex data, then re-add it and verify recovery.

Normalized browse and identity:
- Compare representative Plex and Apple rows in Songs, Albums, Artists, Playlists, Favorites, Feed hubs, search, Queue, and Now Playing. Provider labels, artwork, dates, capabilities, and source/server text must come from normalized models rather than screen-specific shims.
- Exercise every supported sort on Apple songs, albums, artists, and playlists in both directions. Verify real provider metadata orders correctly, unknown values always sort last, and equal or unknown values use a deterministic tie-breaker.
- Trigger a metadata-only refresh where stable item IDs gain or change artwork, added dates, favorites, last-played dates, or play counts. Verify visible rows and active sorting update without a relaunch or unrelated identity change.
- Sort merged artists and playlists by every aggregate field they expose. Their position must use the count, duration, or latest date displayed by the merged row rather than one constituent source.
- Open a merged artist that exists in both sources. Apple sections must be library-scoped, identify the Apple library correctly, and separate albums, EPs, and singles without expanding into the artist's entire catalog.
- Check same-named and colliding-ID media across sources. Navigation, artwork, favorites, playlist membership, and mutations must remain source-scoped.
- Verify Recently Added, Recently Played, and Most Played use explicit normalized hub semantics, merge eligible sources, deduplicate correctly, and sort globally rather than in provider-sized blocks.

Search and catalog:
- Before focusing Search, verify no Library/Apple Music scope tabs are shown. Focus the field with Apple Music enabled and verify the Apple-style scope tabs appear; remove/disable Apple Music and verify the extra scope disappears.
- Search Library and Apple Music for the same term. Verify category previews expose Show All when more results exist, the expanded view is not capped at the preview count, and switching/clearing scopes does not leave stale results.
- Play an Apple catalog song that is not yet in the library. It must remain the selected/playing item instead of immediately skipping, and artwork plus normalized Now Playing metadata must populate.
- Open row swipes and context menus in both scopes. Play Next/Last availability must respect the active playback engine; Add to Library appears only for eligible catalog items and disappears or updates after confirmed convergence.
- Mutate the Apple library, return to Search, and verify Search remains usable while refresh/sync occurs. Inventory caches before and after repeated catalog searches: search artwork must use bounded transient caching and must not create durable library-artwork entries, while synced library artwork remains reusable by browse and detail surfaces.

Playlists and merging:
- Verify Apple playlists populate with artwork and merge with same-named Plex playlists across source types. Open the merged playlist and confirm each source remains identifiable and its unsupported mutations remain disabled.
- Compare one user-created Apple playlist with one Apple editorial/generated playlist. Classification and action availability must follow item-level capabilities: editable content is a regular playlist; curated/generated read-only content may be presented as smart/read-only.
- Open Edit on a merged playlist. Every contributing source appears in the source picker; unsupported operations stay visible but disabled with their reason.
- With disposable data and explicit mutation authorization, create an Apple playlist, add Apple songs, reorder/rename where the provider reports support, and confirm the optimistic local state, remote Apple Music result, and eventual reconciled state. Record acceptance and convergence timing; an older refresh must not roll back the optimistic mutation. Keep Plex tracks disabled as Apple-playlist targets.
- Exercise add-to-playlist from Search, track rows, albums, Queue/History, mini-player, and Now Playing. Verify compatible targets, duplicate handling, recent-target updates, delayed success feedback, and provider-scoped refresh.

Now Playing and media actions:
- Compare a Plex track and an Apple Music track in mini-player and Now Playing. Artwork must populate in Controls, Queue, Lock Screen/Control Center, and source-aware info surfaces.
- For Apple Music, verify the progress treatment remains continuous when no waveform exists, the waveform does not falsely animate, Lyrics explicitly reports unsupported, and Get Info agrees with the Now Playing Info card.
- Verify normalized Source/Server/downloaded-state values. A downloaded Apple item may report device availability, while Server remains Apple Music; unsupported file/codec metadata must be disabled rather than spun indefinitely.
- For an Apple catalog song outside the library, verify Add to Library from both its context menu and Now Playing. Confirm the remote mutation and refreshed action state.
- Verify an existing Apple favorite shows a filled heart in rows and Now Playing. Favoriting through Ensemble must add the song to Apple's Favorite Songs; unfavorite remains disabled with a provider-managed explanation while the public API lacks that action.
- Share an Apple song and verify Ensemble still resolves through its song.link flow, with the Apple Music URL/plain text used only as fallbacks.
- Open SmartMix settings with Apple Music configured and verify the cross-service transition limitation is disclosed.

Playback engine affinity and continuity:
- Establish audible/system-progress baselines with one Plex track and one Apple Music track before diagnosing mixed-source behavior.
- Queue at least two consecutive Apple tracks. With SmartMix off, verify MusicKit-owned continuity; with SmartMix on, verify the configured Apple crossfade where the OS supports it. Never require or attempt an Apple-to-other-service crossfade.
- Start a mixed candidate collection such as shuffled merged Favorites. The first playable track selects the engine; incompatible queue items are removed before playback, the Queue title/card discloses the removed count, and all remaining items use the selected engine.
- Repeat the mixed shuffle until Plex starts first and until Apple Music starts first. Verify both filtering directions and confirm music never pauses merely because incompatible candidates existed.
- With playback active, verify incompatible Play Next/Play Last actions are disabled. Mutate the compatible queue through Play Next/Last, reorder, remove, and destructive replacement; confirm playback state, current-item identity, warning count, and persisted queue stay coherent.
- Background or lock the phone before a real track boundary. Audio and system Now Playing progress must continue into the next compatible track without relying on a cross-engine handoff.
- At queue end, verify provider-matched autoplay: Plex uses Plex recommendations and Apple Music uses an Apple station/recommendation seeded from the final Apple track. Generated tracks must become visible in Queue, avoid duplicates, and never switch playback engines silently.
- Exercise pause/play/skip during Apple queue preparation and rapid queue replacement. Stale MusicKit completions must not resume, pause, stop, or replace newer user intent.

System integrations:
- Route both providers through AirPlay, then return to the device route. Verify controls, elapsed time, current item, and queue survive the route change.
- Invoke a representative Siri request for Apple-only, Plex-only, and ambiguous content when available. Confirm enabled-source scoping, selected provider, queue affinity, and background playback.
- Treat watchOS as an iPhone remote for Apple playback unless its policy changes; do not require Apple library data to be synced into the Watch UI.

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
- Downloads: libraries section, items section, pending mutations if present, Download Manager settings. When a physical-device download sweep is requested and local download mutation is authorized, run [physical-download-sweep.md](physical-download-sweep.md).

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
