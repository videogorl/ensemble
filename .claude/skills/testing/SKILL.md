---
name: testing
description: "Load when choosing Ensemble verification, editing tests, or deciding whether a production change needs new coverage. Defines the smallest sufficient proof."
---

# Ensemble Testing

Prove the changed contract with the smallest reliable check. Coverage volume is
not a goal.

## Before Adding A Test

1. Search existing tests for the owner, behavior, and failure mode.
2. Add no test when existing coverage already protects the contract, or when the
   change is documentation, mechanical refactoring, trivial forwarding, or pure
   visual layout.
3. Add one focused regression test for a new non-trivial contract or a reproduced
   bug that existing coverage misses.
4. Test behavior, not implementation steps. Combine equivalent inputs in one
   table-driven test; avoid one-test-per-input, duplicate fixtures, speculative
   edge cases, and pass-through ViewModel tests.
5. Prefer extending the owning test file over creating a new suite.

Persistence round-trips, destructive/source cleanup, queue ordering, playback
handoffs, offline mutation/replay, download reconciliation, and trust-boundary
parsing normally justify focused coverage when changed.

## Verification Selection

| Change | Smallest sufficient proof |
|---|---|
| Docs/agent guidance | Link, syntax, metadata, and diff checks only |
| Script/tooling | Static syntax plus a safe targeted execution |
| Localized logic | Focused owning test or existing focused filter |
| Broad shared/package logic | Affected package suite, quiet mode preferred |
| CoreData model | Compile the model, persistence tests, then affected dependents |
| UI/user-visible behavior | Focused logic/build checks plus direct inspection of the changed flow |
| Performance/lifecycle/provider behavior | Targeted tests plus the relevant simulator, trace, or physical-device evidence |

Use focused iteration by default:

```bash
swift test -q --package-path Packages/EnsembleCore --filter OwnerTests
```

Run a full affected package only when the change crosses many owners, changes a
shared contract, or a focused selection cannot establish safety. Do not run the
whole app suite merely because one file changed. Do not add edit hooks that run
broad suites automatically.

## Runtime Evidence

Use `simulator-test` for runtime mechanics and `surface-sweep` only for an actual
surface sweep. Navigate to and exercise the changed state; an app launch or an
unrelated screenshot is not proof. Verify the installed/running artifact first.

Treat Ensemble's debug framework as the runtime control plane. Use its launch
surfaces and deep links to establish nearby state, stable identifiers to find
controls, and `USER_JOURNEY` logs to confirm accepted commands. Then exercise the
actual behavior under test: a debug route does not prove its corresponding tap,
scroll, animation, or transition. Add the smallest shared automation hook when
future agents would otherwise repeat fragile setup; do not add one-off shortcuts
that bypass the contract being verified.

Concurrent simulator runners require a dedicated UUID and DerivedData path per
runner. Never target `booted` or switch the global Xcode selection. Serialize
Device Hub, Simulator.app Computer Use, and iPhone Mirroring. Follow
`simulator-test` and `docs/reference/agent-runtime-testing.md` for the current
input and recovery protocol.

Apple Music authorization/DRM, system Now Playing, AirPlay, background/locked
handoffs, and live provider mutations require physical-device evidence when
those contracts change. Report an unavailable environment as residual risk.

Keep mocks at protocol boundaries and use in-memory CoreData stacks; never use
`CoreDataStack.shared` in tests. Treat a flaky asynchronous failure as evidence
to investigate, not a reason to add sleeps or duplicate retries blindly.
