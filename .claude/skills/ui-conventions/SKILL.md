---
name: ui-conventions
description: "Load when building or modifying Ensemble SwiftUI, navigation, presentation, loading/error states, shared actions, or visual behavior on iOS, iPadOS, macOS, or watchOS."
---

# Ensemble UI Router

Prefer native SwiftUI/UIKit/AppKit/watchOS behavior and the existing shared
surface owner. Before adding a modifier, bridge, delay, gesture, geometry probe,
or platform branch, inspect the current component and reproduce why native
behavior is insufficient.

## Core Rules

- Keep navigation and presentation scene/window-scoped. Do not route user UI
  through shared singleton navigation state.
- Preserve iOS 15/macOS 12 fallbacks with availability checks; use modern native
  APIs on newer systems rather than broad appearance overrides.
- Reuse shared scaffolds, design tokens, menu/action catalogs, track-list hosts,
  detail surfaces, and root chrome owners. Do not fork behavior per screen.
- Render cached/last-good content immediately. Refresh in place; do not replace a
  populated surface with a blank loader or infer an empty library from unsettled
  bootstrap state.
- Keep frequently changing state narrowly projected. Load `code-style`'s
  performance reference only for persistent/high-frequency surfaces.
- Preserve accessibility labels, native focus/keyboard behavior, Dynamic Type,
  safe areas, and state-revealing disabled actions.

## Load One Relevant Reference

- [navigation-and-platform.md](references/navigation-and-platform.md): root
  shells, typed routes, iOS 15 navigation, split views, root chrome, StageFlow,
  native tables, and platform bridges.
- [presentation-and-actions.md](references/presentation-and-actions.md): sheets,
  keyboard flows, menus, swipe actions, toasts, source capability copy, and
  shared interaction hosts.
- [design-and-state.md](references/design-and-state.md): design tokens, detail
  surfaces, artwork, loading/error/empty states, toolbars, and visual stability.
- [watch.md](references/watch.md): standalone Watch hierarchy, Crown behavior,
  detail and Now Playing presentation.

Load only the reference covering the changed surface. For durable cross-surface
product behavior, also consult the single matching `app-policies` reference.
