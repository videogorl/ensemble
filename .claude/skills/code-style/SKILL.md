---
name: code-style
description: "Load when editing Ensemble production Swift or Swift tests. Defines the repo's Swift safety, logging, ownership, compatibility, and performance rules."
---

# Ensemble Swift Rules

Write the shortest clear implementation that preserves current behavior and
supported platforms. Reuse the owning type, shared helper, standard library,
native framework, or installed dependency before adding code.

## Mandatory Rules

- Use descriptive names and focused types/functions. Comment only non-obvious
  intent, invariants, or algorithms; document public API when its contract is
  not obvious from its declaration.
- Use package `AppLogger` / `EnsembleLogger` category loggers and intentional
  levels. Never use `print` in production paths or hide `Logger` calls behind
  `#if DEBUG`.
- Treat logs as production data. Route URLs, headers, query strings, auth data,
  filesystem paths, and token-like values through the existing redaction path.
- Keep iOS 15 and macOS 12 source compatibility with availability checks. Remove
  obsolete internal compatibility paths; do not remove user features or stored
  data without explicit authorization.
- Validate remote and persisted inputs. Preserve last-good data when responses
  are failed, partial, or malformed; destructive behavior must require explicit
  or authoritative evidence.
- Keep UI in `EnsembleUI`, orchestration/ViewModels in `EnsembleCore`, transport
  in API/provider owners, and persistence in `EnsemblePersistence`. Load
  `architecture` before changing those boundaries.
- ViewModels are `@MainActor` `ObservableObject`s with injected dependencies.
  Reuse `DependencyContainer` factories; do not hide business logic in views.
- Guard high-frequency publications and expensive work. Keep I/O and CPU-heavy
  work off the main actor, but do not use detached work that escapes ownership
  or can write after cancellation/source removal.
- Account for 2 GB devices. Load [performance.md](references/performance.md) only
  when changing persistent SwiftUI observation, large collections, CoreData,
  artwork, audio analysis, downloads, sync, or another performance-sensitive
  path.

Use `testing` for verification selection. Do not duplicate its policy here.
