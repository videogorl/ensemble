# Testing And Verification Policy

Load this reference when choosing verification for policy-changing work or changing what counts as done. The `testing` skill remains the canonical execution guide for commands and coverage expectations.

## Policies

- Non-trivial behavior changes require affected package tests. User-visible behavior changes also require visual runtime validation on each touched platform when feasible, using screenshots or equivalent UI inspection evidence unless a blocker is documented.
- Policy changes should be verified in the same logical change as implementation changes.
- Performance-sensitive SwiftUI, playback, download, Feed launch/refresh, root chrome, and observation changes require targeted tests plus runtime or performance evidence.
- Plex streaming or playback transport changes require live PMS endpoint checks with `.env` credentials before code changes and targeted playback verification afterward.
- CoreData model changes require recompiling the SwiftPM model bundle and running persistence plus dependent package tests.
- Multi-provider changes require provider-specific and merged-path proof. Verify metadata-only refreshes with stable IDs, sorting of unknown and merged aggregate values, provider-scoped artwork lifecycle, and remote-to-local mutation convergence; use a physical device for DRM playback or system-service contracts.
- Skill or agent workflow changes require skill validation and static discoverability checks.
- Automation launch surfaces and debug deep links must follow the same platform navigation path as user taps, including routing hidden iPhone tabs through More.
- If verification is skipped, blocked, or narrowed, document the exact blocker and residual risk in the final handoff.

## Owners

- `testing` skill owns canonical verification commands, scope selection, and definition of done.
- `simulator-test` skill owns iOS/iPadOS simulator launch, UI driving, screenshots, and log capture.
- macOS visual validation is owned by direct app inspection through Computer Use, Xcode UI tooling, screenshots, or an equivalent UI evidence path.
- `plex-api` skill owns live Plex endpoint probes and endpoint-specific requirements.
- `app-policies` owns policy-aware expectations and documentation verification.

## Implementation Hooks

- Select the smallest verification set that covers the changed behavior and package ownership.
- Run package tests for changed Swift packages before full app tests unless the change crosses app-level integration boundaries.
- Prefer visual runtime proof for visible UI/playback/refresh/download behavior instead of relying only on unit tests or builds.
- Treat build-only verification for user-visible UI changes as incomplete unless the final handoff names the blocker and residual risk.
- Use `scripts/capture_performance_gate.sh` when changing observation, root chrome, Feed launch/refresh, or Downloads queue behavior.
- Use `scripts/check_core_warning_budget.sh` for relevant `EnsembleCore` refactors.

## Verification

- For policy-skill edits, run:
  - `python3 /Users/felicity/.codex/skills/.system/skill-creator/scripts/quick_validate.py .claude/skills/app-policies`
  - `rg "app-policies|Policy-First|offline|downloads|queue|refresh" CLAUDE.md .claude/skills/app-policies`
- Confirm every policy reference is linked from `SKILL.md`.
- No Swift build is required for documentation-only policy changes unless Swift code also changes.
