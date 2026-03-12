# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

If I give you a Notion page to pull from, use the Notion MCP to access the page. If you don't have access, don't just assume, ask.
When starting work from a Notion page, change the status of the page to "In Progress" (or something appropriate).
Once done with the work, mark the Notion page status as "Done"

## Skills (MUST load before starting work)

Detailed reference material lives in `.claude/skills/`. **Always load the relevant skill(s) before beginning any non-trivial task** — these files contain project-specific rules that override general Swift/SwiftUI defaults.

| Skill | Load when… |
|-------|-----------|
| `architecture` | Designing a feature, adding a service, understanding data flow, anything touching multiple packages |
| `ui-conventions` | Building or modifying any SwiftUI view, navigation, loading states, iOS 15 compat |
| `project-structure` | Locating a file, deciding where a new file belongs, understanding what exists |
| `code-style` | Writing any Swift code — contains mandatory rules (e.g. `#if DEBUG` for all prints, edge case handling) |
| `known-issues` | Investigating a bug, planning work, or before touching any area with known problems |
| `common-tasks` | Adding a ViewModel, view, CoreData entity, hub, music source, playlist mutation, or sync trigger |
| `testing` | Writing tests, implementing a major feature, or verifying nothing is broken after a refactor |
| `plex-api` | Implementing or debugging Plex API calls — library sync, playback tracking, playlists, hubs, search, transcoding |
| `recent-changes` | Debugging, investigating prior work, understanding how a feature was implemented, or before touching a recently modified area |

**When in doubt, load all of them.** They are small and the cost of reading them is far lower than making a wrong decision.


## Workflow (MUST follow for every task)

**Commit discipline:**
- Git commit after each logical "step" when implementing a plan
- Always commit before waiting for the user to test (so changes can be rolled back if context is lost or something breaks)

**Testing discipline:**
- After implementing a non-trivial feature or refactor, run `swift test --package-path Packages/<affected-package>` before committing
- If tests fail, fix them before committing — never commit a broken test suite
- For major architectural changes, write tests for new services/repositories first (see `testing` skill)


## Troubleshooting

When a problem is mentioned, **interview the user first** to help hone in on where the problem is originating from -- don't jump straight to code changes. Ask clarifying questions about when it happens, what they see, and what they expect.

**Never assume something was already broken.** When the user reports a symptom, treat it as a real regression until proven otherwise. If you're unsure whether an issue is pre-existing or caused by your changes, **ask** — don't silently dismiss it or claim it was broken before. Similarly, when the user provides a log or screenshot, assume they're running the correct build unless they say otherwise.

When investigating, add logs to the appropriate files so debugging can be more efficient. Remove or reduce log verbosity once the issue is resolved.

### Plex Streaming Issues — MUST READ

**ALWAYS test Plex endpoints with curl BEFORE making code changes.** A `.env` file at the project root contains `PLEX_ACCESS_TOKEN` for testing. Load the `plex-api` skill for endpoint details and testing patterns.

**DO NOT "disable universal endpoint" as a fix for playback failures.** Curl testing has confirmed:
- **Universal transcode endpoint WORKS** (200, valid audio/mpeg)
- **Direct file stream returns 503** — falling back to direct stream makes things WORSE
- The "resource unavailable" error is an **AVPlayer-specific issue**, not a server problem
- See the `plex-api` skill for the full diagnosis and testing patterns


## Using the Gemini CLI

You have access to the Gemini CLI (`gemini -p`) which leverages Google Gemini's massive context window. Use it as a complementary tool in the following situations:

**When to use Gemini:**
- **Large codebase analysis:** When you need to analyze many files or large amounts of code that might strain your context limits, pipe content to `gemini -p` to take advantage of its large context capacity.
- **UI implementation:** Gemini excels at identifying UI patterns and implementing SwiftUI views. When implementing UI changes, **plan the approach here in Claude first**, then delegate the implementation to Gemini. Review and integrate what it produces.

**When NOT to use Gemini:**
- **Architectural decisions:** Do not delegate architectural changes, structural refactors, or design decisions to Gemini. All architectural planning and decisions must stay in Claude.
- **Planning:** Claude handles all planning. Gemini is an implementation tool, not a planning tool.

**Typical workflow for UI changes:**
1. **Claude:** Plan the UI change (what views to create/modify, what patterns to follow, what components to reuse)
2. **Gemini:** Implement the planned UI code via `gemini -p` with the plan and relevant context
3. **Claude:** Review the output, integrate it, and ensure it follows project conventions


## Project Overview

Ensemble is a universal Plex Music Player built with SwiftUI, targeting iOS 15+, iPadOS 15+, macOS 12+, and watchOS 8+. It streams music from Plex servers using PIN-based OAuth authentication. It is very important features work on iOS 15, and are memory and speed optimized for devices with 2GB or less of RAM.

Right now, this app is in beta testing. We should account for edge cases as we're developing the CoreData model. We have a little bit of leeway with regards to asking our testers to reset their app if needed.

The goal of this app is to provide a beautiful, information-dense, and customizable native experience for the Plex server.


## Recent Major Changes

Moved to the `recent-changes` skill to keep CLAUDE.md lean. Load it when debugging, investigating prior work, or before touching a recently modified area.


This project is connected to Xcode's MCP server: please use it to inform you of how best to operate.

Please comment code so that it's understandable. Don't over comment, just comment on what each "piece" does. Do not use emojis (except in debugging).

As you make changes, keep the following documents in sync:

| What changed | What to update |
|---|---|
| New service, subsystem, or major pattern | `architecture` skill + `recent-changes` skill |
| Any feature or major change completed | `recent-changes` skill (add entry at top with date, summary, key files) |
| New file added anywhere | `project-structure` skill |
| New recipe, pattern, or call convention | `common-tasks` skill |
| New UI component, navigation pattern, or visual rule | `ui-conventions` skill |
| New coding rule, naming convention, or mandatory practice | `code-style` skill |
| New known bug, limitation, or tech debt | `known-issues` skill |
| Feature shipped or roadmap item completed | `README.md` |
| Anything that changes how agents should work in this repo | `CLAUDE.md` |
| New View or UI element added/renamed/removed | `VOCABULARY.md` |

When in doubt: if a future agent session wouldn't know about it by reading the skills, document it.

Please don't remove existing functionality (unless directed) when re-architecting parts of the code. I've had to re-implement multiple things that I had asked for and that were removed.


## Build & Test Commands

**Build the full app (iOS simulator):**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

**Build a single package:**
```bash
swift build --package-path Packages/EnsembleAPI
swift build --package-path Packages/EnsembleCore
swift build --package-path Packages/EnsemblePersistence
swift build --package-path Packages/EnsembleUI
```

**Run tests for a single package:**
```bash
swift test --package-path Packages/EnsembleAPI
swift test --package-path Packages/EnsembleCore
swift test --package-path Packages/EnsemblePersistence
swift test --package-path Packages/EnsembleUI
```

**Run all tests via Xcode:**
```bash
xcodebuild -workspace Ensemble.xcworkspace -scheme Ensemble -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

**IMPORTANT:** Always open `Ensemble.xcworkspace` (not `.xcodeproj`) when working in Xcode.


## Architecture (Brief)

Layered modular architecture via four Swift Packages under `Packages/`:

```
Layer 3: EnsembleUI (SwiftUI views & components)
              |
Layer 2: EnsembleCore (ViewModels, services, domain models)
              |
Layer 1: EnsembleAPI (Networking) + EnsemblePersistence (CoreData)
```

For detailed architecture, invoke the `architecture` skill.


## External Dependencies

- **KeychainAccess** (4.2.0+) -- Secure token storage (EnsembleAPI). SPM: `https://github.com/kishikawakatsumi/KeychainAccess.git`
- **Nuke** (12.0.0+) -- Image loading and caching (EnsembleCore + EnsembleUI via NukeUI). SPM: `https://github.com/kean/Nuke.git`
