---
name: simulator-test
description: "Build, launch, and capture debug logs from the iOS simulator. Use when you need to verify runtime behavior, measure timing, or diagnose issues without asking the user to manually capture logs."
---

# Simulator Test — Build, Launch & Log Capture

Use this skill when the `testing` skill calls for runtime proof in the running app. The default path is:

1. Build the app.
2. Install and launch it in Simulator.
3. Drive the relevant UI with the iOS Simulator MCP server.
4. Capture screenshots, accessibility output, and logs as evidence.

This skill exists so the agent can iterate without asking the user to manually operate the app.

Commands below assume `ENSEMBLE_SIMULATOR_UDID` is set to the currently discovered UUID for the requested runtime.

For repeatable cold-launch baselines, prefer `scripts/capture_runtime_baseline.sh --capture-startup` after the app is installed. It captures both the simulator OS log stream and the latest `PersistentLogService` session log, then prints a filtered summary.

---

## Ensemble Automation Hooks

Use these hooks before falling back to coordinate tapping. They route through `NavigationCoordinator`, so ordinary `USER_JOURNEY` navigation/profile/download breadcrumbs still appear.

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

## MCP-First Workflow

Use the iOS Simulator MCP server for interaction and state inspection:

- `open_simulator` opens the Simulator app.
- `get_booted_sim_id` returns the active device identifier.
- `install_app` installs a built `.app` or `.ipa`.
- `launch_app` launches the app by bundle identifier.
- `ui_describe_all` dumps the accessibility tree so you can find tappable elements and current labels.
- `ui_tap`, `ui_type`, and `ui_swipe` drive the UI directly.
- `ui_view` gives a compressed screenshot-like view of the current screen.
- `screenshot` saves a real screenshot when you need visual proof.

Use shell commands for build/log work, and MCP tools for interaction. That split keeps the iteration loop fast and agent-driven.

### Pin The Exact Simulator

When a specific runtime is requested, use its current UUID everywhere. Do not put a human-readable device name in an MCP/build-tool session profile: duplicate names can silently resolve to a newer runtime even when an ID was also supplied.

```bash
xcrun simctl list devices available
ENSEMBLE_SIMULATOR_UDID=<ios-26.5-uuid>
xcrun simctl boot "$ENSEMBLE_SIMULATOR_UDID"
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination "platform=iOS Simulator,id=$ENSEMBLE_SIMULATOR_UDID" build
xcrun simctl install "$ENSEMBLE_SIMULATOR_UDID" <path-to-Ensemble.app>
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" launchctl list | rg 'com\.videogorl\.ensemble'
```

Use an ID-only session profile. After every tool-driven build or launch, compare the returned destination/launch target with the requested UUID. Reject UI evidence until the fresh app was explicitly installed on that UUID and the running Ensemble process is proven there.

## Physical Device Screenshots Via iPhone Mirroring

When validating on a real iPhone through iPhone Mirroring, do not use plain `screencapture` for evidence. It captures the full desktop display and can save the wrong window. Resolve the `iPhone Mirroring` window id first, then target that window explicitly:

```bash
swift -e 'import CoreGraphics; let opts = CGWindowListOption(arrayLiteral: [.optionOnScreenOnly, .excludeDesktopElements]); if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] { for w in list { let owner = w[kCGWindowOwnerName as String] as? String ?? ""; let name = w[kCGWindowName as String] as? String ?? ""; if owner.localizedCaseInsensitiveContains("iPhone") || name.localizedCaseInsensitiveContains("iPhone") { print("\\(w[kCGWindowNumber as String] ?? "?") owner=\\(owner) name=\\(name) bounds=\\(w[kCGWindowBounds as String] ?? [:])") } } }'
screencapture -x -l <window-id> /tmp/ensemble-device-profile/artifacts/iphone-mirroring-now-playing.png
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
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination 'id=<device-udid>' build

# Install and verify the resulting app before testing.
xcrun devicectl device install app --device <device-udid> <path-to-Ensemble.app>
xcrun devicectl device info apps --device <device-udid>
```

Physical-device rules:

- Record the device, OS, source commit, built app path, and installed version. A visible app launch does not rule out a stale installation.
- Treat mirrored input as untrusted until the phone UI or fresh Ensemble logs confirm the action. If Device Hub stops accepting input, restart it and re-check the device lock state before repeating the gesture.
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

## Quick Reference

```bash
# 1. Build
ENSEMBLE_SIMULATOR_UDID=<target-simulator-uuid>
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination "platform=iOS Simulator,id=$ENSEMBLE_SIMULATOR_UDID" \
  build

# 2. Install the fresh app on the exact simulator
xcrun simctl install "$ENSEMBLE_SIMULATOR_UDID" <path-to-Ensemble.app>

# 3. Terminate previous instance if needed
xcrun simctl terminate "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble

# 4. Start log stream → file (background)
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" log stream \
  --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > /tmp/ensemble-test-log.txt 2>&1 &
LOG_PID=$!

# 5. Launch and prove the process on the exact simulator
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" launchctl list | rg 'com\.videogorl\.ensemble'

# 6. Use the MCP server to inspect and drive the UI
# ui_describe_all()
# ui_tap(...)
# ui_type(...)
# screenshot(...)

# 7. Wait for the phase you're testing (adjust as needed)
sleep 1

sleep 10

# 8. Stop log stream
kill $LOG_PID 2>/dev/null

# 9. Analyze with grep
grep -E '(pattern|you|care|about)' /tmp/ensemble-test-log.txt
```

---

## Step-by-Step Guide

### 1. Boot Or Select The Target Simulator

```bash
xcrun simctl list devices available
```

If no simulator is booted, boot one:

```bash
ENSEMBLE_SIMULATOR_UDID=<target-simulator-uuid>
xcrun simctl boot "$ENSEMBLE_SIMULATOR_UDID"
```

Use the UUID with every `simctl` and build-tool command. Use the MCP `open_simulator` and `get_booted_sim_id` tools once the device is up, and reject the session if the returned ID differs.

### 2. Build the App

```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination "platform=iOS Simulator,id=$ENSEMBLE_SIMULATOR_UDID" \
  build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Omit `-sdk iphonesimulator` for the full app scheme so Xcode can build its embedded Watch target with `watchsimulator`.

Check for `BUILD SUCCEEDED`. If the build fails, fix errors before proceeding.

### 3. Install And Launch Through MCP

After building, explicitly install the generated `.app` bundle on `$ENSEMBLE_SIMULATOR_UDID`. If using `install_app` and `launch_app`, first configure an ID-only session and confirm each returned target matches that UUID. Prove the Ensemble process is running on that simulator before accepting UI evidence.

Once the app is running:

- Use `ui_describe_all` to understand the current screen.
- Use `ui_tap`, `ui_type`, and `ui_swipe` to navigate the target flow.
- Use `ui_view` or `screenshot` to confirm the visible state.

This is the default validation path for bug fixes and UI work.

### 4. Terminate Any Running Instance

```bash
xcrun simctl terminate "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble 2>/dev/null
```

This ensures a clean cold launch. Ignore errors if no instance is running.

### 5. Start Debug Log Stream

```bash
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" log stream \
  --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > /tmp/ensemble-test-log.txt 2>&1 &
LOG_PID=$!
sleep 1  # Give log stream time to initialize
```

**Predicate notes:**
- `--level debug` captures ALL log levels (debug, info, default, error)
- The predicate filters to only the main app process (excludes Siri extension noise)
- To include the Siri extension, remove the `AND NOT` clause
- `--style compact` keeps lines concise

**Alternative predicates for focused capture:**

```bash
# Only app's own subsystem logs (skips system framework noise)
--predicate 'subsystem BEGINSWITH "com.videogorl.ensemble"'

# Specific subsystem (e.g., only core services)
--predicate 'subsystem == "com.videogorl.ensemble:core"'

# Combine: app process + specific level
--predicate 'processImagePath CONTAINS "Ensemble" AND messageType >= 1'
```

### 6. Launch the App

```bash
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
```

For launches with specific arguments or environment variables:

```bash
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble --argument1 value1
```

Prefer the Ensemble automation arguments for repeatable surface entry:

```bash
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble \
  -EnsembleAutomationMode YES \
  -EnsembleAutomationStartSurface downloads
```

### 7. Wait for the Phase Under Test

Adjust the sleep duration based on what you're measuring:

| Phase | Suggested Wait |
|-------|---------------|
| Health checks only | 5s |
| Full startup (health + sync) | 15s |
| Siri cold launch simulation | 20s |
| Background sync trigger | 30s |

### 8. Stop Log Stream & Analyze

```bash
kill $LOG_PID 2>/dev/null
```

### 9. Analyze Results

**Common analysis patterns:**

```bash
# Health check timing
grep -E '(🏥|health check|ServerHealthChecker|ConnectionTest|✅ Server|❌ Server)' /tmp/ensemble-test-log.txt

# Startup timeline
grep -E '(📱 AppDelegate|didFinishLaunching|health check|Startup sync|network monitor)' /tmp/ensemble-test-log.txt

# Connection probing details
grep -E '(ConnectionTest|ConnectionFailover|⚡️|Early exit|Grace period|preferred)' /tmp/ensemble-test-log.txt

# Siri flow
grep -E '(SIRI_APP|SIRI_EXT|InAppPlayMedia|coordinator|execute|AirPlay|route)' /tmp/ensemble-test-log.txt

# Playback flow
grep -E '(🎵|Starting playback|AVPlayer|playing audio|player item|stream URL)' /tmp/ensemble-test-log.txt

# Sync flow
grep -E '(🔄|sync|incremental|full sync|SyncCoordinator)' /tmp/ensemble-test-log.txt

# Network state
grep -E '(📡|NetworkMonitor|network state|Restored cached)' /tmp/ensemble-test-log.txt
```

---

## All-in-One Script

Copy-paste this block for a standard cold-launch capture:

```bash
# Build, launch, and capture 10s of cold-launch logs
xcrun simctl terminate "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble 2>/dev/null
xcrun simctl spawn "$ENSEMBLE_SIMULATOR_UDID" log stream --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > /tmp/ensemble-test-log.txt 2>&1 &
LOG_PID=$!
sleep 1
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble
sleep 10
kill $LOG_PID 2>/dev/null
echo "=== Captured $(wc -l < /tmp/ensemble-test-log.txt) lines ==="
```

---

## Evidence To Capture

Capture enough evidence to support the claim:

- A passing package test run for the affected package, if the change is non-trivial.
- Simulator confirmation of the relevant flow using MCP-driven interaction.
- A screenshot, accessibility dump, or log excerpt when the result would otherwise be ambiguous.

If the app cannot be fully validated because login, network state, or an external service is unavailable, stop short of "done" and report the blocker precisely.

---

## Tips

- **Log file location:** Always use `/tmp/ensemble-test-log.txt` (or similar) so it's easy to find and doesn't clutter the project.
- **Multiple runs:** Rename the log file between runs (e.g., `/tmp/ensemble-test-log-v2.txt`) to avoid confusion.
- **Large logs:** The full debug log can be 5000+ lines for a 10s capture. Use targeted grep patterns rather than reading the whole file.
- **Simulator performance:** Simulator probes are faster than real devices (local network latency is near-zero). Device logs will show longer probe times.
- **Real device logs:** Prefer Xcode's device console, copied `PersistentLogService` session logs, or another device-supported log collection path. Correlate timestamps with visible actions; do not rely on the mirror alone.
