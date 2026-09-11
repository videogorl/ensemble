---
name: simulator-test
description: "Build, launch, interact with, and capture evidence from an exact Ensemble simulator or physical device. Use for runtime verification, concurrent simulator runners, timing diagnosis, or Device Hub input recovery."
---

# Simulator Test — Build, Launch & Log Capture

Use this skill when the `testing` skill calls for runtime proof in the running app. The default path is:

1. Build the app.
2. Install and launch it in Simulator.
3. Establish state with Ensemble's debug framework, then drive only the behavior
   under test with UUID-pinned simulator tools.
4. Capture screenshots, accessibility output, and logs as evidence.

This skill exists so the agent can iterate without asking the user to manually operate the app.

Commands below assume `ENSEMBLE_SIMULATOR_UDID` is set to the currently discovered UUID for the requested runtime.

Create one isolated run directory before using the examples below:

```bash
ENSEMBLE_RUN_DIR=$(mktemp -d /tmp/ensemble-runtime.XXXXXX)
ENSEMBLE_DERIVED_DATA="$ENSEMBLE_RUN_DIR/DerivedData"
```

Reuse these paths for this run only. For a repeatable cold-launch baseline after
fresh installation, use the existing helper with explicit target and output:

```bash
scripts/capture_runtime_baseline.sh --capture-startup \
  --udid "$ENSEMBLE_SIMULATOR_UDID" --output-dir "$ENSEMBLE_RUN_DIR/startup" \
  --wait-seconds 15
```

It captures OS and persistent session logs. The 15 seconds is a capture window,
not proof of readiness; confirm the expected UI/log event separately. Never rely
on the helper's default target or shared output path.

---

## Ensemble Automation Hooks

Use these hooks before falling back to coordinate tapping. They route through `NavigationCoordinator`, so ordinary `USER_JOURNEY` navigation/profile/download breadcrumbs still appear.

Use a hook to establish nearby state, not to bypass the behavior under test. A
debug route plus its journey log proves that Ensemble accepted navigation; a
settled accessibility snapshot or screenshot proves that it rendered. If agents
repeatedly need the same fragile setup, extend the shared automation surface,
identifier catalog, or structured logging at the owning code path instead of
adding tool-specific timing workarounds. See
`docs/reference/agent-runtime-testing.md`.

Launch arguments:

```bash
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble \
  -EnsembleAutomationMode YES \
  -EnsembleAutomationStartSurface profile-storage \
  -EnsembleAutomationDisableAnimations YES
```

Environment alternatives:

```bash
ENSEMBLE_AUTOMATION_MODE=1
ENSEMBLE_AUTOMATION_START_SURFACE=profile-storage
ENSEMBLE_AUTOMATION_DISABLE_ANIMATIONS=1
```

Supported start surfaces: `home`, `songs`, `artists`, `albums`, `genres`, `playlists`, `favorites`, `search`, `downloads`, `settings`, `profile`, `profile-storage`, `add-source`.

Debug navigation deep links:

```bash
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" 'ensemble://debug/open?surface=profile-storage'
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" 'ensemble://debug/open?surface=playlists'
```

Media deep links:

```bash
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" 'ensemble://artist/<artist-id>?sourceKey=<url-encoded-source-key>'
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" 'ensemble://album/<album-id>?sourceKey=<url-encoded-source-key>'
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" 'ensemble://playlist/<playlist-id>?sourceKey=<url-encoded-source-key>'
```

Expected logs:

```text
USER_JOURNEY context=automation event=launchOptions ...
USER_JOURNEY context=automation event=deepLinkAccepted ...
USER_JOURNEY context=automation event=routeRequested ...
USER_JOURNEY context=navigation event=tabChanged ...
USER_JOURNEY context=navigation event=auxiliaryPresentation ...
```

Stable accessibility identifiers to prefer in UI automation:

```text
sidebar.search
sidebar.library.home
sidebar.library.songs
sidebar.library.artists
sidebar.library.albums
sidebar.library.genres
sidebar.library.favorites
sidebar.playlists.all
sidebar.toolbar.downloads
sidebar.toolbar.profile
profile.storage.clearArtworkCache
profile.storage.clearAllLibraryData
profile.reset.removeAllAccounts
```

Dynamic sidebar rows use sanitized identifiers:

```text
sidebar.playlist.<playlist-id>.source.<source-key>
sidebar.smartPlaylist.<playlist-id>.source.<source-key>
sidebar.mergedPlaylist.<playlist-id>.source.<source-key>
sidebar.pin.<artist|album|playlist>.<id>.source.<source-key>
```

---

## Reliable Simulator Control

Prefer XcodeBuildMCP for accessibility snapshots and input. Configure the
current agent's session with `persist: false`, the exact `simulatorId`, and a
unique `derivedDataPath`. Use `snapshot_ui` to resolve an `elementRef`, then use
low-level `touch` with `down: true`, `up: true`, and a short delay for taps.
Use `swipe` or `gesture` for movement. Immediately verify the expected state
with a fresh snapshot, screenshot, journey log, or app log.

On the current toolchain, high-level `tap` and `ios-simulator-mcp` `ui_tap` can
report success without changing the UI. Do not retry those blindly or classify
the app as unresponsive. The iOS Simulator MCP remains useful for screenshots
and accessibility inspection only when every call includes the exact `udid`;
never call `get_booted_sim_id` or omit `udid` when another simulator may be
running.

Do not use Device Hub, Simulator.app Computer Use, or iPhone Mirroring for
concurrent simulator control. They share foreground focus and process state.
Use them only under the GUI lease described in
`docs/reference/agent-runtime-testing.md`.

### Pin The Exact Simulator

When a specific runtime is requested, use its current UUID everywhere. Do not put a human-readable device name in an MCP/build-tool session profile: duplicate names can silently resolve to a newer runtime even when an ID was also supplied.

```bash
xcrun simctl list devices available
ENSEMBLE_SIMULATOR_UDID='replace-with-discovered-uuid'
# Boot only if this exact simulator is shut down.
xcrun simctl boot "$ENSEMBLE_SIMULATOR_UDID"
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -configuration Debug \
  -destination "platform=iOS Simulator,id=$ENSEMBLE_SIMULATOR_UDID" \
  -derivedDataPath "$ENSEMBLE_DERIVED_DATA" build
xcrun simctl install "$ENSEMBLE_SIMULATOR_UDID" \
  "$ENSEMBLE_DERIVED_DATA/Build/Products/Debug-iphonesimulator/Ensemble.app"
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" launchctl list | rg 'com\.videogorl\.ensemble'
```

Use an ID-only, non-persisted session. Do not change global `xcode-select`; pin a
consistent toolchain with per-command `DEVELOPER_DIR` when necessary. After
every tool-driven build or launch, compare the returned target with the requested
UUID. Reject UI evidence until the fresh app was explicitly installed on that
UUID and the running Ensemble process is proven there.

## Physical Device Screenshots Via iPhone Mirroring

When validating on a real iPhone through iPhone Mirroring, do not use plain `screencapture` for evidence. It captures the full desktop display and can save the wrong window. Resolve the `iPhone Mirroring` window id first, then target that window explicitly:

```bash
swift -e 'import CoreGraphics; let opts = CGWindowListOption(arrayLiteral: [.optionOnScreenOnly, .excludeDesktopElements]); if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] { for w in list { let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if owner.localizedCaseInsensitiveContains("iPhone") || name.localizedCaseInsensitiveContains("iPhone") { print("\\(w[kCGWindowNumber as String] ?? "?") owner=\\(owner) name=\\(name) bounds=\\(w[kCGWindowBounds as String] ?? [:])") } } }'
screencapture -x -l <window-id> "$ENSEMBLE_RUN_DIR/iphone-mirroring-now-playing.png"
```

Use the window-targeted artifact for before/after performance comparisons, especially when collecting Time Profiler or Instruments evidence from a physical device.

## Physical Device Validation

Use a physical iPhone or iPad when the contract depends on Apple Music authorization, subscription state, DRM playback, `ApplicationMusicPlayer`, system Now Playing, AirPlay, Siri, or live provider mutations. Simulator success is still useful for cached UI and navigation, but it does not prove those integrations.

Prefer `xcrun devicectl` for device discovery, fresh install/launch, installed-build verification, process state, and file collection. Use Device Hub or iPhone Mirroring only for visible interaction that the CLI cannot perform. Obtain any required approval before a signed device build or install.

```bash
# Discover the current device and destination identifier.
xcrun devicectl list devices
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -showdestinations

# Build for the exact attached device. Do not reuse an unverified old artifact.
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -configuration Debug \
  -destination 'id=<device-udid>' \
  -derivedDataPath "$ENSEMBLE_DERIVED_DATA" build

# Install and verify the resulting app before testing.
xcrun devicectl device install app --device <device-udid> <path-to-Ensemble.app>
xcrun devicectl device info apps --device <device-udid>
```

Physical-device rules:

- Record the device, OS, source commit, built app path, and installed version. A visible app launch does not rule out a stale installation.
- Treat mirrored input as untrusted until the phone UI or fresh Ensemble logs confirm the action. Device Hub translates Mac canvas input into remote touch, while iPhone Mirroring uses ordinary Mac pointer, trackpad, and scroll interaction; reacquire the active window and never reuse coordinates between them.
- If Device Hub's window controls respond but its canvas is black or ignores Home and touch, inspect recent Device Hub logs for `HID remote call failed`, `CoreDeviceError 15004`, `XPCError 1001`, or `connection was invalidated`. Capture Keyboard only redirects keystrokes and is not the cause when pointer input fails with the toggle off. Refresh only that device view first; a pop-out shares the same process and HID service. Use iPhone Mirroring or a narrow physical XCUITest while the channel is stale, and restart Device Hub only after coordinating with every active runner.
- Establish an audio baseline with a known Plex track before diagnosing Apple Music silence. Confirm audible output when the transport exposes it, and also inspect elapsed progress/system Now Playing in Lock Screen or Control Center. If UI state advances but mirrored audio is silent, distinguish an app failure from a Device Hub/iPhone Mirroring transport limitation by changing only the mirror connection.
- Capture the exact interaction and a focused log window together. For MusicKit work, include preparation, queue replacement, playback state, unresolved IDs, interruption, autoplay/station, and background-transition messages.
- For provider mutations, correlate the user action, provider acceptance, optimistic local write, targeted reconciliation attempts, remote result, and final local state. A successful request alone does not prove convergence, and a later stale refresh must not erase the optimistic result.
- After adding a source, verify the app returns to usable UI while initial sync continues. Browse/search during sync, confirm progress advances rather than sticking, and confirm completion or a surfaced error.
- Perform provider mutations with disposable items or playlists. Verify both the remote result in the provider's app and Ensemble's refreshed local state; API acceptance alone is not convergence proof.
- Source removal, playlist deletion, queue destruction, and cache cleanup require explicit authorization. When authorized, capture before/after database counts and cache inventory, confirm removed-source media disappears without harming other sources, then re-add the source and verify recovery.
- When testing artwork lifecycle, collect the app container's durable artwork inventory before and after catalog search, library sync/browse, and authorized source removal. Record file counts and bytes by provider scope; do not treat Nuke's bounded transient cache as durable library artwork.
- For background playback, start audio, background or lock the phone, wait through an actual track boundary, and confirm uninterrupted audio plus advancing system Now Playing state. Foreground-only success does not prove this path.

Do not claim that the agent heard audio unless the active audio transport exposes it or the user confirms it. Logs and moving system progress prove playback state, not audibility.

---

## Build And Capture One Run

Use the run directory and exact UUID established above. Omit
`-sdk iphonesimulator` so the workspace can build its embedded Watch target with
`watchsimulator`. Preserve the build exit status; inspect the log on failure.

```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -configuration Debug \
  -destination "platform=iOS Simulator,id=$ENSEMBLE_SIMULATOR_UDID" \
  -derivedDataPath "$ENSEMBLE_DERIVED_DATA" build \
  > "$ENSEMBLE_RUN_DIR/build.log" 2>&1
```

Continue only after build success. Install the exact produced artifact:

```bash
xcrun simctl install "$ENSEMBLE_SIMULATOR_UDID" \
  "$ENSEMBLE_DERIVED_DATA/Build/Products/Debug-iphonesimulator/Ensemble.app"
```

For a cold-launch baseline, use the helper above. For a specific interaction,
start a focused stream before the action and stop only this run's logger:

```bash
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" log stream \
  --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > "$ENSEMBLE_RUN_DIR/interaction.log" 2>&1 &
ENSEMBLE_LOG_PID=$!
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" launchctl list | rg 'com\.videogorl\.ensemble'
```

Confirm the logger is receiving events and the fresh process is running before
accepting evidence. Use automation to establish nearby state, inspect the
hierarchy, exercise the actual interaction, and verify its result. For a cold
launch, terminate only the target app first; do not terminate it while testing
in-process lifecycle recovery. Include extension logs when testing Siri.

```bash
kill "$ENSEMBLE_LOG_PID" 2>/dev/null
rg 'USER_JOURNEY|PlaybackService|StreamingPipeline|OfflineDownload|SyncCoordinator|ConnectionFailover' \
  "$ENSEMBLE_RUN_DIR/interaction.log"
```

Wait for the expected state/event within a bounded observation window. If it
never arrives, report that outcome; elapsed sleep time does not establish
startup completion, readiness, background execution, or lifecycle handoff. Use
persistent session logs to corroborate events a live stream may have missed.

## Evidence To Capture

- Focused tests/build checks selected by [testing](../testing/SKILL.md); a
  non-trivial change does not automatically require a whole-package run.
- The changed flow, verified through UUID-pinned interaction and fresh-build
  provenance, with a screenshot, accessibility dump, or relevant log excerpt.
- The actual lifecycle state reached, using the
  [lifecycle matrix](../testing/references/downloads-and-lifecycle.md#lifecycle-evidence)
  when background/download/playback behavior is involved.

Report unavailable login, network, device, or provider coverage precisely.
Simulator timings are directional; do not assume simulator networking is
near-zero latency or use it as physical-device performance proof. For device
logs, use copied `PersistentLogService` sessions or a supported device console
and correlate timestamps with the visible action.
