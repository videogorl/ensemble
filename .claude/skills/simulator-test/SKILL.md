---
name: simulator-test
description: "Build, launch, and capture debug logs from the iOS simulator. Use when you need to verify runtime behavior, measure timing, or diagnose issues without asking the user to manually capture logs."
---

# Simulator Test — Build, Launch & Log Capture

Use this skill to build the app, launch it on a simulator, and capture debug-level logs for analysis — all from the CLI. This avoids round-tripping logs through the user for every test iteration.

---

## Quick Reference

```bash
# 1. Find a booted simulator
xcrun simctl list devices | grep "Booted"

# 2. Build
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# 3. Terminate previous instance
xcrun simctl terminate booted com.videogorl.ensemble

# 4. Start log stream → file (background)
xcrun simctl spawn booted log stream \
  --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > /tmp/ensemble-test-log.txt 2>&1 &
LOG_PID=$!

# 5. Wait for log stream to initialize
sleep 1

# 6. Launch app
xcrun simctl launch booted com.videogorl.ensemble

# 7. Wait for the phase you're testing (adjust as needed)
sleep 10

# 8. Stop log stream
kill $LOG_PID 2>/dev/null

# 9. Analyze with grep
grep -E '(pattern|you|care|about)' /tmp/ensemble-test-log.txt
```

---

## Step-by-Step Guide

### 1. Find the Target Simulator

```bash
xcrun simctl list devices | grep "Booted"
```

If no simulator is booted, boot one:

```bash
xcrun simctl boot "iPhone 17 Pro"
```

Use the device name (not UUID) with `xcrun simctl` commands, or use `booted` as a shortcut when exactly one simulator is running.

### 2. Build the App

```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build 2>&1 | grep -E "error:|BUILD" | tail -5
```

Check for `BUILD SUCCEEDED`. If the build fails, fix errors before proceeding.

### 3. Terminate Any Running Instance

```bash
xcrun simctl terminate booted com.videogorl.ensemble 2>/dev/null
```

This ensures a clean cold launch. Ignore errors if no instance is running.

### 4. Start Debug Log Stream

```bash
xcrun simctl spawn booted log stream \
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

### 5. Launch the App

```bash
xcrun simctl launch booted com.videogorl.ensemble
```

For launches with specific arguments or environment variables:

```bash
xcrun simctl launch booted com.videogorl.ensemble --argument1 value1
```

### 6. Wait for the Phase Under Test

Adjust the sleep duration based on what you're measuring:

| Phase | Suggested Wait |
|-------|---------------|
| Health checks only | 5s |
| Full startup (health + sync) | 15s |
| Siri cold launch simulation | 20s |
| Background sync trigger | 30s |

### 7. Stop Log Stream & Analyze

```bash
kill $LOG_PID 2>/dev/null
```

### 8. Analyze Results

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
xcrun simctl terminate booted com.videogorl.ensemble 2>/dev/null
xcrun simctl spawn booted log stream --level debug \
  --predicate 'processImagePath CONTAINS "Ensemble" AND NOT processImagePath CONTAINS "Extension"' \
  --style compact > /tmp/ensemble-test-log.txt 2>&1 &
LOG_PID=$!
sleep 1
xcrun simctl launch booted com.videogorl.ensemble
sleep 10
kill $LOG_PID 2>/dev/null
echo "=== Captured $(wc -l < /tmp/ensemble-test-log.txt) lines ==="
```

---

## Tips

- **Log file location:** Always use `/tmp/ensemble-test-log.txt` (or similar) so it's easy to find and doesn't clutter the project.
- **Multiple runs:** Rename the log file between runs (e.g., `/tmp/ensemble-test-log-v2.txt`) to avoid confusion.
- **Large logs:** The full debug log can be 5000+ lines for a 10s capture. Use targeted grep patterns rather than reading the whole file.
- **Simulator performance:** Simulator probes are faster than real devices (local network latency is near-zero). Device logs will show longer probe times.
- **Real device logs:** For device testing, the user must capture logs via Console.app or `log stream` on the device. This skill covers simulator-only workflows.
