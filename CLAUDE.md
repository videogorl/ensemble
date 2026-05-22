# CLAUDE.md

Repository guidance for AI agents working on Ensemble.

## Product And Constraints

Ensemble is a Plex music player for iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It should feel native, information-dense, customizable, and reliable on 2 GB RAM devices such as iPhone 6s and iPad Air 2.

The app is in beta. Handle data and migration edge cases defensively; asking testers to reset can be acceptable, but do not silently discard functionality or data.

Always use `Ensemble.xcworkspace`, not `Ensemble.xcodeproj`.

## Skill Routing

Load the smallest relevant set of skills before non-trivial work:

| Skill | Load when... |
|---|---|
| `project-structure` | Locating files, adding files, or checking package ownership |
| `app-policies` | Changing app behavior, playback, queue, offline/connectivity, downloads, sync/refresh, mutations, platform UI behavior, or verification expectations |
| `architecture` | Designing features, adding services, or touching multiple packages |
| `code-style` | Writing Swift or changing coding conventions |
| `ui-conventions` | Building or modifying SwiftUI, navigation, loading, or error UI |
| `common-tasks` | Adding ViewModels, views, CoreData entities, hubs, music sources, playlist mutations, sync triggers, downloads, or Siri flows |
| `testing` | Writing tests, making non-trivial code changes, or deciding verification scope |
| `simulator-test` | Validating user-visible behavior in the running app |
| `surface-sweep` | Visually touching every reachable iPhone, iPad, and macOS app surface with repeatable screenshot/accessibility evidence |
| `known-issues` | Investigating bugs, planning around active limitations, or touching fragile areas |
| `plex-api` | Implementing or debugging Plex API, streaming, playback tracking, playlists, hubs, search, or sync endpoints |

Add another skill when the task crosses that boundary. Do not load every skill by default; long skills and references should stay out of context unless they are relevant.

## Policy-First Workflow

Before changing durable app behavior, load `app-policies` and the relevant policy reference(s). Follow the existing policy unless the task explicitly requires a behavior change. If implementation creates, removes, or clarifies behavior, update the relevant `app-policies` reference in the same logical change before handing work back.

Use policy docs for behavior contracts, not historical notes. Keep `architecture` for package/service ownership, `ui-conventions` for UI implementation conventions, `testing` for verification execution, `known-issues` for active limitations, and `plex-api` for PMS endpoint details.

## Workflow

Start with `git status --short` and preserve unrelated user changes.

For implementation work:
- Make the smallest coherent change that satisfies the request.
- Commit after each logical step when implementing a plan, and always commit before handing work back for manual testing.
- Follow the canonical verification policy in `testing`. In short: run affected package tests after non-trivial code changes, and visually validate user-visible behavior with screenshots or equivalent UI inspection unless a blocker is documented.

For bug reports:
- Ask clarifying questions first when the symptom, trigger, or expected behavior is unclear.
- Treat reported symptoms as real regressions until proven otherwise.
- Add focused logs when they materially improve diagnosis; remove or reduce noisy logs after fixing.

## Plex Streaming Guardrail

Before changing streaming or playback transport code, load `plex-api` and test the relevant PMS endpoint with `curl` using `.env` credentials. Do not rely on stale documentation.

Current live check on May 13, 2026:
- Direct file stream can work: tested `206` with a ranged `/library/parts/...` request.
- Universal transcode can work: tested `200` for decision and `200 audio/mpeg` for `start.mp3`.
- Therefore, do not disable universal transcode as a broad fix, and do not assume direct stream is always broken. Keep recovery scoped to the concrete failing path.

## Documentation Sync

Update docs only when the change creates information future agents or users need:

| Change | Update |
|---|---|
| Durable app behavior policy, including playback, queue, offline/connectivity, downloads, sync/refresh, mutations, platform UI behavior, or verification expectations | `app-policies` skill |
| New service, subsystem, package boundary, or major ownership rule | `architecture` skill |
| New file or moved ownership boundary | `project-structure` skill |
| New recipe, call convention, or implementation pattern | `common-tasks` skill |
| New UI component, navigation rule, or shared visual rule | `ui-conventions` skill |
| New coding rule or mandatory practice | `code-style` skill |
| New active bug, limitation, or watchlist item | `known-issues` skill |
| User-visible feature/status change | `README.md` |
| Canonical UI name, renamed shared UI element, or accessibility terminology | `VOCABULARY.md` |
| Agent workflow change | `CLAUDE.md` |

Do not update README or VOCABULARY for every internal refactor.

## Notion

If the task starts from a Notion page, use the Notion MCP. If access is unavailable, ask instead of guessing. Move the page to an in-progress status before implementation and to done when the work is complete.

## Gemini CLI

Use `gemini -p` as an optional implementation aid for very large context reads or bounded UI implementation after planning locally. Do not delegate architecture, structural refactors, or planning decisions to Gemini.

## Commands

```bash
# Full app build
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# All app tests
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test

# Package tests
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleDomain
swift test --package-path Packages/EnsemblePlex
swift test --package-path Packages/EnsembleWatchCore
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
swift test --package-path Packages/EnsembleSiriShared
```

The independent watch app builds with the `EnsembleWatch` scheme. The iOS `Ensemble` scheme does not embed the watch app during simulator builds.

## Architecture Summary

```text
Layer 3: EnsembleUI
Layer 2: EnsembleCore
Layer 1: EnsembleAPI + EnsemblePersistence
Shared: EnsembleSiriShared
Watch: EnsembleDomain + EnsemblePlex + EnsembleWatchCore
```

Use `architecture` for current ownership rules and `docs/reference/architecture-inventory.md` only when a detailed historical inventory is useful.

## External Dependencies

- KeychainAccess 4.2.0+ for token storage.
- Nuke 12.0.0+ for image loading and caching.
