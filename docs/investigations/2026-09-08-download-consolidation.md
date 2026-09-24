# Download consolidation and native transport comparison

September 8, 2026. Baseline: `0e7a2b99`.

## Delivered consolidation

- Plex queue downloads return an owned temporary file URL. The executor reads
  only the first 12 bytes for format detection and moves the file through
  installation; the file-to-Data-to-file rewrite is gone.
- Direct downloads, Plex queue downloads, and playback-cache adoption share a
  staged installation path. Duration/size validation precedes replacement of
  an existing file. Cache adoption copies its source; owned transfers move it.
  Cancellation is checked before replacement, and staging is cleaned on failure.
- Workers call the main-actor processing method directly. The actual byte
  transfer retains its existing off-main task and cancellation bridge.
- Both download detail view models use `CDDownload.installedQuality` for the
  retained-file quality and legacy completed-row fallback.

No new dependency, storage migration, queue policy, or native transport is shipped.

## Verification

- 37 focused Core tests passed: `DownloadTransferExecutorTests`,
  `OfflineDownloadServicePolicyTests`, and `TrackDownloadRowStatsTests`.
- 31 focused API tests passed: `PlexAPIClientTests` and `ResumableDownloadTests`.
- One added table-driven regression feeds a real truncated WAV through direct
  and queue installation. Both reject it, preserve the existing destination,
  leave completion unreported, and clean the temporary file.
- Existing success, playback-cache adoption, removed-target, replacement
  cancellation, quality, and resume tests remain passing.
- Clean Debug iPhone workspace build passed. Benchmark builds use Release `-O`
  with `DEBUG` defined solely to enable the temporary audit entry point.

## What URLSessionDownloadTask would replace

It can replace the byte-by-byte AsyncBytes loop and its buffer/file writes,
progress plumbing, and custom partial-file/range-validator metadata inside
`ResumableDownload`. Native resume data still depends on server validators,
range support, unchanged content, and the continued existence of the OS's
partial file. A failed resume needs a clean restart.

Ensemble must retain queue persistence, cancellation/retry policy, `download=1`
Plex URL semantics, transcode-job preparation, staged audio validation, quality
metadata, and mutation acknowledgment rules. A production background session
also needs stable task-to-download association and delegate handling across
relaunch; the temporary benchmark does not implement those.

Apple references: [background transfers](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
and [resume requirements](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/cancel%28byproducingresumedata%3A%29).

## Benchmark method and limits

Physical iPhone 16 Pro, iOS 27.0 (24A5430a), local Wi-Fi, charging. Same optimized
app process, two different original files concurrently (156,383,059 bytes per
phase), three rounds in alternating order. Both use the same authorized PMS
URLs with `download=1`; custom transfers use fresh identities. SHA-256 is checked
after each transfer. Duration ends before that file's hash, although hashing
one file can overlap the other transfer. No production progress callback is
attached, so this measures transport rather than the entire download queue.

Instruments Power Profiler captures both variants in the same run. CPU impact
is Apple's modeled score, not CPU percentage, joules, or battery drain. Its
approximately one-second sampling limits precision for short native transfers;
app activity and hashing can contribute. Native work in the system networking
process is not fully represented by the app-only score.

The first capture finished six phases but the audit prototype aborted while
setting a per-task delegate on a background-session task. The corrected harness
uses the session delegate there and checkpoints results between phases. This
was diagnostic code, removed from production sources before handoff.

The background-configured task runs while the app is active. It does not prove
suspension, OS termination/relaunch, user force-quit, disk-pressure resume, or
three-day offline reliability. No battery savings or total wire-byte reduction
is established by this experiment.

## Results

| Round | Current paired transfer | Native paired transfer | Current app CPU impact | Native app CPU impact |
| --- | ---: | ---: | ---: | ---: |
| 1 | 6.159 s | 2.051 s | 30.34 | 13.94 |
| 2 | 5.833 s | 2.033 s | 27.68 | 3.05 |
| 3 | 5.802 s | 2.013 s | 25.75 | 0.88 |

Median paired time improved from **5.833 to 2.033 seconds (2.87x)**.
CPU impact is the duration-weighted app score over each transfer window;
variation in the native score makes an exact energy-saving percentage unsound.
The phone was already **Fair** thermally at capture start and became **Serious**
at 46.256 seconds, during the third native phase. This warm, charging device is
not a controlled battery experiment. A cool-device repeat would strengthen
quantitative estimates before using them for product claims.

All 14 completed files match independent server SHA-256 references: 12 comparison
files plus resume and background-session outputs. Native cancellation returned
resume data and resumed at **4,014,080 bytes**, with HTTP **206**, producing the
full 101,100,001-byte file. The background-session file completed in **1.855 s**
(including its hash in this diagnostic timer), HTTP 200, with matching hash.

The clean production-source Debug build was reinstalled and its fresh process
path verified. Download management still showed High (320 kbps), cellular
downloads disabled, and 6.08 GB retained. The secret-bearing benchmark config
was automatically removed from the phone; the audit hook is absent from shipped
source. This pass did not requeue or replace the user's existing downloads.

## Next decision

The benchmark supports replacing the transport with native download tasks,
but that migration is deliberately separate from this consolidation. First
validate missing/invalid resume data, changed server content, task cancellation,
and background session reattachment against the existing queue. Retain clean
restart and the same safe installer. Do not add a third-party download package.

Sanitized results, phase logs, and the temporary harness are in
[the artifact folder](artifacts/2026-09-08-native-download/). Private raw trace:
`/tmp/ensemble-native-download-20260908/native-verified.trace`.

To reproduce the temporary harness: copy its `.swift.txt` source into the Core
services target; call `runNativeTransferAudit()` from a DEBUG-only app task after
pausing the queue and waiting ten seconds for startup. Keep the screen awake
during the audit. Supply a private `Documents/NativeTransferAudit.json` array of
`{"name":"track-id","url":"authorized-PMS-download-URL"}` entries. Build Release
with `SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, install on the exact device,
and capture Power Profiler while launching that entry point. Copy results before
removing the hook and reinstalling a clean build. This harness is diagnostic,
not a reusable production networking service.
