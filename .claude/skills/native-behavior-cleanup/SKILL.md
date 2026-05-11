---
name: native-behavior-cleanup
description: "Use when auditing, simplifying, or removing SwiftUI/UIKit/AppKit UI workaround code that fights native platform behavior: safe-area/titlebar/nav-bar bridges, custom scroll or drag handling, representable hit-testing, GeometryReader layout correction, DispatchQueue layout delays, loading-state swaps, stale UI layers, and broad chrome/presentation overrides. Supports thorough multi-pass cleanup with optional subagents when the user explicitly asks to use agents, plus tests, simulator checks, macOS checks, documentation, and commits."
---

# Native Behavior Cleanup

## Overview

Audit UI workaround code with a deletion-first bias: remove proven-dead or redundant code, let native SwiftUI/UIKit/AppKit behavior own the result, and defer high-risk adapters unless before/after runtime proof supports removal.

Always load these project skills before changing code: `architecture`, `project-structure`, `known-issues`, `code-style`, `ui-conventions`, `testing`, and `simulator-test`. Load `plex-api` only when a flow needs live Plex endpoint checks.

## Workflow

### 1. Establish The Baseline

- Check `git status --short` first and preserve unrelated user changes.
- Read the current cleanup notes in `docs/investigations/` and `known-issues`.
- Run `scripts/scan-native-workarounds.sh` from this skill to collect the first candidate set:

```bash
.claude/skills/native-behavior-cleanup/scripts/scan-native-workarounds.sh .
```

- Save important findings into a working note or existing investigation doc when the pass is broad.

### 2. Use Agents When Explicitly Requested

If the user explicitly asks for agents, subagents, delegation, or parallel work, split scanning into independent explorer tasks. Do not spawn agents otherwise.

Good explorer prompts:

- Safe-area/chrome: find titlebar, toolbar, nav-bar, safe-area, keyboard, and presentation workarounds. Return files, line refs, active call sites, and delete/keep/defer recommendation.
- Scroll/gesture/layout: find custom scroll, drag, offset, `GeometryReader`, `PreferenceKey`, and hardcoded layout correction. Return symptom group and risk.
- Bridges/adapters: find `UIViewRepresentable`, `NSViewRepresentable`, hit testing, AppKit/UIKit delegate bridges, and passthrough windows. Separate platform adapters from workaround shims.
- Dead-code/call-site pass: find unused UI types, private helpers, compile guards, duplicated environment values, and stale docs.

After agents return, verify claims locally with `rg` and file reads before editing. Use worker agents only for disjoint file sets and tell them not to revert others' changes.

### 3. Classify Ruthlessly

Read `references/classification-rubric.md` when the candidate set is large or ambiguous.

Classify each candidate as:

- `delete now`: no live call sites, duplicated by parent/root ownership, stale compile guard, stale wrapper, or private helper with no behavioral surface.
- `simplify now`: current behavior can be owned by native presentation, root chrome, native scroll view, native list/table, or existing platform API with less code.
- `keep`: active platform adapter that exposes behavior SwiftUI does not expose, such as native table row actions, route picker, Metal surface, AppKit drop handling, or iOS-version-specific missing API.
- `defer high-risk`: custom scroll/drag/layout/hit-testing or root chrome code that still owns real behavior and needs dedicated before/after visual proof.

Group findings by symptom:

- titlebar / safe area / toolbar behavior
- scroll focus stealing
- reflow / padding compensation
- native list/table wrapping
- loading-state swaps
- macOS-only or iPad-only branches
- stale public types or unused private helpers

### 4. Delete In Safe Passes

Work in small logical commits:

1. Delete dead code with no live call sites.
2. Remove stale comments/docs that describe deleted behavior.
3. Consolidate duplicated root/presentation/chrome ownership.
4. Replace broad workaround modifiers with owner-scoped native behavior only when runtime proof shows the broad fix is unnecessary.
5. Defer high-risk candidates into the closeout doc instead of half-removing them.

For every candidate, answer:

- What native behavior was this trying to restore?
- Does the workaround still solve a current problem?
- Can the parent/container own the behavior instead?
- Can code be deleted without adding a replacement?
- What test, build, screenshot, or log proves the simpler version?

### 5. Verify

Run targeted package tests after each non-trivial code pass:

```bash
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsembleUI
```

For app-facing UI cleanup, build and launch at least one phone and one iPad simulator. Prefer XcodeBuildMCP for the configured iPad path. Use shell `xcodebuild`/`simctl` for additional named devices when needed.

Required closeout checks for broad cleanup:

```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -destination 'platform=macOS' build
```

Capture simulator screenshots or logs for visible/presentation/layout changes. If credentials, simulator state, or platform support blocks a check, document the blocker and do not call the behavior verified.

### 6. Document And Commit

- Update `docs/investigations/` with removed code, kept adapters, deferred high-risk candidates, and verification.
- Update project skills when future agents need to know a changed rule, file, or pattern.
- Commit after each logical step and before handing work back for manual testing.
- Final answer should name the commit, tests/builds run, simulator evidence, and anything deferred.
