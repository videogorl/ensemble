---
name: code-style
description: "Load before writing any Swift code. Contains mandatory rules that override defaults: #if DEBUG required for all print() calls, edge case handling required (active beta), memory targets, MVVM pattern, debug logging conventions."
---

# Ensemble Code Style & Development Guidelines

## Comment Guidelines

- **"What" not "how":** Comment on what each logical section does, not how Swift works
- **Class/function headers:** Include doc comments (`///`) for all public types and methods
- **Complex logic:** Explain non-obvious algorithms, formulas, or architectural decisions
- **Avoid over-commenting:** Self-documenting code is preferred; don't comment the obvious
- Leave comments above classes and other elements so both the user and the agent understand what's going on

## Change Documentation

- **Git commits:** Commit after each logical step with descriptive messages; always commit before waiting for testing
- **Code comments:** Leave comments in code so future developers (including AI assistants) understand the design

Keep the following documents in sync when making changes:

| What changed | What to update |
|---|---|
| New service, subsystem, or major pattern | `architecture` skill + CLAUDE.md Recent Major Changes |
| New file added anywhere | `project-structure` skill |
| New recipe, pattern, or call convention | `common-tasks` skill |
| New UI component, navigation pattern, or visual rule | `ui-conventions` skill |
| New coding rule, naming convention, or mandatory practice | `code-style` skill (this file) |
| New known bug, limitation, or tech debt | `known-issues` skill |
| Feature shipped or roadmap item completed | `README.md` |
| Anything that changes how agents should work in this repo | `CLAUDE.md` |

## Code Style

- Use clear, descriptive variable/function names
- Use Xcode's MCP server to inform best practices
- Don't over-comment -- focus on complex logic and architectural decisions
- Do not use emojis (except in debugging)

## Debug Logging

**All `print()` calls must be wrapped in `#if DEBUG / #endif`** — this keeps debug output out of release/TestFlight builds:

```swift
#if DEBUG
print("[MyService] Something happened: \(value)")
#endif
```

For consecutive prints, wrap the group under a single `#if DEBUG`:

```swift
#if DEBUG
print("[MyService] State: \(state)")
print("[MyService] Detail: \(detail)")
#endif
```

Never add a bare `print()` outside of a `#if DEBUG` block. The entire codebase enforces this — zero unguarded calls.

## Preserve Existing Functionality

- **Don't remove features** when refactoring unless explicitly directed
- **Backward compatibility:** Maintain iOS 15 support; use feature detection for newer OS features
- **User preferences:** Respect user settings (accent colors, enabled tabs, filter preferences)
- Build on existing code; extend rather than replace working components
- Reuse established patterns (DetailLoader, HubRepository, FilterOptions)

## Memory & Performance Targets

- **Target:** iOS 15+ devices with 2GB RAM (iPhone 6s, iPad Air 2)
- Fetch in batches from CoreData
- Use `@FetchRequest` limits and offsets for large lists
- Lazy-load images with Nuke
- Background context for heavy CoreData operations (`CoreDataStack.performBackgroundTask`)
- Use `LazyVGrid`, `LazyVStack` for list views
- Use `Task.detached` for non-blocking background work
- Two-tier image caching (filesystem + Nuke in-memory) with 100MB disk cache limit

## Debouncing Standards

- **Network monitor:** 1s debouncing
- **Home screen loading:** 2s debouncing
- **App launch:** Network monitor starts with 500ms delay

## Testing Policy

- Unit tests for business logic (services, repositories)
- Integration tests for sync flows
- Not required for simple ViewModels or UI-only code
- App is in active beta testing — account for edge cases in CoreData model
- Validate inputs before saving to CoreData; handle nil/missing fields defensively

## MVVM Pattern

- All ViewModels: `@MainActor class ... ObservableObject`
- Inject dependencies via initializer
- Add factory method to `DependencyContainer`
- Use Combine publishers for reactive updates
