# Step 0 verification

Date: 2026-10-13. Plan: [`rearchitecture-plan.md`](../reference/rearchitecture-plan.md)
step 0. Checklist: [`surface-checklist.md`](../reference/surface-checklist.md).

Step 0 is **not verified**. The Mac pass is partial and the iPhone pass has not
run.

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

Driven through accessibility actions and per-window captures, with the app in
the background. Rows that need a real pointer or keyboard are `not run`.

| Surface | Result | Evidence |
|---|---|---|
| Launch and readiness | pass | PID path and version as above; window showed sidebar, pins, and the restored mini player. Feed showed "Loading..." for about 40 seconds on both cold launches before hubs appeared, see below |
| Sidebar | pass | Search, Home, Songs, Artists, Albums, Genres, Favorites, a pinned playlist, album, and artist each highlighted and showed their screen |
| Browse split | pass | Artists: selecting ABBA, then Adele, changed the detail pane while the list kept its place |
| Songs table | not run | The table rendered with artwork. Row play and the context menu need pointer input |
| Detail screens | pass | Album (Fantasies), artist (alt-J), and merged playlist (Ambient Electric) rendered header and tracks. Album Play started playback: `firstAudibleRender` logged 645 ms after the press and the mini player showed track 1 |
| Feed | pass | Hubs rendered with artwork; a Recently Added card opened its album. Scroll readability not checked |
| Search | pass | A recent search returned Artists, Albums, and Songs sections. Typing was not exercised |
| Mini player | pass | Next advanced to track 2. Nothing overlapped at 1100 and 1500 points wide. Width below 1100 not confirmed |
| Now Playing | not run | The mini player did not respond to an accessibility press or a background click |
| Menu commands | pass | Playback > Play/Pause paused playback. View > Refresh was accepted; no log line distinguishes it, so its effect is unconfirmed |
| Profile window | pass | Every section rendered. Logs listed the current session and opened it with lines from this run |
| Downloads window | pass | Library rows rendered; one row drilled in and went back. Nothing was toggled |
| System Now Playing | not run | Needs Control Center interaction |
| Share and song.link | not run | Needs a pointer-opened menu |

## iPhone, iPad, Apple Watch

All rows `not run`. `devicectl` listed the iPhone 16 Pro as `unavailable`
throughout. The iPad and watch are not approved until steps 5 and 6.

## Observations

- **Feed stays on "Loading..." for about 40 seconds after a cold launch** on the
  Mac, although a last-good hub snapshot exists. Not compared against
  `pre-step-0`, so it is unknown whether step 0 changed it.
- **Walking the Songs accessibility tree stalls artwork.** An AppleScript
  `entire contents` walk of the Songs table made it resolve artwork for
  thousands of rows; artwork then showed placeholders on every screen for
  minutes. A relaunch cleared it. This may affect assistive-technology users
  with large libraries.
- The Mac's network switched between Ethernet and Wi-Fi several times during
  the run. The app logged each switch and recovered.

## Still owed for step 0

1. iPhone surface pass on the iPhone 16 Pro through Device Hub.
2. The four `not run` Mac rows, with pointer and keyboard input.
