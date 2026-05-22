---
name: surface-sweep
description: "Use when the user asks to visually test, touch, automate, or walk every Ensemble app surface across iOS/iPadOS and macOS, including agent-run UI sweeps, issue detection, reproduction, log inspection, fix-plan reports, platform parity checks, and repeatable screenshot/accessibility evidence runs."
---

# Ensemble Surface Sweep

Run this skill when asked to touch every visible surface of Ensemble, automate a broad visual regression pass, or generate a fix-oriented issue report from live iPhone/iPad/macOS UI inspection.

This is a runtime verification workflow, not a unit-test replacement. It should usually be loaded with `testing`; load `simulator-test` for iOS/iPadOS, and use Computer Use or Xcode/macOS UI tooling for macOS. Load `known-issues` when classifying findings, and `app-policies` only when the sweep is tied to behavior policy changes.

## Scope

Default coverage:
- iPhone compact navigation: tab bar, More routing, sheets, full-screen Now Playing, compact rows, StageFlow-capable landscape surfaces.
- iPad regular navigation: sidebar/split behavior, regular-width sheets, wide Now Playing.
- macOS: sidebar, detail panes, auxiliary windows/sheets, menus/popovers, Now Playing viewport, table interactions, command availability.

Out of scope unless the user explicitly asks:
- watchOS.
- destructive final actions such as removing accounts, deleting playlists, clearing library data, or mass download removal.
- live third-party side effects beyond ordinary local app navigation/playback.

## Preflight

1. Start with `git status --short` and preserve unrelated changes.
2. Create an artifact root outside the repo:

```bash
RUN_ID="$(date +%Y%m%d-%H%M%S)"
ARTIFACT_ROOT="/tmp/ensemble-surface-sweep-$RUN_ID"
mkdir -p "$ARTIFACT_ROOT"/{iphone,ipad,macos,logs}
```

3. Confirm the app has usable local state. If there are no Plex accounts or no enabled libraries, still sweep onboarding/empty states, but mark library-dependent coverage as blocked.
4. Build before touching UI:

```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -destination 'platform=macOS,arch=arm64' build
```

If a destination name is unavailable, run `xcodebuild -showdestinations -workspace Ensemble.xcworkspace -scheme Ensemble` and choose the closest current iPhone, iPad, or macOS destination.

## Agent-Orchestrated Run

Use [automation-protocol.md](references/automation-protocol.md) when the user asks for automation, agents, a full sweep, or an issue report. The coordinator owns setup, platform assignment, final classification, `surface-sweep-notes.md`, and `fix-report.json`. Platform runners own UI interaction and raw evidence for exactly one platform.

If multi-agent tools are available and the request permits agent delegation, split independent sweeps into runners:
- iPhone runner: compact iPhone simulator.
- iPad runner: regular-width iPad simulator.
- macOS runner: local macOS app through Computer Use or macOS UI tooling.

Keep runners read-only against source files. They may create artifacts under the run's `/tmp` folder and inspect logs, screenshots, accessibility trees, and local code. Each runner writes `platform-report.json`; the coordinator is the only agent that edits code or commits.

## Execution Rules

- Use the iOS Simulator MCP/XcodeBuildMCP for iPhone and iPad: launch, `ui_describe_all`, tap/type/swipe, and capture screenshots.
- Use Computer Use for macOS visible interaction when no narrower macOS UI tool is available. Follow the Computer Use confirmation policy for risky UI actions.
- For each screen, capture at least one screenshot plus either an accessibility dump, visible UI description, or concise notes. For suspected issues, capture the before/after state, exact navigation path, and nearby logs.
- Touch every command path that is safe: toolbar buttons, search, sort/filter sheets, row context menus, mini-player actions, Now Playing panels, profile/download/settings drill-downs, and non-destructive alerts.
- For destructive or expensive actions, open the menu/dialog when useful, capture the confirmation UI, then cancel. Do not perform the destructive final action unless the user explicitly asked for it.
- Restore toggles/settings that were changed only for coverage. Prefer observing existing toggle state over changing it when the control itself is already visible.
- Keep data-dependent coverage honest: if there are no playlists, pins, downloads, lyrics, queue items, or search results, record the blocker instead of inventing coverage.

## Issue Loop

Every suspected issue gets a short closed loop before it becomes a finding:
1. Reproduce it once from a clean nearby state.
2. Capture screenshot/accessibility/log evidence.
3. Inspect the likely owning source files with `rg` and focused reads.
4. Classify severity and confidence.
5. Write an agent-readable JSON finding with suspected files, root-cause hypothesis, patch strategy, and verification commands.

Use [fix-report-template.md](references/fix-report-template.md) for both `fix-report.json` and the optional Markdown companion. If the issue cannot be reproduced, record it under `needs_recheck` instead of promoted `findings`.

## Route Map

Use [surface-map.md](references/surface-map.md) as the checklist. Treat it as a living map: if code reveals a new public surface during the sweep, add it to the notes and propose updating the reference.

Run the sweep in this order:
1. iPhone compact.
2. iPad regular.
3. macOS.
4. Cross-platform parity pass for surfaces that looked different or failed on one platform.

## Evidence

Use [evidence-template.md](references/evidence-template.md) for the final sweep report and [fix-report-template.md](references/fix-report-template.md) for the agent-readable JSON fix report. Keep artifacts in `/tmp`, and include paths in the handoff.

Minimum final handoff:
- build commands and results,
- platform/device list,
- artifact root,
- completed surfaces,
- blocked surfaces with exact reason,
- visual defects or regressions with screenshot/log paths,
- `fix-report.json` path with per-issue reproduction steps and suspected code owners,
- risky actions intentionally not completed.

## Failure Handling

If the shared build setup fails, stop the sweep and report that blocker first. If one platform build or launch fails, complete the remaining platform runners and mark the blocked platform incomplete.

Do not call a full sweep complete until each required platform has been launched, interacted with, and captured, or a precise blocker is documented.
