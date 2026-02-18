# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Detailed reference material is in `.claude/skills/` and loads on-demand:
- `architecture` -- Package structure, key types, patterns, subsystems (artwork, waveform, hubs, filtering, network, playback tracking)
- `ui-conventions` -- Navigation, visual design, loading states, iOS 15 compat, DetailLoader pattern
- `project-structure` -- Full file trees for all packages and targets
- `code-style` -- Comment guidelines, naming, performance targets, testing policy
- `known-issues` -- Critical bugs, feature gaps, tech debt
- `common-tasks` -- Recipes for adding ViewModels, views, entities, hubs, music sources


## Workflow (MUST follow for every task)

**Commit discipline:**
- Git commit after each logical "step" when implementing a plan
- Always commit before waiting for the user to test (so changes can be rolled back if context is lost or something breaks)


## Troubleshooting

When a problem is mentioned, **interview the user first** to help hone in on where the problem is originating from -- don't jump straight to code changes. Ask clarifying questions about when it happens, what they see, and what they expect.

When investigating, add logs to the appropriate files so debugging can be more efficient. Remove or reduce log verbosity once the issue is resolved.


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

### Sync System Overhaul (Feb 2026)
The sync system now supports **incremental sync** using Plex API timestamp filters (`addedAt>=`, `updatedAt>=`):

- **Pull-to-refresh:** Library views perform incremental sync (fast), HomeView refreshes hubs only
- **Startup sync:** Full sync if >24h old, incremental if >1h old, skip if fresh (<1h)
- **Background refresh (iOS):** `BGAppRefreshTask` refreshes hubs every ~15min (system-controlled)
- **Routine updates:** Incremental library sync every 1h, hubs every 10min while app is active
- **Offline-first:** All syncs respect offline state, fall back to CoreData cache

**Key files:**
- `SyncCoordinator.swift` - `syncAllIncremental()`, `performStartupSync()`, periodic timers
- `PlexMusicSourceSyncProvider.swift` - `syncLibraryIncremental(since:)`
- `PlexAPIClient.swift` - Filtered fetch methods (e.g., `getArtists(sectionKey:addedAfter:)`)
- `BackgroundSyncScheduler.swift` - iOS background refresh scheduling

### Playlist Mutations Rollout (Feb 2026)
Playlist management now supports server-backed mutations with local cache refresh:

- **Now Playing:** add current track to playlist, save current queue snapshot
- **Playlist Detail:** rename and edit playlist track ordering/removals
- **Album Detail:** add full filtered album track list to playlist from the pin menu
- **Consistency:** all successful playlist mutations trigger server refresh + CoreData update
- **Smart playlists:** treated as read-only for mutation operations

**Key files:**
- `PlexAPIClient.swift` - Create/rename/add/remove/move playlist mutation endpoints
- `SyncCoordinator.swift` - Playlist mutation orchestration + post-mutation playlist refresh
- `NowPlayingViewModel.swift` - Queue snapshot logic and shared playlist action methods
- `PlaylistViewModel.swift` - Playlist detail rename/edit mutation hooks
- `PlaylistActionSheets.swift` - Shared add/create playlist UI sheets


This project is connected to Xcode's MCP server: please use it to inform you of how best to operate.

Please comment code so that it's understandable. Don't over comment, just comment on what each "piece" does. Do not use emojis (except in debugging).

As you make big architectural changes, please update this document, the skills files, and the README.md as necessary.

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
