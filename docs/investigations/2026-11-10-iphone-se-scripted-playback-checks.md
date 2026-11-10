# iPhone SE scripted playback checks, 2026-11-10

Results of `PhonePlaybackAcceptanceUITests` on the physical iPhone SE. This is
the evidence for the items removed from
[`physical-device-backlog.md`](../reference/physical-device-backlog.md) on
2026-11-10. The build under test was `develop` at `43d7ff18` plus the DEBUG
automation hooks. Evidence paths are in the system temp folder and are not kept.


Device UDID 00008030-00090C493C13402E, on a cable, Plex only. Branch `test/iphone-se-playback-checks`.
Commits (local, signed): a2030ad6, 04a6f9f0 (hooks), de67a060 (test class, pbxproj, probe `net=` field).
Evidence root: `$TMPDIR/se-playback/` (`results/batch1..9/` each with xcresult, attachments/manifest.json, session logs; `archive/` holds every session log seen, since the app keeps only 5).
A check passes only on what the test or the journey log observed.

## Build identity
Final build in `$TMPDIR/se-playback/DD` (Debug-iphoneos): CFBundleShortVersionString 0.4.0, CFBundleVersion 202611100350.0469.
`devicectl info apps` on the phone reports the same 0.4.0 / 202611100350.0469.
sha256 Ensemble c82d123ff0db73dc20f7ae5a96c608bda9bd4dd0724a51ae5608f50ab4f6f25f, Ensemble.debug.dylib d58aa2e8feec59439ab5980b8a1cd8cd2fd2a91464a72526cad2a7b1043cff43.
Every run restarted the app (distinct pids in the timelines).
(Batch 9 rebuilt only the test bundle with the ZZ9 change; the app binary is unchanged.)

## Results (status / backlog area / test / evidence)
Evidence paths are under `results/<batch>/attachments` (timeline_*.txt per test) and `archive/session-*.log`.

| Item | Status | Test | Observation |
|---|---|---|---|
| G1 WAV 8731 to natural end (default quality) | PASS | G1a (batch4) | `transcodedHTTP` mp3, played 3:02 to the end, 8732 advanced as `cachedFile origin=streamCache`; no crash |
| G1 WAV original quality, direct PCM (fix d735bf26) | PASS (with a finding) | G1b (batch3), G1g (batch6) | G1b: `kind=directHTTP ext=wav`, PCM decoded and playing. G1g (single track, no successor to prefetch) passed through the natural end in 204 s. Finding in G1b only: `failed after startup NSURLErrorDomain:-1005` at exactly bytes=5242880 of 50699330, twice, then fell back to `transcodedHTTP` and finished. Hypothesis: concurrent prefetch of 8732; G1g did not reproduce it |
| G1 MP3 20 s+ | PASS | G1c | `transcodedHTTP` mp3 |
| G1 AAC 20 s+ | PASS | G1d | network stream |
| G1 FLAC 20 s+ (default and original) | PASS | G1e, G1f | original = `directHTTP` flac |
| G2 11631 non-original (6afaad0b) | PASS | G2a | two quick retries ("invalid audio data"), `ITEM_FAILED ... skipping to idx 1`, next track played, no spin |
| G2 11700 fails once, no loop | PASS | G2b, G2c | HTTP 400 / engineLoadFailed once, `halting`, stays failed |
| G2 twenty one pilots 14291-14293 at original | PASS (behaviour recorded) | G2d1-3 | `directHTTP` flac, each played to its end, no retries or skips; the expected corrupt-frame behaviour was not observed. 14294-14304 were not run |
| G3 pause/resume after gapless | PASS | G3a | three `via gapless`, continuity, no "Ignoring render clock" |
| G3 pause/resume after gapless, locked | PASS | G3b (batch8) | after lock and advance, Pause then Play on the controls, resume continued (log: locked pause 03:52:46, resume 03:52:56); but see "lock method" |
| G3 relaunch-resume into gapless | PASS | G3c | gapless advance idx1 to idx2, no "dropped native" |
| G3 paused Next/Previous/Play | PASS | G3d | |
| G3 relaunch then Next within 3 s | PASS | G3e | |
| G3 autoplay off while an autoplay track plays | PASS | G3f | |
| G3 SmartMix cancel | PASS | G3g (batch7) | tracks from different albums (SmartMix skips same-album transitions): crossfade began at pos 353.3 of 365.5, SmartMix turned off, `mix` went false immediately, the outgoing track kept playing and the queue advanced to idx 1 |
| G3 AirPlay with Garage HomePod | NOT RUN (route selection) | G3h (batch6) | Control Center AirPlay picker opens (screenshot attached, `airplay-route-picker`), but the test's query listed no receivers, so it cannot select one. No route changed; audio stayed on the speaker |
| Step 1b queue policy: end of queue, repeat-one wrap, shuffle toggle | PASS | G4a, G4b, G4d | end of queue paused at 0:00 with queue kept; Repeat One wraps on Next; shuffle toggle keeps the track playing |
| Step 1d: failed track while locked skips once then halts | PASS | G4c (batch8) | real damaged files 11631, 11700 behind 8728: halted at idx 2 after unlock. The startup-stage failure injection is bypassed by gapless prefetch (G4c batch7), so this was changed to real files |
| Step 1d: Lock-controls Next/Pause during a load | PASS | G4e, G4f (batch8) | see "lock method" |
| Step 1e G17 (stream-cache item plays with the network down) | PASS | G4h | played, probe `net=offline` |
| Step 1e G18 | PARTIAL | G4g | paused stream, network off/on, Play resumed in 1.3 s at the same position. No SIM, so the Wi-Fi-to-cellular switch was not exercised |
| Stream drop mid-playback recovers | NOT RUN (invalid) | G2e | Control Center gestures take 60-120 s each on this phone, so the 182 s track ended before the drop in batch5 and batch6. Not a verdict on the app |
| Step 0: offline playback of a downloaded track | PASS | G5c | plays with the network off; a forced-stream track failed with "No internet connection" |
| Step 0: natural change while locked | PASS | G5a (batch7) | phone idled to the background (scenePhase background), advanced idx 0 to 1, still playing |
| Step 0: Lock Screen play | PASS | G5b part / G3b | Play and Pause controls worked (G3b) |
| Step 0: Lock Screen scrub | FAIL | G5b (batch8) | drag from 5% to 70% of the scrubber (target about 173 s of 247 s): afterwards the app was on the next track at 6.8 s (idx 1), no scrub position seen. Hypothesis: the synthesized drag was interpreted by the cover sheet differently from a scrub; not confirmed |
| Step 0: Control Center tile | PASS (Pause/Play); Next unproven | G5d | tile Pause and Play changed state; slow gestures kept Next from being proven |
| Step 2 Downloads sheet | PASS | G5e | |
| Step 2 Autoplay and SmartMix toggles | PASS | G5f | flip and restore |
| Step 2c/2d launch, toast | PASS | EnsembleLaunchUITests (batch5) | testAppLaunchesToReachableRootSurface, testToastOverlayInteractions |
| PhoneBrowseAcceptanceUITests | PASS | batch5 | Artists, Albums, Playlists, Songs, Genres |
| Step 2 Now Playing debug-link items | PARTIAL | Z2 | covered by queue-page toggles in G5f and G3g; no separate sweep |

### Lock method (important)
The lock button cannot be pressed from XCUITest on this phone (`pressLockButton` does nothing). The tests set Auto-Lock to 30 s (A0), idle 40-70 s so the phone locks, then press Home. With no passcode that unlocks to the Home screen rather than the Lock Screen, so the media controls were read from the cover sheet (swipe down from the top), with the app backgrounded. G3b, G4e, G4f and G5b therefore prove the controls and remote-command path with the app in the background, not a literally locked Lock Screen. G5a and G4c prove playback and advancing while the app is backgrounded by an idle lock.

## Hooks added (DEBUG only)
- Launch options `-EnsembleAutomationForceNetworkStream` and `-EnsembleAutomationIgnoreDownloads` (env equivalents).
- Debug routes `ensemble://debug/play?tracks=k1,k2&index=N` and `debug/transport?action=pause|resume|next|previous|seek&to=sec`.
- Accessibility probe `automation.playback.probe` with value `pid|net|mix|state|id|pos|dur|idx|count|err`.
- Debug play route refreshes the connection first (cold-start "server unavailable" race).
- Unit test: `AutomationSupportTests.testPlaybackRequestParsingAndForceStreamOption` (does not cover `ignoreDownloads`).
- Findings about the hooks: failure and stream-delay env need `ENSEMBLE_AUTOMATION_MODE=1` in the environment (the tests add it); `startup`-stage failure injection is bypassed by a gapless advance.

## Settings changed and restored
- Auto-Lock: 5 minutes, set to 30 s by A0, restored by ZZ (passed in batches 7 and 8; the last run restored it to "5 minutes"). Not read back by hand afterwards.
- Shuffle, Smart Mix: the launch-argument overrides were written back to the persisted preferences. Restored by ZZ9 (batch9 passed: Shuffle On, Autoplay On, Smart Mix On, Repeat Off). Final plist diff against `prefs-baseline.plist` shows only `repeatMode` None to 0 (equals Off) plus JSON key-order noise in the FilterOptions and library_visibility values. Streaming and download quality unchanged (medium). Whole-library download untouched.
- Network: Wi-Fi and Airplane Mode toggled by Control Center taps for G2e, G4g, G4h, G5c, restored by paired toggles; probes read `net=online(wifi)` at the end of runs. Airplane Mode itself was not independently read back.
- Plex side effect: playing tracks to the end scrobbles them (view counts) for WAV 8731, the twenty one pilots tracks and others. No library mutation was made.

## Crash-report check
System crash listing on the phone (`systemCrashLogs`) after the runs: no Ensemble `.ips` and no new JetsamEvent. Existing: JetsamEvent-2026-11-09-112632 and Retired/JetsamEvent-2026-11-03-111927 (before these runs); the 11/10 entries are `dtfileserviced` (test infrastructure) only.

## Not reached
Apple Music items (no Apple Music source); phone call and Bluetooth items; G18 cellular switch and cellular streaming (no SIM); paired Watch; Siri affinity, Focus and App Shortcuts; TV and iCloud two-client items; 14294-14304; AirPlay route selection (G3h); a controlled network drop mid-stream (G2e); Lock Screen scrub (G5b FAIL, see above); Control Center Next; a literal Lock Screen (no passcode, Home unlocks).

## Re-running
```
cd <worktree>
## whole class (queues behind the shared build lock; BUILD=1 builds and tests in one lock hold)
BUILD=1 $TMPDIR/se-playback/run.sh batchN testG1a... testG2a...   # method names, or Class/method
```
`run.sh` passes `TEST_RUNNER_ENSEMBLE_PHONE_PLAYBACK=1` and `TEST_RUNNER_ENSEMBLE_PHONE_BROWSE=1` (both gates are needed), builds through `scripts/build_serial.py`, pulls the session logs and exports attachments.
Run order for the locked group: `testA0_SetAutoLockTo30Seconds`, then the locked tests, then `testZZ_RestoreAutoLock`. Finish with `testZZ9_RestoreShuffleAutoplayRepeat`.
`poll.sh` archives session logs while a batch runs (the app keeps only 5).
The phone ended with playback paused on the iPhone speaker.
