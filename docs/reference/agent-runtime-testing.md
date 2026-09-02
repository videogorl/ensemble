# Agent Runtime Testing

Use this protocol when one or more agents verify Ensemble on simulators or
physical devices. The goal is isolated runners, deterministic app state, and
evidence that proves an interaction was delivered.

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
