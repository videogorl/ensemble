# Step 0 verification

Date: 2026-10-13. Plan: [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
step 0. Checklist: [`surface-checklist.md`](../reference/surface-checklist.md).

Step 0 is **not verified**. The Mac pass is complete. The iPhone
rows were run on a simulator because the physical iPhone pass is on hold by
Felicity's decision; simulator results do not satisfy plan section 7.

## Build under test

- Source commit: `254691f2` on `develop`.
- Built app: `/tmp/ensemble-codex-derived/Build/Products/Debug/Ensemble.app`,
  Debug, macOS arm64, built through `scripts/build_serial.py`.
- Version `0.4.0 (202610131108.7746)` in the built `Info.plist`; the running
  app's Profile > About row showed the same string.
- Launched by path with `open -n`. The PID's executable path was the built
  app's `Contents/MacOS/Ensemble`, started after the binary's modification time.

## Builds and tests

| Check | Result |
|---|---|
| macOS build at `254691f2` | Succeeded |
| iOS Simulator and watchOS Simulator builds at `254691f2` | Succeeded |
| EnsembleCore tests | 1,160 run. Two `PlaylistDetailViewModelTests` cases failed in the full run and passed when run alone: `testCreateFeedbackPreservesAccountIdentityAndEachBatchRetry`, `testPlaylistAddFeedbackPreservesActualCountsAndNavigation`. Both report an offline state leaking from another test |
| EnsembleUI tests | 125 run, 0 failures |
| EnsembleDomain, EnsembleSiriShared, EnsembleWatchCore tests | 14, 24, and 33 run, 0 failures |

Before this pass the Core test target did not compile: `1f6da3eb` removed
Persistence methods that Core test wrappers still called. Four UI tests also
predated the track radio and shuffle-from-track menu actions. Both are repaired
in `254691f2`.

## Mac

First pass driven through accessibility actions with the app in the background;
second pass, with Felicity's go-ahead, with real pointer and media-key input on
a relaunch of the same built app.

| Surface | Result | Evidence |
|---|---|---|
| Launch and readiness | pass | PID path and version as above; window showed sidebar, pins, and the restored mini player. Feed showed "Loading..." for about 40 seconds on both cold launches before hubs appeared, see below |
| Sidebar | pass | Search, Home, Songs, Artists, Albums, Genres, Favorites, a pinned playlist, album, and artist each highlighted and showed their screen |
| Browse split | pass | Artists: selecting ABBA, then Adele, changed the detail pane while the list kept its place |
| Songs table | pass | Rendered with artwork. Double-click played the row (`firstAudibleRender` logged, speaker glyph on the row). Right-click listed Start Track Radio through Hide |
| Detail screens | pass | Album (Fantasies), artist (alt-J), and merged playlist (Ambient Electric) rendered header and tracks. Album Play started playback: `firstAudibleRender` logged 645 ms after the press and the mini player showed track 1 |
| Feed | pass | Hubs rendered with artwork; a Recently Added card opened its album. Scroll readability not checked |
| Search | pass | A recent search returned Artists, Albums, and Songs sections. Typing was not exercised |
| Mini player | pass | Next advanced to track 2. Nothing overlapped at 1100 and 1500 points wide. Width below 1100 not confirmed |
| Now Playing | pass | Clicking the mini player opened it. Queue, Lyrics, and Info each rendered; Forward and Pause changed state; Close restored the toolbar and sidebar |
| Menu commands | pass | Playback > Play/Pause paused playback. View > Refresh was accepted; no log line distinguishes it, so its effect is unconfirmed |
| Profile window | pass | Every section rendered. Logs listed the current session and opened it with lines from this run |
| Downloads window | pass | Library rows rendered; one row drilled in and went back. Nothing was toggled |
| System Now Playing | pass | System Play/Pause and Next media keys reached Ensemble: logs show `remote toggle command received`, the next track, then paused. The Control Center tile was not looked at |
| Share and song.link | pass | The first attempt raised the Apple Music access prompt, which Felicity allowed. Share Link then opened the sharing picker for the track with AirDrop, Mail, Messages, and Copy. The URL itself was not read |

## iPhone rows on a simulator

Physical iPhone rows are all `not run`: the device pass is on hold. The rows
below ran on simulator `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1` (iPhone 17 Pro,
iOS 26.5), which already held a signed-in Plex library.

- Prepared with `scripts/prepare_runtime.py`; run directory
  `/tmp/ensemble-step0-sim`. Source commit `3a6a32fb`, clean tree.
- Build `0.4.0 (202610131144.3632)`; the helper matched the installed
  executable hash and the PID's path, and Profile > About showed the same build.
- Driven with the `agent-device` CLI pinned to the UUID, plus debug routes.
- Simulator shut down afterwards and confirmed `Shutdown`.

| Surface | Result | Evidence |
|---|---|---|
| Launch and readiness | pass | Feed showed hubs with the restored mini player |
| Tab bar shell | pass | Feed, Artists, Playlists, Search, More each showed their root |
| More and Edit Tabs | partial | Songs opened from More. Edit Tabs opened once by accident and was closed; tabs were unchanged. Other rows reached by debug route, not from More |
| Feed | partial | A Recently Added card opened its album. Hub scrolling and the order sheet not checked |
| Songs | partial | List rendered with artwork. Chip filter and row tap not exercised: accessibility snapshots of this screen timed out |
| Albums | pass | Filter sheet opened and closed; an album opened |
| Artists, Artist detail | pass | Artist detail (Metric) rendered header, counts, and albums |
| Playlists, Playlist detail | pass | Playlist opened; tapping a track started playback (system Now Playing log `state=playing`) |
| Genres | pass | Genre list rendered; Blues opened |
| Favorites | pass | Rendered with 278 tracks |
| Album detail | pass | Header and track rendered; Play logged `firstAudibleRender` |
| Search | pass | Typing "metric" returned Artists and Albums sections; the artist result opened |
| Mini player | pass | Pause and Play changed state; present on every tab visited |
| Now Playing: controls | pass | Elapsed advanced 0:14 to 0:20 after Play |
| Now Playing: queue, lyrics, info | pass | Queue page with its toggles, "No Lyrics Available", and filled Info rows |
| Share and song.link | pass | Share Link opened the share sheet with the track; the URL itself was not read |
| Downloads | pass | Library rows rendered; nothing toggled |
| Profile | pass | Sources, playback rows, Storage, Reset, Developer, and About rendered |
| Settings subpages | partial | Audio Quality opened. The other five not opened |
| Storage | pass | Clear Artwork Cache showed its confirmation; Cancel dismissed it and no clear was logged |
| Add Source | pass | Plex and Apple Music options shown; cancelled |
| Logs | pass | Current session listed and opened with lines from this run |
| Toasts | pass | Test toast appeared above the Profile sheet |

Not run on the simulator: Hidden, Moods, Pins, Item info, Now Playing dismiss
and go-to, StageFlow, Song permalink, Download manager settings, Music source
detail. Not possible on a simulator: Lock Screen, Control Center, Background
playback, Offline playback, Siri, App Shortcuts, Focus filter, Spotlight.

## iPad, Apple Watch

All rows `not run`. Neither is approved until steps 5 and 6.

## Observations

- **Feed stays on "Loading..." for about 40 seconds after a cold launch** on the
  Mac, although a last-good hub snapshot exists. Not compared against
  `pre-step-0`, so it is unknown whether step 0 changed it.
- **Walking the Songs accessibility tree stalls artwork.** An AppleScript
  `entire contents` walk of the Songs table made it resolve artwork for
  thousands of rows; artwork then showed placeholders on every screen for
  minutes. A relaunch cleared it. This may affect assistive-technology users
  with large libraries.
- **Songs accessibility on the simulator.** A snapshot of Songs exceeded the
  test runner's watchdog and held the app above 100 percent CPU. Same cost as
  the Mac walk above.
- **Queue order differs from the Songs list on the Mac.** After playing
  "(Anesthesia) – Pulling Teeth" from Songs, Next went to "(Big) Wish" while
  the list shows "[Anthems]" next. The list and the queue appear to sort
  punctuation differently. Not investigated.
- **Share Link on the Mac asks for Apple Music library access.** This is by
  design: `SongLinkService` resolves the item in the Apple Music catalogue
  before calling song.link. The denied path was not exercised.
- The Mac's network switched between Ethernet and Wi-Fi several times during
  the run. The app logged each switch and recovered.

## Still owed for step 0

1. iPhone surface pass on the iPhone 16 Pro through Device Hub. On hold.
