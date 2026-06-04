# Native Behavior Cleanup Classification Rubric

Use this rubric after the scan script or agent passes produce candidates.

## Delete Now

Delete the candidate when one or more are true:

- `rg` finds no live call sites outside the file or tests that only cover the dead type.
- The code is a stale wrapper around an existing parent/root behavior.
- The code is a compile guard for a platform the package no longer supports.
- The helper is private and its output is no longer read.
- Comments describe behavior already removed.

Proof: static call-site search is enough for private code. Public package symbols need a package-wide search and a quick package build/test.

## Simplify Now

Simplify the candidate when native ownership is clear:

- A sheet/popover distinction can become one native sheet presentation.
- A broad `.ignoresSafeArea` can be removed because the owning container already handles keyboard/chrome.
- A root environment value duplicates a scene-owned view model or service.
- A custom toolbar/menu label duplicates a shared platform component.
- A refresh/reload observer watches broad state when a narrower content-change signal exists.

Proof: targeted unit tests for policy changes, plus simulator verification for presentation/layout changes.

## Keep

Keep the candidate when it is an intentional platform adapter:

- Native table/list row actions, context menus, selection, or swipe support.
- AppKit/UIKit representables exposing platform APIs SwiftUI does not expose.
- Route picker, share sheet, Metal surface, passthrough toast window, sidebar drop bridge, or old-OS compatibility bridge.
- Measurement needed for responsive layout where no native equivalent exists across the supported OS range.

Proof: document why the adapter owns real platform behavior and what would break if removed.

## Defer High-Risk

Defer instead of deleting when removal could silently break complex UI behavior:

- Custom scroll or drag physics.
- Hit testing and passthrough windows.
- Root chrome or mini-player placement preferences.
- StageFlow layout/gesture systems.
- Native track-list bridges with self-scrolling or header observers.
- iOS 15 fallback behavior where the newer native API does not exist.

Proof needed before deletion: before/after simulator or macOS screenshots, logs when relevant, and a narrow rollback plan.

## Red Flags

Stop and inspect deeper when you see:

- `DispatchQueue.main.async` or `asyncAfter` in view layout paths.
- Geometry used to compensate for toolbar/titlebar/safe-area behavior.
- State updates from `body`, `onAppear`, or preference changes that re-present sheets.
- Hardcoded offsets that differ by device, tab, or OS.
- Loading-state swaps that recreate root view models or reset navigation.
