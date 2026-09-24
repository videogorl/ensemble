# Native download scheduling and stalled continued processing

## Finding

The iPhone had two zero-byte native background tasks (tracks 8428 and 11178) while its continued-processing grant stopped advancing and expired. Both exact saved requests were available: 1 KiB range probes returned HTTP 206 in approximately 0.18 seconds. After replacing daemon-scheduled transfers with ordinary native download tasks during app execution, both tracks installed in approximately one second on the same phone.

This supports a scheduling mismatch between the queue's execution grant and the background URLSession. It does not identify the exact private daemon scheduling decision. Apple's [isDiscretionary documentation](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/isdiscretionary) says transfers initiated in the background are treated as discretionary. Its [background transfer guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background) also describes scheduling delays and the resume rate limiter when applications repeatedly wake to enqueue more transfers.

## Change

Keep URLSessionDownloadTask, the existing persistent queue, native resume data, receipts and validated installation. Use an ordinary session while Ensemble owns execution time. At expiration, cancel the app-owned waits with native resume data and submit unfinished files to the existing background session. Reattachment while the app can execute promotes daemon tasks back to the ordinary session. Automatic queue work obtains the existing short UIKit execution window; continued-processing requests remain user initiated.

Both sessions share one serial delegate queue. Signed task identifiers distinguish ordinary and daemon tasks without changing the stored receipt schema. Queue admission pauses during handoff, and explicit pause waits for handoff before cancelling transfers. Lifecycle cancellation is not recorded as a failed track.

## Evidence

Physical device: iPhone 16 Pro, iOS 27.0 (24A5430a). This is physical iOS 27 evidence, not physical iOS 26 evidence. The installed application receipt and PID 70048 executable path matched the newly installed build. Its session log records the new immediate transport.

- Session `session-2026-09-08-132327.log`: immediate tasks started at 13:23:28; tracks 8428 and 11178 installed at 13:23:29.
- Both installed files were copied completely from the phone and SHA-256 matched full responses from their original saved server requests:
  - 8428: 5,319,675 bytes; `9ad3ec9e5de114326ce8f8fceae624225685c72bd6f74f7aaeb16e85b848b734`.
  - 11178: 9,557,813 bytes; `1d7aab372c4793d61070f3471da0ec45a5f0575d5fec7343b0024cd94674b0c9`.
- Short UIKit window: backgrounded 13:23:49, expired 13:24:17; completed receipts installed and recovery finished paused at 13:24:19. No HTTP transfer was still partial at this expiration, so this run proves queue recovery, not physical partial-transfer handoff.
- User pause/resume admitted a 362-track continued-processing batch at 13:26:58. Locked at 13:27:49. By 13:33:05, 118 additional tracks had installed since admission, with progress at 119,000/362,000 and no logged failure or grant expiration. The slight count difference reflects work already in flight at admission. Progress continued for more than five minutes while locked.
- 72 EnsembleAPI tests and 39 focused Core tests passed. The existing real-HTTP resume test now exercises handoff and reattachment, requiring HTTP 206 and exact final bytes. Its injected sessions are ephemeral; this validates resume and task ownership, not iOS daemon scheduling.
- Signed iOS device build and exact-UUID iOS 26.5 simulator build passed. Simulator runtime was not exercised for this change.

Selected privacy-safe evidence is in [the accompanying log](2026-09-08-native-download-scheduling-artifacts/phone.log). Raw receipts containing request credentials remain outside the repository.

## Limits

The locked run is bounded evidence, not completion of the whole library, three-day reliability, or a battery measurement. The OS can still end a continued-processing grant; the queue must remain recoverable. A hard process kill before handoff can require restarting an ordinary active file. Native resume data is not guaranteed, so clean restart remains necessary. Background handoff remains subject to OS scheduling, and physical expiration during a partial HTTP body still needs direct coverage.
