---
name: code-style
description: "Ensemble coding standards: comment guidelines, naming conventions, development guidelines, memory/performance targets, testing policy"
---

# Ensemble Code Style & Development Guidelines

## Comment Guidelines

- **"What" not "how":** Comment on what each logical section does, not how Swift works
- **Class/function headers:** Include doc comments (`///`) for all public types and methods
- **Complex logic:** Explain non-obvious algorithms, formulas, or architectural decisions
- **Avoid over-commenting:** Self-documenting code is preferred; don't comment the obvious
- Leave comments above classes and other elements so both the user and the agent understand what's going on

## Change Documentation

- **Update CLAUDE.md:** When making architectural changes, update with new patterns and conventions
- **Update README.md:** Keep user-facing documentation in sync with implemented features
- **Git commits:** Commit after each logical step with descriptive messages; always commit before waiting for testing
- **Code comments:** Leave comments in code so future developers (including AI assistants) understand the design

## Code Style

- Use clear, descriptive variable/function names
- Use Xcode's MCP server to inform best practices
- Don't over-comment -- focus on complex logic and architectural decisions
- Do not use emojis (except in debugging)

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
