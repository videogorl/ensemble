# Ensemble Agent Guide

Ensemble is a native Plex music player for iOS 15+, iPadOS 15+, macOS 12+,
and watchOS 10+. Keep it reliable on 2 GB devices such as iPhone 6s and iPad
Air 2.

## Working Rules

- Start with `git status --short`; preserve unrelated worktree changes.
- Use `Ensemble.xcworkspace`, never `Ensemble.xcodeproj`.
- Prefer the smallest complete solution. Reuse existing code, native platform
  behavior, standard libraries, and installed dependencies before adding an
  abstraction or package.
- Trace the shared owner and callers before fixing a symptom. Remove obsolete
  paths instead of adding compatibility layers. Preserve supported OS versions
  and protect persisted user data.
- Handle missing, partial, and malformed remote data defensively. Never infer a
  destructive deletion from an unavailable or incomplete response.
- Keep concerns in their owning package; load `architecture` only when changing
  ownership, adding a service, or crossing package boundaries.
- Use structured privacy-safe `Logger` calls, never `print`, in production Swift.
- Reproduce reported bugs first when feasible. Capture the specific UI state,
  logs, database/network evidence, or runtime path that distinguishes the cause.
- Commit the completed logical change before handoff.

## Load Only What The Task Needs

Skills are opt-in context, not a checklist:

- `code-style` for Swift edits.
- `ui-conventions` for SwiftUI, navigation, presentation, or visual behavior.
- `common-tasks` only for a matching recipe such as a new source, CoreData
  entity, mutation flow, download target, or Siri integration.
- `testing` when choosing verification or changing tests.
- `app-policies` only when a durable product, safety, privacy, offline,
  destructive-mutation, queue, or cross-provider contract may change.
- `plex-api` for Plex endpoints, streaming, sync, playlists, hubs, or tracking.
- `simulator-test`, `surface-sweep`, or `trace-analysis` only when that workflow
  is actually requested or required.
- `known-issues` only when the touched area matches a listed limitation.

Use `rg`/`rg --files` for ordinary discovery before loading a project map.

## Durable Behavior Policy

Policy documents contain invariants, not implementation history. Follow an
existing invariant unless the user approves changing it. Update policy only
when the delivered change creates, removes, or changes a durable contract.
Do not update policy for a bug fix that restores the existing contract, a
refactor, renamed owner, file move, test command, or implementation detail.

Keep architecture in `architecture`, UI mechanics in `ui-conventions`, test
selection in `testing`, active limitations in `known-issues`, and investigations
in `docs/investigations/`.

## Verification

Search existing coverage first. Add no test by default. Add one focused
regression test only for a new non-trivial contract or a reproduced bug that
existing coverage does not protect. Prefer one table-driven test per behavior
equivalence class; skip duplicate, speculative, boilerplate, layout-only, and
one-test-per-input coverage.

During iteration, run the narrowest relevant `swift test -q --filter ...` or
build check. Run a whole affected package only when the change is broad, shared,
or cannot be proven by a focused selection. User-visible changes also require
direct inspection of the changed flow when feasible. Report blockers and
residual risk instead of overstating verification.

Before accepting runtime or UI evidence, prove the installed and running app is
the build just produced. On macOS launch the explicit built `.app`, then verify
the PID executable path and build version; display-name launches can select
stale artifacts. Use installed-version/process evidence on devices. Restart
Device Hub if its frames or input become stale.

For Plex streaming or transport changes, load `plex-api` and test the exact PMS
endpoint with `.env` credentials. Direct file streams and universal transcode
are both known-valid paths; never disable either as a broad workaround.
