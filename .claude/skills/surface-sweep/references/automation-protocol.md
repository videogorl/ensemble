# Surface Sweep Automation Protocol

Use this when a surface sweep should be run by agents, not as a single manual checklist.

## Coordinator Responsibilities

The coordinator stays in the main thread and owns:
- Git status, build setup, artifact root, and launch prerequisites.
- Assigning platform runners when agent delegation is available and permitted.
- Keeping source edits out of runner scopes.
- Merging runner `platform-report.json` files into `surface-sweep-notes.md`.
- Reproducing or downgrading any severe finding before finalizing.
- Producing `fix-report.json` for a later fixing agent, plus optional `surface-sweep-fix-report.md` for human scanning.

Recommended artifact layout:

```text
/tmp/ensemble-surface-sweep-<run-id>/
  iphone/
    screenshots/
    accessibility/
    logs/
    runner-report.md
    platform-report.json
  ipad/
    screenshots/
    accessibility/
    logs/
    runner-report.md
    platform-report.json
  macos/
    screenshots/
    accessibility/
    logs/
    runner-report.md
    platform-report.json
  surface-sweep-notes.md
  surface-sweep-fix-report.md
  fix-report.json
```

## Runner Contract

Each runner gets one platform, the artifact root, and a checklist slice from `surface-map.md`.

Runner rules:
- Do not edit source files.
- Do not perform destructive final actions.
- Save screenshots, accessibility dumps, and logs with stable names: `<surface>-<state>-<step>.<ext>`.
- For every issue, try one immediate reproduction from a clean nearby state.
- Inspect likely source files only enough to identify owner and hypothesis; do not patch.
- Return a concise Markdown report and `platform-report.json` with completed surfaces, blocked surfaces, findings, and artifact paths.

Required finding fields in `platform-report.json`:
- `id`, `severity`, `confidence`, `platform`, `device`, `surface`, `summary`,
- `starting_state`, `repro_steps`, `expected`, `actual`,
- `screenshot_paths`, `ui_dump_paths`, `log_excerpt_paths`,
- `first_seen_commit`, `suspected_area`, `source_files`, `fix_hint`,
- `verification_steps`, `notes`.

## Suggested Runner Prompts

iPhone runner:

```text
Use $surface-sweep for the iPhone compact slice only. Build/launch the Ensemble iPhone simulator if needed, drive every iPhone compact surface from surface-map.md, save artifacts under <ARTIFACT_ROOT>/iphone, reproduce suspected issues once, inspect likely logs/source owners, and write <ARTIFACT_ROOT>/iphone/runner-report.md plus <ARTIFACT_ROOT>/iphone/platform-report.json. Do not edit source files or complete destructive actions.
```

iPad runner:

```text
Use $surface-sweep for the iPad regular slice only. Build/launch the Ensemble iPad simulator if needed, drive every iPad/sidebar surface from surface-map.md, save artifacts under <ARTIFACT_ROOT>/ipad, reproduce suspected issues once, inspect likely logs/source owners, and write <ARTIFACT_ROOT>/ipad/runner-report.md plus <ARTIFACT_ROOT>/ipad/platform-report.json. Do not edit source files or complete destructive actions.
```

macOS runner:

```text
Use $surface-sweep for the macOS slice only. Build/launch the macOS Ensemble app if needed, use Computer Use or macOS UI tooling to touch every macOS surface from surface-map.md, save artifacts under <ARTIFACT_ROOT>/macos, reproduce suspected issues once, inspect likely logs/source owners, and write <ARTIFACT_ROOT>/macos/runner-report.md plus <ARTIFACT_ROOT>/macos/platform-report.json. Do not edit source files or complete destructive actions.
```

## Detection Heuristics

Mark an issue when any of these are visible or logged:
- Blank, chrome-only, or partially populated screen after navigation settles.
- Overlapping/clipped text, controls, toolbar items, mini-player, or keyboard.
- Wrong platform chrome, missing sidebar/tab/back control, or stale toolbar/search state.
- Tap/click does nothing, opens the wrong surface, or cannot be dismissed.
- Actionable controls missing usable accessibility labels.
- Empty/error states without a recovery action when one should exist.
- Destructive actions without a confirmation step.
- Layout failure after rotation, sidebar collapse, or macOS resize.
- Loading state never resolves when local data should be available.
- Error/toast/log message appears during ordinary navigation.
- Noticeable stutter, repeated redraw, audio interruption, or CPU/log storm during a simple interaction.
- Platform parity drift where iPhone/iPad/macOS expose contradictory safe actions.

## Log Capture

iOS/iPadOS runner:
- Use the `simulator-test` log stream pattern.
- For post-action snapshots, use `xcrun simctl spawn <udid> log show --last 10m --predicate 'process CONTAINS "Ensemble"'`.
- Save a full log for the platform plus a filtered issue excerpt next to each finding.
- Useful filters: `fault|error|crash|assert|timeout|CoreData|Plex|player|migration|navigation|toolbar|search|NowPlaying|Playback|CoreAudio|sync|download|offline`.

macOS runner:
- Prefer unified logs filtered to the Ensemble process or subsystem:

```bash
log stream --style compact --level debug --predicate 'process == "Ensemble" OR subsystem BEGINSWITH "com.videogorl.ensemble"'
log show --last 10m --predicate 'process CONTAINS "Ensemble"'
```

- If Computer Use observes visible jank, capture a short log window around the action and note wall-clock time.

## Coordinator Merge

After runners finish:
1. Read each `runner-report.md` and `platform-report.json`.
2. Deduplicate equivalent findings across platforms.
3. Promote cross-platform issues when the same behavior appears on multiple platforms; keep platform-specific evidence paths inside one finding's `platforms` and `evidence` arrays.
4. Separate environment/data blockers from app bugs.
5. For P1/P2 issues, personally inspect the strongest artifact and source owner before finalizing.
6. Write the final sweep report, optional Markdown fix report, and required `fix-report.json`.

## Severity

- P1: App crash, data-loss risk, impossible login/source setup, broken playback, or primary navigation unusable.
- P2: Major visible regression, stuck loading, missing key action, broken sheet/menu, or platform-specific flow blocked.
- P3: Visual polish, confusing copy/state, minor parity drift, recoverable log error, or non-blocking layout issue.
- Needs Recheck: observed once but not reproduced or evidence is too weak.
