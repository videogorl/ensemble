# Focused Download And Lifecycle Checks

Select the rows affected by the change, using existing focused coverage first.
Use the [physical sweep](../../surface-sweep/references/physical-download-sweep.md)
only when a full sweep is requested; its fixture and cleanup rules apply when
using its physical procedures. This reference grants no mutation authorization.

## Download Checks

| Change | Evidence to collect |
|---|---|
| Completion or recovery | Correlate source/track, queue-item identity, completion rows, and installed files across recovery. Require exactly one durable completion for the intended item/revision/quality; an empty queue alone is insufficient. |
| Quality or transfer replacement | Requested quality survives recovery. Explicit quality changes supersede old work; a late old completion cannot install over the replacement. Preserve the usable old artifact until replacement succeeds. |
| Target removal or membership reconciliation | Removing one target preserves shared files; removing the final reference removes its artifacts. Failed or partial membership reads are not evidence of zero references. |
| Resume or transport handoff | Exercise an interrupted body using existing HTTP fixtures; check status, expected bytes, validators, content range, and resume offset. Invalid resume state must not install a truncated file. Compare final bytes/hash where a stable original is available. |
| Lyrics retries | An unchanged missing-stream signature does not trigger a retry storm. Distinguish confirmed absence from retryable transport/server failure. |

## Lifecycle Evidence

Passing one state does not prove another. Record the transition actually reached
and correlate its timestamps with app logs and the current installed build.

| State or transition | Required distinction |
|---|---|
| Foreground | Establish progress and persisted state before leaving the app. |
| Background | Confirm the inactive/background transition; the app may still own execution time. |
| Locked | Independently query device lock state. A black mirror or successful lock command is insufficient. |
| Suspended | Require evidence execution stopped while the process remained present; background or lock alone does not establish suspension. |
| Execution-grant expiration | Capture the actual expiration and transfer of unfinished work. A debug callback checks app logic, not OS delivery or daemon continuation. |
| Process termination and relaunch | Record how the process ended and verify persisted recovery after a fresh launch. User force-quit, OS termination, and suspension are distinct cases. |

For downloads, verify durable completion, quality, and file integrity across the
selected transition. For playback, cross an actual item boundary and correlate
logical item/index, active provider, playhead, and exactly-once advancement; old
callbacks must not alter a newer request. Test relevant provider directions and
output routes on a physical device. Moving progress alone does not prove audio.

Report unobserved states as unverified. Request/probe counts and thermal logs are
diagnostic evidence, not measurements of battery savings.
