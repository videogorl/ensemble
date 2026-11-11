# iPhone SE checks through Device MCP, 2026-11-11

Build `202611110741.9140` (`refactor/apple-music-library-writer` at `9140f772`, which includes `develop`),
iPhone SE 2 on iOS 27.2, Wi-Fi, no SIM. Three checker agents drove the phone with Device MCP (taps, drags,
hardware buttons, the accessibility tree) and debug links sent with
`xcrun devicectl device process launch --payload-url`. Their reports follow unedited. Network checks used
Wi-Fi off and on, not Airplane Mode.

Lead's corrections after the runs:

- Group C's "Artists lists one artist, Playlists lists one playlist" was a saved filter, not lost data: the
  store held 674 artists and 50 playlists, and `Ensemble.FilterOptions.Artists` / `.Playlists` held
  `searchText` "Metric" / "Foc". Both were cleared afterwards. See `ON_DECK.md`.
- Group B toggled Favorite on the Plex track "Gimme That Swing!" by a mistimed tap and toggled it back.


## Group a report

# Group A (Plex): system media controls, network, errors  (build 202611110741.9140, iPhone SE)

| Check | Result | Evidence |
|---|---|---|
| A1 relaunch/resume | Passed | launch_app restored 14291 paused; Play, then Lock Screen 22 s -> 31 s of 4:51 (advancing). Next in app (Fall Away), Lock Screen followed: Fall Away 0:09 playing |
| A2 Lock Screen transport | Passed | Next -> The Pantaloon 4 s, advancing to 11 s; Pause -> Play button, pos frozen at 12 s over 4 s; Play -> 18 s, Pause shown |
| A3 halt | Partly | Queue [14291 seeked to 275 s, 11631, 11700, 14292] at medium: 11631 failed 1 s after start (invalid audio data), skipped to 11700, HTTP 400, halted. Lock Screen: Noah's Descendants, position `-:--`, Play button present but DISABLED. App: one persistent toast "Playback stopped / Server returned HTTP 400 / Retry" (survived lock/unlock); mini player shows title + Play, no error text. Retry then Pause at once (about 0.3 s apart) did NOT stay paused: retry took 1.8 s (engine recreate), 11700 failed again, skipped to Fall Away, which played (log: no pause event). Retry target always fails, so cannot separate "pause lost" from "skip-on-fail"; suspected pause was swallowed while loading |
| A4 skip toast | Passed | [11700,14292,14293]: toast "Skipped Noah's Descendants, Server returned HTTP 400" (id toast.banner), Fall Away playing |
| A5 end of queue | Passed | repeat off, autoplay off: 14293 seeked to 200 s, ended: app mini player shows The Pantaloon + Play (paused); Lock Screen: The Pantaloon, Play, Next disabled, position 0:00 (reset to start) |
| A6 Repeat One + Lock Screen Next | Observed | autoplay off, repeat one, last item of 3: Lock Screen Next Track is DISABLED; tapping did nothing, Pantaloon kept playing (13 s -> 19 s). No wrap seen. Separately with autoplay ON + repeat one + last item, Next went to an autoplay track (Technicolor Girls) |
| A7 Lock Screen vs app position | Passed (loose) | Lock Screen values tracked playback during A1/A2; one exact side-by-side not taken |
| A8 Control Center Next | Passed (caveat) | control_center gesture exposed a full-screen Now Playing page (page 1 of 2) that looks like Lock Screen-style media UI; Next there: Implicit Demand -> Fall Away, playing. Could not tell it from the Lock Screen |
| A9 network drop mid-stream | Passed | Wi-Fi off (not Airplane): 11741 FLAC original, 7.2 of 18.3 MB: log `dropped -1005` 07:57:20, Wi-Fi back 07:57:31, `resumed offset=7159808 sinceDrop=14.44s` 07:57:34; track kept playing, no skip, position 0:25 at about 28 s wall time. Earlier attempts hit the successor prefetch only (resumed after 12 s / 20 s, current track unaffected) |
| A10a Next during drop | Failed vs checklist | 14291, drop, Next while offline: The Pantaloon at 0:00, halted, toast "Playback stopped / No internet connection / Retry". After Wi-Fi returned it did NOT start by itself (consistent with A12); Retry then played from 0:05 |
| A10b Pause during drop | Passed | paused at 0:02 offline, Wi-Fi back, 10 s later still 0:02 paused; Play resumed (0:03 after 6 s, 0:12 after 11 s, so a slow ~5 s restart) |
| A11 offline blocked track | Passed w/ note | Wi-Fi off, play 7278,7631 (force-stream): both failed, halted on 7631 at 0:00, nothing played. Toast text: "Playback stopped, Network error: The operation couldn't be completed. (NSURLErrorDomain error -1004.), Retry" (raw system text, not an "unavailable" message) |
| A12 halt stays halted | Passed (variant) | Halted on offline failure; Wi-Fi on, 15 s later still halted, same toast. Done on a network halt, not on 11700 |

## Odd / suspected
- Lock Screen Play button is disabled while halted (A3); Next disabled on last item with repeat one (A6).
- Retry + immediate Pause is not honoured (A3), see above.
- Offline toast text is a raw NSURLError string (A11); a different one ("No internet connection") appears when Next is pressed offline (A10a).
- Launch-argument overrides (-isShuffleEnabled etc., -streamingQuality) WERE written back to the preferences plist (shuffle ended Off, quality original) - the suite note about write-back is still true.
- devicectl with `--payload-url` before the app is active delivers the link only when the app becomes active (a link sent while the app sits behind Settings plays late).

## Tooling
- open_url needs an interactive Device MCP approval; unanswered -> blocked. Used `xcrun devicectl device process launch --device UDID --payload-url 'ensemble://debug/...' com.videogorl.ensemble` instead (no relaunch of a running app, same pid; add `--terminate-existing --environment-variables '{...}' ... -- <app args>` for an automation launch; the `--` is required before dash-args).
- batch_commands steps take no `device` argument. Probe element not exposed by list_elements; used the app UI, Lock Screen tree and session logs.
- Lock Screen button true coordinates: Previous (107,552), Pause/Play (177,552), Next (248,552).
- Wi-Fi toggle on Settings > Wi-Fi at (309,325); open_settings page wifi is quick. The app then needs a link (now-playing?page=controls) to return; launch_app restarts it.
- forceNetworkStream does not ignore the stream cache: fully-played tracks are `cachedFile origin=streamCache`; the 8731 delay env only delays the first request; downloads of a 50 MB WAV finish in 16 s, so drops need to start within ~4 s of play to hit the current track.
- Phone auto-locks while idle (about 30 s); a Control Center gesture then shows the Lock Screen media UI.

## Cleanup
Paused, Wi-Fi on and connected (LondonFog), Airplane never used, Ensemble Shuffle On / Repeat Off / Smart Mix On / Autoplay On (read back in queue page), streaming quality medium (plist), phone locked, device lock released.


## Group b report

# Group B (Apple Music) report
B1 Passed: Gimme That Swing! (Plex 3:53) -> Her Majesty (AM, shown 0:24) -> Fly Free (Plex 6:05) -> Polythene Pam (AM 1:12) -> Complicate You (Plex 4:43); each advanced by itself, AM durations were AM's.
B2 Passed: locked, Complicate You -> Her Majesty (Lock Screen "4 of 25 s", then 14 s) -> Stand By Me (Plex, 3:31, 4 s). Position advances.
B3 Partly: app round OK (play+pause within a tap, still paused at 0:01; resume moves 0:06). Lock Screen round OK (pause, quick play/pause, play: 5 s -> 12 s). Next-track-at-end not conclusive (see odd 1).
B4 Partly: shuffle off->on during Hotel California: 0:11 -> 0:19, no restart. Single-item queue so Up Next order not observable.
B5 Partly: single-item queue, Lock Screen Previous at ~49 s -> position 1 s (restart); second press within 3 s -> still 1 s (restarted again, no earlier track). Earlier via debug links on a multi-item queue (1 s apart): two previouses went to the previous track.
B6 Passed: Her Majesty last, autoplay off, repeat off: ended at 0:00, paused, same track.
B7 Passed with note: Polythene Pam last, Repeat All, autoplay on: wrapped to Fly Free (Plex), the first item of the session queue incl. history, not the AM item queued before it; no station started.
B8 Passed: Hotel California single item, autoplay on: next Who'll Stop the Rain (AM catalog, "Add to Library" offered), Up Next shows Mary Jane's Last Dance; Previous x2 back to Hotel California, queue rows Who'll Stop the Rain + Mary Jane's, no duplicates.
B9 Partly: AM Now Playing More menu: AirPlay, Favorite, Add to Playlist, Go to Album, Go to Artist, Share Ensemble Link, Share Link. (Plex context menu additionally: Go to Album/Artist, Share Audio File; Plex Now Playing menu not captured.) AM context menu adds Get Info, disabled Edit Metadata, Hide.
B10 Partly: "Plays" is on the Now Playing Info page. Her Majesty Plays = 0 before; I played it to the end, ran sync?mode=full (syncStarted 08:15:14, syncFinished 08:15:25), but did not re-read the counts (budget). Note it showed 0 even after earlier natural plays.
B11 Partly: mini player and Now Playing titles matched on Who'll Stop the Rain; AM -> Plex/back Next/Previous not cleanly verified.


## Group c report

# Group C (iPhone SE, build 202611110741.9140)
| Check | Result | Evidence |
|---|---|---|
| C1 | Passed | Her Majesty Plays = 6; Hotel California Plays = 1 (Info page, both Apple Music) |
| C2 | Passed (partly) | Genre chip "Alternative" -> 1 song (Tame, Mint Julep), cleared via x; speaker indicator moved Hotel California -> Take On Me; Title sort has A-Z/# index; last row sits above mini player ("13,313 songs" footer); fast scroll kept titles/art; pull-to-refresh spinner, no jump. Not separately confirmed: indicator across refresh |
| C3 | Passed | Leading: Play Next, Play Last. Trailing: Add to Playlist..., Favorite (Songs, album, playlist). Long-press: Start Track Radio, Shuffle from Here, Play Next, Play Last, Add to Playlist..., Add to <playlist>, Favorite/Unfavorite, Go to Album, Go to Artist, Share Ensemble Link..., Share Link..., Share Audio File..., Get Info... (album rows omit Go to Album). Album shows track numbers; no multi-disc album found. Search songs row not swiped (same row component) |
| C4 | Partly | More: Songs, Albums, Genres, Favorites, Hidden, Downloads open/back; Edit Tabs not opened |
| C5 | Passed | Hub scrolls sideways; Edit sheet (Reset.../Done, no Cancel) dismissed by swipe down |
| C6 | Partly | iCloud Sync, SmartMix, Download manager settings (Manage Downloads) open/back. Merging, Connection Security, Track Swipe Actions, Music source detail not run |
| C7 | Partly | Hidden: "Nothing Hidden" empty state. Album Get Info OK. Track Get Info did nothing (see odd). Artist menu has no Get Info. Moods/Pins not found |
| C8 | Partly | Album, playlist ("focus", 27 songs, 2 sources, artwork), merged artist (The Beatles, 2 sources) open; collapsing title appears; Sort/More menus open; playlist track plays. Genre/Favorites/Mood not run; hero flash not judged |
| C9 | Partly | Albums sort/filter ok, sort restored to Title asc (Hide Singles filter on by default); Artists, Playlists, Genres see odd |
| C10 | Partly | Swipe-down dismiss works; queue shows "Continue Playing" with title/artist/art; History shows Dalaran; shuffle/repeat toggles work (end: Shuffle On, Repeat Off, SmartMix On, Autoplay On). Lyrics: "No Lyrics Available" on current track; Go to Artist from NP not run |
| C11 | Partly | Play Last twice -> two Echoes Of Mine rows at end; Remove from Queue removed only Intro. Drag reorder: not run (3 drags, no effect) |
| C12 | Passed | Landscape shows StageFlow, no nav bar, track panel opens, portrait restores grid. (StageFlow started on first album as grid was at top) |
| C13 | Partly | Share Link... sheet titled "(Anesthesia)—Pulling Teeth, Metallica, Apple Music"; pasted URL: https://music.apple.com/us/album/anesthesia-pulling-teeth/579146130?i=579146164 (not song.link). No permalink route documented -> not run |
| C14 | Not run | Shortcuts app is not installed on this phone (absent from list_apps). Unblock: install Shortcuts |
| C15 | Passed | Focus -> Do Not Disturb -> Add Filter lists "Ensemble, Playback & Libraries"; Cancel |
| C16 | Passed (none) | Downloads lists only 3 libraries (Hiigel-Server Music 12/9696, Minibar Christian Music 1/439, Minibar Music 3595/3597); no playlist targets. Minibar Music detail shows 2 failed items (Retry not tapped) |

## Odd
- Confirmed: Artists tab shows only "Metric, 2 sources / 1 artist" and Playlists tab only "focus"; Beatles artist exists elsewhere. Possibly paging/scope; reproduce: tap Artists tab.
- Confirmed (3 tries): track-row "Get Info..." does nothing (Abbey Road track, Anesthesia); album Get Info works.
- Suspected: Songs list does not re-sort after switching sort Title -> Date Added in-screen (stayed "!!!!!!!" first) until the screen is reopened.
- Suspected: after Play (Her Majesty) Plays=6 though earlier read 0.
- Suspected: playback jumped to "¡viva La Gloria!" after an index tap / drag-close swipe; unintended row taps.
- Shuffle was Off at start; set On then restored per instruction.
## Mutations
None intended. Tapping a Songs index letter played a track (A.I. Theme); several tracks played. Clipboard (copy) used for Share URL. Songs sort restored to Date Added desc, Albums to Title asc, Artists to Name.
## Tooling
get_clipboard needs approval (2 min stall). Swipe from y<=60 pulls Notification Center; swipe from the sheet's header area to dismiss. Index letters need drag, not tap. Merging row hidden under nav bar after scroll.
## Cleanup
Playback paused (app relaunched), portrait, locked (lock screen confirmed), lock released next.


## Group d report (Shortcuts, queue row touch targets)

# Group D (iPhone SE, build 202611110741.9140)
## Part 1 App Shortcuts: BLOCKED/FAIL (Ensemble absent from Shortcuts)
- Shortcuts: Apple's Shortcuts redownloaded from App Store with no password prompt (cloud button, ~15 s). It is a system bundle (com.apple.shortcuts) so list_apps(include_system=false) does not list it; launches fine.
- Shortcuts > Library > Apps lists only Audible, Files, Sonnet. Ensemble is NOT listed, even after relaunching Ensemble (12 s), killing/relaunching Shortcuts. Gallery/Spotlight "Play album" show no Ensemble App Shortcut either. No shortcut run possible; the five expected names (Play Track, Play Album, Play Artist, Play Playlist, Open Media) could not be seen on device.
- Local build Metadata.appintents (stale DerivedData Jul 13) does contain the five shortTitles, so the provider compiles; the device is not surfacing them. Unverified: whether the installed Debug build contains Metadata.appintents.
## Part 2
Frames (pt): Up Next row 20,y,311x68 (rows at y=185.5, 253.5, 321.5, 389.5; pitch 68); Track Actions button 20x20 at (289,y+24); Reorder handle 24x68 at (315,y) (full row height, 24 wide). Apple min 44x44: Track Actions fails (20x20); handle fails in width (24).
Tap test (current track watched): exact centre of Track Actions: 3/3 menu opened. 5 pt left, right, above, below the glyph edge: 4/4 row played instead (no menu).
Drag (handle centre row 2 -> row 4, 1000 ms, plus 2500 ms): hold 0 = no effect; hold 0.2 = reorder but WRONG: row 2 moved to row 1 (swap rows 1/2), not to row 4; hold 0.6 (x2, 1000 and 2500 ms) = same swap of rows 1/2. Never a menu, never played. Next after reorder played new row 1 (correct, order consistent, titles matched rows).
Code: Packages/EnsembleUI/Sources/TrackLists/QueueTableView.swift: contextMenuButton lines 18, 59-64, 89-92 (UIButton .system, width/height = TrackListLayoutMetrics.queueDragHandleDimension = 20, Packages/EnsembleUI/Sources/DesignSystem/TrackListLayoutMetrics.swift:28; trailing -rowTightAccessoryGap; no contentEdgeInsets/hitTest/point(inside)/expanded area). Handle is UITableView's system reorder control: setEditing(true) line 221-222, canMoveRowAt 586, moveRowAt 594, targetIndexPath 598; row selection didSelectRowAt 514 with allowsSelectionDuringEditing = true (so a miss plays the track); also dragInteractionEnabled + dragDelegate itemsForBeginning 628. SwiftUI QueueCard.swift:375 is a different (non-iOS-queue?) row.
Mutation: while dismissing the first menu I tapped the Dismiss element's centre (187,333) which hit "Add to Playlist..."; a later tap picked "peace" -> "Create missing playlist?" dialog; I tapped Cancel, closed the sheet. Nothing created. Queue playback state changed (tracks played) only.
Cleanup: paused, Shuffle On, Repeat Off, SmartMix On, Autoplay On, phone locked (lock screen confirmed).
