# Continued processing: Apple lifecycle integration

2026-09-08. Builds made with Xcode 26.6. Physical testing used iPhone 16 Pro,
**iOS 27.0 (24A5430a)**; the API is available from iOS 26. This is not physical iOS 26 proof.

## Delivered behavior

- Register and submit the same fresh concrete identifier for each user-requested
  pass. Only the permitted plist entry uses a wildcard. Deduplicate outstanding
  requests and ignore obsolete grants delivered after their pass ends.
- Submit only while the app is active, from the existing user download/resume
  actions. Use `.fail`: work already runs independently, so there is no reason
  to enqueue an accelerator that could arrive after the work finishes.
- Feed native byte progress for direct, transcoded, and restored transfers into
  the system task. Report bounded audio-decoding progress too. Updates use existing
  transport throttling and at most one validation callback per second plus boundaries.
- Scope progress to unique queue rows in the requested pass. Each row has 1,000
  units: transfer contributes 900, validation 90, and completion of the attempt 10.
  Units never regress during fallback. They describe **processing the pass**, not
  the number of successfully installed downloads; the persistent queue owns failures
  and retry status. Existing/overlapping targets no longer inflate the denominator.
- End an idle pass even if durable work is waiting for retry backoff. Clear its
  background admission when relinquishing the grant. Existing URLSession transfers
  and durable receipt recovery remain independent of the processing grant.
- Preserve the short UIKit fallback, OS expiration callback, playback-buffer pause
  policy, and installed-file safety. No package, alternate queue, polling heartbeat,
  or manufactured elapsed-time progress was introduced.

## Evidence

The initial wildcard-handler attempt was rejected by the phone. Native transfers
still completed through the existing fallback, and its short UIKit window expired.
The final implementation registers concrete IDs on demand, as Apple recommends.
See [registration-attempt.log](artifacts/2026-09-08-continued-processing-guidance/registration-attempt.log).

Three subsequent continued tasks were admitted and completed, with six native
files totaling 149,089,263 bytes. No continued-task expiration or download error
was logged in these three passes.

| Pass | Grant | Completion | Observation |
| --- | --- | --- | --- |
| Original, two tracks | 12:34:53.903 | 12:35:03.222 | App backgrounded at 12:34:59.805; final file installed at 12:35:02.582 while locked. Progress continued through 1547, 1728, 1900, 1990, 2000 of 2000 units. |
| High, same app session | 12:37:32.479 | 12:37:35.331 | Second registration/submission worked without relaunch. Both files installed before the lock took effect. |
| Original, final build | 12:40:49.484 | 12:40:56.379 | Both originals installed; system task finished at 2000/2000. Backgrounding occurred at 12:40:57.056, so this is foreground completion proof. |

[Consecutive-request evidence](artifacts/2026-09-08-continued-processing-guidance/consecutive-requests.log)
and [final-build evidence](artifacts/2026-09-08-continued-processing-guidance/final-build.log).
The final build additionally clears background admission at queue wind-down;
the earlier locked pass had the same registration, transport, and progress code.

The final installed app was verified against its installation receipt:
`F4F125D8-664D-451A-91F6-2CA137D4A7A8/Ensemble.app`, running PID 69742.
The target ended with both originals retained (65.7 MB), and the quality preference
was restored to High without requesting another replacement. Nothing Playing was
verified, and the phone was locked after testing.

- 39 focused Core tests passed: background coordinator, queue coordinator,
  transfer executor, and service policy. Added scoped-progress coverage, checked
  intermediate native decode progress, and updated foreground-only request coverage.
- Four native transport tests passed. API changes only forward progress callbacks.
- Final signed iOS device and iOS 26.5 simulator builds passed. Simulator build
  destination: `08CA3DD8-D174-40E9-A361-62B95671B969`.
- [Core results](artifacts/2026-09-08-continued-processing-guidance/core-tests.txt)
  and [API results](artifacts/2026-09-08-continued-processing-guidance/api-tests.txt).

## Limits

These bounded runs do not establish three-day reliability or battery savings.
No forced backoff or OS-expiration fault was injected into the final build.
The system may still expire a task because of resource pressure, user cancellation,
or real lack of progress. We do not falsify progress or promise to suppress that UI.
An old “Downloading Music / Task failed” card was visible before testing this change;
a prior failed system card is not evidence that a newly admitted task failed.

Plex server preparation can still wait without reporting measurable progress.
Temporary playback-buffer suspension intentionally retains the grant under the
existing download policy; OS expiration remains the bound on that pause.

## Apple sources

- [Performing long-running tasks](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados): foreground user initiation and real progress.
- [WWDC25: Finish tasks in the background](https://developer.apple.com/videos/play/wwdc2025/227/): compose a concrete identifier for registration and submission.
- [DTS: intended registration pattern](https://developer.apple.com/forums/thread/796944): register each concrete instance, not the wildcard handler.
- [DTS: unique IDs and independent work](https://developer.apple.com/forums/thread/807370): start work independently and attach the system task when delivered.
