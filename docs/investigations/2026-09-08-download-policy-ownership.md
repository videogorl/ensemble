# Download policy and task ownership

September 8, 2026. Baseline `a82f78c5`.

## Simplification delivered

The persistent queue resolves one effective `DownloadNetworkPolicy`. A nil
result means no transfer is admitted; an admitted transfer carries the same
cellular and Low Data Mode permissions into its native URLRequest. Both direct
originals and Plex queue media use it. A valid temporary exception remains in
the request permissions when a transfer begins on Wi-Fi before a path change.
Offline still blocks admission, and exception expiry still pauses work.

This closes the gap between queue-only reachability checks and the interface
URLSession actually uses. Native restrictions complement path observation;
they do not replace the queue's durable policy. Plex preparation/metadata
requests retain their existing API policy; this change restricts audio payload
requests. Expensive-network access is not silently equated with cellular access.

Removed the direct transfer's detached task and its extra cancellation bridge.
The worker now awaits the shared transport directly. The API package uses Swift
5.7 language/configuration semantics: its nonisolated async function executes
on the generic executor, so the main-actor caller does not need to manage an
extra off-main task. See [SE-0338](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0338-clarify-execution-non-actor-async.md).
The transport retains its own URLSession cancellation and partial-file checks.

The direct path now owns original quality unconditionally. Previously an empty
queue payload could fall through to a direct original while retaining the
requested quality in its filename/metadata. Extending the existing fallback
test reproduced `medium` instead of `original`; choosing quality at the direct
path removes that mutable transition and fixes both empty and failed fallback.

No new manager, package, persistence layer, or background task system was added.
The durable queue owns intent/retry policy; transport owns HTTP and partial files;
the existing installer owns validation and replacement. A native download-task
implementation can later replace transport without making callers own its state.

## Verification

- 31 API checks passed, including native request flags across resume/retry and
  queue-media retry without creating another transcode job.
- 31 Core checks passed, including temporary override/expiry/offline policy,
  both direct fallback cases, and preservation of an old file after rejection.
- Stabilized the existing explicit-removal test by cancelling its startup worker
  before measuring the removal's completion call. Its old absolute count raced
  a legitimate idle-loop completion; the assertion still requires one additional
  completion for removal.
- Exact simulator: `08CA3DD8-D174-40E9-A361-62B95671B969`, iPad A16, iOS 26.5.
  Signed Debug workspace build passed. Final installed executable hash matched
  the built executable, and the running PID used that installed path.
- On the policy/cancellation build, UI Retry for the existing failed track 11631
  exercised both media paths. Plex supplied a 133.9-second transcode for a
  279.4-second track; validation rejected it. Direct fallback installed the
  15,990,784-byte original, matching a fresh server SHA-256 reference. The
  simulator's retained count went from 26 to 27. The final empty-payload fix was
  then checked by the regression test and final build/reinstall; the retained
  count stayed 27 and playback showed Nothing Playing.
- The live original-file endpoint separately returned the requested 65,536-byte
  HTTP 206 range.

[Sanitized runtime evidence](artifacts/2026-09-08-download-policy/).
No new throughput or battery claim follows from this pass. Native background
session reattachment and physical cellular/Low Data Mode transitions remain
separate validation work; the native download-task prototype is not activated.
