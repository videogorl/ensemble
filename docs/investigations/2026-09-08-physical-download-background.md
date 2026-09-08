# Physical download background recovery

Tested on iPhone 16 Pro, iOS 27.0 (24A5430a), using Device Hub for input and
CoreDevice FBEDD183-439E-58D7-BB94-56B9BAC9415A for installation and evidence.
Starting commit: 0c1ddbe2. No network settings were changed: Device Hub was
connected over the same Wi-Fi link needed to control the phone.

## Findings and repair

The first run stopped 27 seconds after backgrounding (06:28:14.797 to
06:28:41.794). A native continued-processing indicator had appeared, but the
short UIKit assertion's expiration unconditionally finished the longer task.
The coordinator now ends the short assertion when the continued grant arrives,
ignores stale continued-task expiration callbacks, and avoids replacement
requests while a grant is active. The original run lacked explicit grant logs,
so its exact grant lifetime is not independently reconstructable.

A second run with grant logging exposed a separate entry-point gap: manual
Resume did not request continued processing until backgrounding. The request
was submitted, but no grant arrived; the short window expired after 26 seconds.
Manual Resume now requests the grant in the foreground. The final run logged
submission at 06:42:26.103 and execution granted at 06:42:26.135.

This follows Apple's separate lifetimes for
[UIKit assertions](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:))
and [continued processing](https://developer.apple.com/documentation/BackgroundTasks/performing-long-running-tasks-on-ios-and-ipados).
OS expiration still pauses safely; a submission alone does not prove a grant.

## Build and checks

- Workspace device build passed; 28 focused Core tests passed, including a new
  manual-Resume regression that requires a request before backgrounding.
- Final install receipt and live PID 66984 agree on bundle container
  BD9D1E91-5DCB-4614-8707-6495A41A4BF1/Ensemble.app/Ensemble.
- Incremental builds retained version 202609080621.0126, so version alone is
  insufficient: the fresh install/process evidence and new grant log establish
  the running implementation.
- Raw logs and receipts remain private under
  /tmp/ensemble-phone-downloads-20260908. Sanitized evidence is adjacent below.

## Scope and side effects

Real connection-loss errors occurred on the phone. Other tracks continued,
retries deferred, and original downloads successfully returned HTTP 206.
This proves resilience on this device/PMS path, not the cause of the frequent
connection losses, long-term energy consumption, or three days offline.

Temporarily selecting Original quality triggered existing target reconciliation
and queued upgrades across existing downloads, beyond the added 12-track
The Maybe Man target. Existing files are preserved while upgrade rows become
pending; lower completed counts do not mean those files were deleted. High
(320 kbps) was restored, but already queued Original upgrades retain their
requested quality. Remaining work is left paused to bound network use.

## Final locked interval

From 06:43:05.847 (background) through 06:45:13.994 (return), 128 seconds,
21 tracks completed, 19 responses were HTTP 206, and 25 transient failures
were deferred. No background expiration appeared during this interval.
Independent lock-state checks at both collection points required a passcode.
This is a short physical lifecycle check, not an overnight endurance test.

[Sanitized transfer evidence](artifacts/2026-09-08-physical-download-background/phone-evidence.log).
At cleanup, the UI showed High (320 kbps), cellular downloads off, a Play
button confirming the queue was paused, and Nothing Playing. Final CoreDevice
lock-state check reported passcodeRequired=true. Existing queued quality
upgrades and the added album target remain; no existing downloads were removed.
