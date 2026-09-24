# Offline replay and streaming recovery fixes

September 7, 2026. Implements the findings from the
[simulator root-cause investigation](2026-09-07-simulator-root-cause-followup.md).

## Delivered behavior

- Mutation replay retains error classification. Transport, cancellation, 429,
  and server failures keep records pending without spending the permanent-error
  budget. A temporarily failing server defers its remaining rows while other
  owners can proceed. Permanent rejections retain the five-consecutive-failure
  cutoff. One recovery task retries after 30 seconds, backing off to
  at most five minutes, and does not keep retrying when the device is offline.
  Successful acknowledgment remains the condition for deletion; persistence
  write failures are surfaced in logs rather than silently ignored.
- Streaming progress uses PCM frames actually consumed, including across pause
  and resume. Missing frames never advance the content clock. Known-duration
  completion still works, using consumed content time instead of elapsed wall
  time. Obsolete consecutive-underrun detection was removed.
- Temporary starvation keeps the live stream and collects a one-second PCM
  reserve before resuming output. Playback publishes buffering while waiting.
  A continuous 30-second rebuffer still invokes the existing recovery path;
  actual transport failures retain their existing handling. Pause resets the
  rebuffer deadline, and generation checks protect newer playback requests.
- Playback preparation reserves the connection before async source resolution.
  During streaming, reserve below three seconds defers new sync/prefetch work
  and suspends downloads; eight seconds releases that pressure. Existing
  foreground work scheduling also observes the pressure. Download suspension
  preserves the user's manual pause and network restrictions.
- Bounded cumulative missing-frame diagnostics expose repeated short gaps.
  Counters live inside the PCM buffer's existing lock; no render-time logging
  or additional render lock was introduced.

Existing failed mutations are not automatically reset: their stored rows do not
retain enough error classification to distinguish old transport failures from
semantic failures. They remain available through the existing explicit retry.

## Simulator evidence

Same dedicated iPad A16 simulator (`08CA3DD8-D174-40E9-A361-62B95671B969`),
iOS 26.5 / 23F77, uncached Downstairs track, requested 320 kbps MP3, and shared
48,000 encrypted downstream bytes/second. The baseline container was restored
before each trial. Built/installed executable hashes and running process paths
were checked. Temporary hooks controlled workloads and sampled diagnostics;
none altered the new production decisions.

| Case | Before | After |
| --- | --- | --- |
| Sync alone | 0.844 / 0.789 s missing audio | **0.000 s**, first audio 961 ms |
| Combined sync + download, about 45 s | 12.159 s missing audio in original trial | **0.000 s**, first audio 879 ms |
| Extended combined run | No extended baseline | **0.000 s over 91.648 s** of sampled render callbacks |
| Single four-second gap | Stream restarted; restart first audio took 2,500 ms | **No restart**; playhead held at 2.4 s during starvation |
| Forty-second gap | Not previously measured | Recovery invoked after the 30-second bound; playback resumed when delivery returned |
| Four failed mutation drains | Failed at three; manual reset needed | **Pending, zero permanent retries; automatic recovery succeeded** |

The short gap still necessarily produced silence: 3.051 seconds in the fixed
trial, including the deliberate rebuffer reserve. The claim is correct content
time and connection retention, not elimination of an imposed network outage.

Sync began about ten seconds after playback measurement started, once its
reserve was available. In the extended run, the same download attempt started
at 20:58:34, suspended at 20:58:52, and restarted at 20:59:15. Playback remained
free of missing frames throughout. A later suspension/restart also occurred;
no complete album download is claimed under this constrained workload.

Download suspension deliberately reuses existing cancellation/requeue behavior.
It is not byte-range resume: partial-transfer efficiency on long downloads
remains a transport limitation. Admission gates do not interrupt an already
running catalog request. These changes prioritize playback and prove recovery
scheduling; they do not guarantee bandwidth allocation for every workload.

For mutation replay, two fabricated rating requests were intercepted by
URLProtocol while using the real coordinator, provider routing, and CoreData
repository. One was acknowledged once. The second remained pending through
four transport-failed drains, then was acknowledged by the scheduled retry
without another path change or a manual retry. No synthetic rating reached PMS.

## Verification and limits

- **69 focused tests passed**, covering streaming, PCM buffering, mutation error
  classification, foreground scheduling, download policy, playlist mutations,
  and sync artwork invalidation. The download regression checks both automatic
  recovery and preservation of a user's manual pause.
- Full Core run: 1,165 tests, 15 assertion failures in three unrelated test
  cases. An isolated worktree at unchanged `52d36184` reproduced the same 15
  assertions in the same playlist-casing/source-cleanup cases. These failures
  predate this change; they are not reported as a passing full suite.
- The saved gap-free check passed for fixed sync, combined, and extended runs.
  Replay phase, frozen-clock, bounded-recovery, and baseline-failure comparison
  assertions passed.
- Ten replay/playlist checks also passed after retaining the permanent-rejection
  cutoff in final review. Clean app rebuild passed after removing the test hooks. The clean app was
  reinstalled, playback ended, the dedicated simulator shut down, and the proxy
  stopped. The original simulator and global network settings were unchanged.

Physical radios, energy use, AirPlay/Lock Screen behavior, iOS 27, a three-day
soak, and real PMS acknowledgment-loss/idempotency semantics remain outside
this simulator validation. Queues in these bandwidth trials contained one track;
next-track prefetch admission was not independently exercised in a multi-track
bandwidth trial here. No new external dependency was added.

## Artifacts

- [Measurements](artifacts/2026-09-07-offline-streaming-fixes/measurements.json)
- [Focused evidence](artifacts/2026-09-07-offline-streaming-fixes/evidence.txt)
- [Test-hook patch](artifacts/2026-09-07-offline-streaming-fixes/instrumentation.patch)
- [Baseline failure comparison](artifacts/2026-09-07-offline-streaming-fixes/baseline-failures.json)
- Local runners, private baseline, raw logs, and full build/test output:
  `/tmp/ensemble-network-audit/`.
