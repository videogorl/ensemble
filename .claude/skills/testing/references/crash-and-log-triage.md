# Crash And Session-Log Triage

1. Open the named artifact first. For note-linked session logs, check iCloud
   Downloads; if the named interaction is absent, retrieve retained app logs
   from `Library/Application Support/Ensemble/Logs` using `devicectl` rather than
   diagnosing a different session. Keep app session IDs and Codex thread IDs
   distinct.
2. Record timestamp/time zone, app version/build, source commit when known,
   device/runtime, and the exact interaction/provider/item. Unknown provenance
   stays unknown; do not attribute it to current HEAD.
3. Classify the report before grouping failures:

   | Evidence | Investigation |
   |---|---|
   | Entitlement exception during startup | Inspect signed entitlements on the installed artifact and the API invoked before the trap. Platform compilation alone does not establish entitlement availability. |
   | Audio graph exception | Inspect the faulting graph operation and matching-build source; distinguish it from transport starvation. |
   | FrontBoard watchdog / `0x8BADF00D` | Inspect termination details, main-thread stacks, and correlated CPU/UI activity. Do not classify it as jetsam or an ordinary exception. |
   | Jetsam / memory-pressure termination | Inspect the termination reason and available memory evidence. |
   | CPU or disk-write resource report | Treat it as resource evidence; establish separately whether the process crashed or was killed. |

4. Identify the app runtime from `procPath`, simulator coalition/runtime, and
   device metadata. Simulator reports can appear in macOS DiagnosticReports;
   the report's top-level OS label alone is insufficient.
5. Correlate report build and symbols with source/history. A later fix or removed
   code path makes a report historical; it does not prove current runtime
   correctness. Without matching symbols or a reproduction, avoid naming an
   exact view from framework-only SwiftUI/AttributeGraph stacks.
6. Reproduce the named flow on a proven fresh artifact when feasible. Separate
   captured facts, suspected cause, and post-fix proof. No new report from one
   launch does not disprove an intermittent failure.

For Instruments evidence, use [trace-analysis](../../trace-analysis/SKILL.md)
and correlate the same run window. Preserve logs before restarting the app;
redact credentials and private media paths from shared excerpts.
