# Agent Runtime Testing

Use this protocol when one or more agents verify Ensemble on simulators or
physical devices. The goal is isolated runners, deterministic app state, and
evidence that proves an interaction was delivered.

## Prepare And Capture A Run

Use `scripts/prepare_runtime.py` for repeatable Debug build, install, launch,
identity checks, and evidence collection. Discover and reserve the exact target
first; open simulator targets in the available device panel so the user can
observe. The helper uses a fresh DerivedData directory for each preparation and
never selects a device by name or `booted`.

```bash
python3 scripts/prepare_runtime.py prepare --platform simulator \
  --udid "$ENSEMBLE_SIMULATOR_UDID" --surface settings
# For a connected physical device, use --platform device and its exact UDID.
```

The command prints its run directory. `run.json` records the source commit and
dirty worktree status, built app path/version/hash, exact target, launch PID,
and evidence directory. Simulator preparation compares the installed executable
hash with the built executable and proves the PID's executable path. Physical
preparation records the fresh install, compares installed build versions, and
checks the launched PID/executable. Physical preparation requires an available,
unlocked, paired device; it does not enter a passcode or operate Device Hub.

Preparation launches an existing automation surface and captures evidence; it
does not establish that the surface rendered or the requested behavior passed.
Inspect the UI, exercise the actual flow, then collect updated evidence without
rebuilding or relaunching:

```bash
python3 scripts/prepare_runtime.py collect --run-dir "$ENSEMBLE_RUN_DIR"
python3 scripts/prepare_runtime.py shutdown --run-dir "$ENSEMBLE_RUN_DIR"
```

`collect` rechecks the original PID, so an app restart or replacement requires
new preparation. Simulator captures include a screenshot, recent OS logs, and
the latest persistent session log. Physical captures include session logs and
lock evidence; capture UI through Device Hub. Raw logs may contain private
library/account data; inspect and redact excerpts before sharing them.

`shutdown` targets and verifies only the run's simulator. Run it after a failed
preparation too, once all users of that simulator have released it. The helper
leaves the simulator running during inspection and never erases its data.
Physical cleanup remains playback pause and phone lock through Device Hub,
followed by independent lock-state verification.

Animations remain enabled unless `--disable-animations` is explicitly supplied.
Use the lower-level recipes below for lifecycle scenarios requiring an existing
process, Release/performance work, or custom launch arguments. The helper
deliberately cold-launches and replaces the installed Debug app.

## Assign Isolated Lanes

Each simulator runner owns:

- one exact simulator UUID;
- one unique DerivedData path;
- one artifact/log directory;
- one non-persisted XcodeBuildMCP session.

Use the UUID in every `xcodebuild`, `simctl`, screenshot, log, and UI command.
Never use `booted`, `get_booted_sim_id`, a device name, or a saved profile when
another simulator may run. Do not change global `xcode-select`; use the same
toolchain for all simulator lanes or set `DEVELOPER_DIR` per command.

Separate simulator containers isolate accounts, caches, and `UserDefaults`.
Separate DerivedData paths prevent build-database contention and stale artifact
reuse. Agents testing different source changes should also use separate Git
worktrees.

## Use Ensemble As The Control Plane

Launch directly into a stable surface:

```bash
xcrun simctl launch "$ENSEMBLE_SIMULATOR_UDID" com.videogorl.ensemble \
  -EnsembleAutomationMode YES \
  -EnsembleAutomationStartSurface albums \
  -EnsembleAutomationDisableAnimations YES
```

Move between supported roots without pointer input:

```bash
xcrun simctl openurl "$ENSEMBLE_SIMULATOR_UDID" \
  'ensemble://debug/open?surface=playlists'
```

Use media deep links for known artist, album, and playlist identifiers. Confirm
accepted commands through `USER_JOURNEY context=automation` logs and confirm
rendering through a settled hierarchy or screenshot.

Automation establishes nearby state; it does not replace the behavior under
test. Do not disable animations for animation or performance checks, deep-link
past navigation that is being verified, or use offline simulation as proof of
real network loss.

For toast interactions, launch a Debug build with `-EnsembleAutomationToast`.
This opens a fixture using the production global toast window, with persistent
toasts, action/tap feedback, and a sheet. Run
`EnsembleUITests/EnsembleLaunchUITests/testToastOverlayInteractions` to verify
swipe dismissal, action taps, and outside touch pass-through without a timeout
or provider mutation.

## Extend The Debug Framework

When repeated testing requires the same fragile setup, improve Ensemble instead
of accumulating coordinate scripts or sleeps. Prefer, in order:

1. Reuse an existing launch surface, media deep link, or identifier.
2. Add a stable accessibility identifier to the owning control.
3. Add structured journey logging at the shared behavior owner.
4. Add the smallest reusable `AutomationSurface` or debug option routed through
   the production owner.

Keep hooks DEBUG-safe, non-destructive by default, and representative of real
app behavior. Add one focused parsing or routing test for a new non-trivial hook.
Do not add a shortcut for a one-off leaf state or bypass the interaction being
validated.

Automation flags can fall back to app `UserDefaults`, and boolean sources are
combined. Keep pool baselines free of persisted automation values and leave the
Developer offline toggle disabled unless that runner owns an offline test.

For playback recovery checks, Debug builds support a bounded, process-local TLS
failure at `startup` or `prefetch`. Launch with `SIMCTL_CHILD_` environment
variables (or the unprefixed names in another launcher):

```text
ENSEMBLE_AUTOMATION_MODE=1
ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_STAGE=startup
ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_TRACK=<identity or rating key>[,<identity or rating key>...]
ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_COUNT=1
ENSEMBLE_AUTOMATION_PLAYBACK_FAILURE_DELAY_SECONDS=0
```

Count must be 1–10 and applies to each listed track; delay is capped at ten
seconds. Restarting the process resets the counts. One attempt can consume more
than one failure, because resolution and the TLS path each retry once, so use a
count of 10 to make a track fail for the whole run. Listing two consecutive
tracks exercises the skip-then-halt rule (G11). The `injectedPlaybackFailure` journey event distinguishes synthetic
failures from actual transport errors. These hooks exercise recovery after source
resolution; they do not reproduce a real TLS handshake failure. Use live uncached
playback separately to establish transport and decoder behavior.

## Drive And Verify Simulator Input

Prefer XcodeBuildMCP:

1. Set `simulatorId` and `derivedDataPath` with `persist: false`.
2. Capture `snapshot_ui` and resolve a current `elementRef`.
3. For a tap, use `touch` with `down: true`, `up: true`, and a short delay such
   as `0.08` seconds.
4. Use `swipe` or `gesture` for movement.
5. Capture a new hierarchy, screenshot, or correlated app log immediately.

On the Xcode 26.6/iOS 26.5 setup investigated on 2026-09-02, both
`ios-simulator-mcp ui_tap` and XcodeBuildMCP's high-level `tap` returned success
without changing UI state. Low-level touch down/up delivered concurrently to two
different simulator UUIDs, and low-level swipe delivered correctly. Treat
high-level tap as unavailable until a canary interaction visibly changes state.

The iOS Simulator MCP may still inspect UI or capture screenshots if every call
receives an explicit `udid`. Its default target selection chooses the first
booted simulator and is not safe for concurrent runners.

## Match Input To The Surface

| Surface | Input model | Agent rule |
|---|---|---|
| UUID-pinned simulator tool | Device coordinates or current element references | Preferred for concurrent lanes; verify every action on that UUID. |
| Device Hub canvas | Mac pointer and trackpad events translated into remote device touch | Reacquire the canvas after any resize, zoom, rotation, sidebar, or window change. The device UI isn't exposed as Mac accessibility elements. |
| Simulator.app through Computer Use | Mac window interaction | Treat focus as shared global state and reacquire the window before every action. |
| iPhone Mirroring | Regular Mac pointer and trackpad interaction, including scrolling | Use its current window geometry and Mac interaction semantics, not coordinates copied from Device Hub. It remains useful while the physical phone is locked or Device Hub's input channel is stale. |

Use one coordinator-owned GUI lease for Mac GUI automation because focus and
window geometry are shared state. Device Hub tabs or standalone compact windows
help humans observe several devices, but every Device Hub window belongs to one
process and uses the same underlying device services. A pop-out is neither an
isolated agent lane nor a fresh connection; restarting Device Hub disconnects
all of its windows.

Keep Capture Keyboard off unless the scenario specifically tests hardware-key
input. It routes Mac keystrokes to the selected device; pointer and trackpad
events remain touch input. Capture Keyboard and zoom are separate toolbar
controls, but toolbar layout can move after resizing or changing presentation;
resolve the toggle from fresh accessibility state instead of reusing a toolbar
coordinate.

For physical devices, use `devicectl` for discovery, installation, launch,
process, log, and lock evidence. Give the GUI lease to one agent only for actions
that require the mirrored screen. Finish physical testing with playback paused
and the device locked when the applicable project instructions require it.

## Recover Without Collateral Damage

When an action appears ignored:

1. Check the assigned UUID, installed build, process, lock state, and latest UI
   hierarchy before blaming Ensemble.
2. Repeat only after re-resolving the target from fresh state.
3. Replace high-level tap with low-level touch down/up.
4. For Device Hub, distinguish a coordinate miss from a dead remote channel. If
   the Mac window controls respond but the canvas is black or ignores Home and
   touch, inspect recent Device Hub logs for `HID remote call failed`,
   `CoreDeviceError 15004`, `XPCError 1001`, or `connection was invalidated`.
5. Refresh or reopen only the affected device view. A pop-out may confirm the
   same failure but does not create a new HID connection.
6. Continue physical interaction in iPhone Mirroring, or use one narrow
   XCUITest, when Device Hub's remote channel remains stale.
7. Restart Device Hub only after every active Device Hub runner releases its
   windows. A process restart is warranted when the window remains responsive
   but Device Hub repeatedly reuses an invalidated HID service.

An input tool's success response, a fresh mirror frame, or a journey log alone is
not a pass. Require the observable state change relevant to the feature.

## Incomplete stream handoff

DEBUG builds can hold the second data callback of one stream after its first
bytes arrive. Set `ENSEMBLE_AUTOMATION_MODE=1`,
`ENSEMBLE_AUTOMATION_STREAM_DELAY_TRACK` to its exact playback identity or Plex
rating key, and `ENSEMBLE_AUTOMATION_STREAM_DELAY_SECONDS` (clamped to 20 seconds).
The delay applies once per pipeline and logs `injectedStreamChunkDelay`. This
exercises a live incomplete transfer; it does not simulate TLS or network loss.

Match `downloadStarted`, `Adopted stream ... bytes=`, and `downloadComplete` for
the incoming track. One start followed by adoption before completion proves
that the engine retained the prefetch request and growing file. Confirm actual
render/progress and recovery after the delay, rather than treating adoption
alone as a successful playback check.
