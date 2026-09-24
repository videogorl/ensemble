# Native background downloads

September 8, 2026. Baseline: `ce8df581`.

## Transport ownership

Production original-file and Plex download-queue media transfers now use a shared background `URLSessionDownloadTask` transport in EnsembleAPI. URLSession owns byte delivery and opaque resume data; Ensemble retains admission, Plex preparation/authentication, retry limits, target membership, validation, quality, and database acknowledgment. No package dependency was added.

The transport stores task identity before starting, reattaches system tasks after launch, and commits temporary files synchronously in its delegate before returning. Durable receipts survive the window between transfer completion and installation. A hard link gives the installer an owned file while preserving the receipt until acknowledgment. Removal and source/cache cleanup reconcile against authoritative database membership; failed reads preserve receipts.

Resume state is checked before passing it to CFNetwork. A resumed response must describe the same complete entity; rejected ranges restart once cleanly. Changed request credentials, endpoint, or network permissions start a fresh request. Inactive records require current provider resolution. Cancellation retains native resume data when available; unavailable resume data still requires a clean restart. Old strong-validator partial files drain through the previous transport once; normal new transfers no longer use the per-byte loop.

The OS execution grant expiring no longer cancels active native transfers. Queue admission still honors pause, connectivity, Low Data Mode, cellular permission, low power, and playback protection. Completed receipts can be installed without another provider/network request.

See Apple's [background download guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

## Correction: the short transcode's source is damaged

For track 11631, Christmas in June, Plex metadata and the original FLAC header advertise 279.36 seconds. The original served bytes are 15,990,784 bytes, SHA-256 `1df752aa5b21fb82db550e670798dd0b988aa781d3fb7be4c53ffea8021c5e50`.

FFmpeg reports invalid residual/decode-frame errors and only decodes 133.932698 seconds. AVAudioFile fails after 5,906,432 frames against 12,319,776 advertised frames. Plex's 4,136,998-byte prepared MP3 is also 133.932698 seconds, including after explicitly restarting preparation. This is evidence of a damaged original as served by PMS, not evidence that Ensemble's range resume truncated the transcode. The server filesystem itself was not inspected.

The earlier server-hash match proved HTTP integrity, not playable duration. The shared installer now decodes in bounded 32,768-frame chunks off the main actor before replacing a file. It stops at the advertised frame count rather than issuing an extra EOF read. The existing conservative metadata-duration comparison uses decoded frames. Unsupported formats that cannot be opened by the native decoder retain the earlier open-failure behavior.

The final simulator run rejected this original after two local decode attempts at the same failing frame. Its final message is “Could not validate downloaded audio. Retry, and check the server copy if the problem continues.” The existing file remained byte-for-byte unchanged. Server media repair remains separate work; no server file was modified.

## Runtime evidence

Exact simulator: `08CA3DD8-D174-40E9-A361-62B95671B969`, iPad A16, iOS 26.5. Installed executable matched the built executable before each lifecycle run. Track 12941 is a healthy 24,527,090-byte FLAC, fully decoded to 230.9867 seconds; SHA-256 `93413191b0bd8d06046bc25b4e265cb6a91a3d65f54b1e2d520fd67194ce8320`.

- Process suspension: SIGSTOP after 65,536 native temporary bytes. Four seconds later, while Ensemble remained stopped, the daemon-owned file had all 24,527,090 bytes. SIGCONT led to a completed row with the expected hash.
- Process loss: SIGKILL after 2,097,152 native temporary bytes. A new session log began at 11:14:38 and recorded native completion at 11:14:38.935, before the scripted manual launch after the four-second wait. Installation at 11:14:41.201 matched the expected hash. This demonstrates recovery from process loss; it does not model a user force-quit or reboot.
- Damaged original: the normal queue on the updated simulator build failed validation and preserved the previous file.

Physical device: iPhone 16 Pro, iOS 27.0 (24A5430a), CoreDevice `FBEDD183-439E-58D7-BB94-56B9BAC9415A`. Device Hub supplied UI input. Installation receipts and process executable paths identified the produced signed Debug build.

The two-track Ambient Electric target completed High-quality transfers of 7,281,329 and 10,391,036 bytes, with successful native validation and installation. They completed just before the background transition, so that first run is foreground installation evidence. A later 38,495,372-byte original completed after the logged background transition. One read failed around the lock transition at 13,107,200 of 14,862,876 advertised frames. A fresh server copy decoded fully with FFmpeg and AVAudioFile on the Mac, and a subsequent foreground phone replacement passed. The failed phone body was not retained for hash comparison, so neither a decoder defect nor corrupted server delivery is established.

A temporary 15-second pre-validation delay then made both originals validate and install while already locked, at 11:37:31.881 and 11:37:42.194, after backgrounding at 11:37:20.043. A temporary 100-pass decoder stress run crossed locking without another logged decoder failure, but did not finish before it was stopped after approximately four minutes; it is not a completed stress-test pass. Relaunch installed both durable receipts at 11:45:54.929 and 11:45:55.009 without another logged native transfer. All timing/stress hooks were removed.

The final validator reopens the same local file once on a read error before rejection, checks cancellation, logs the native error domain/code, and uses a neutral failure message. This bounds recovery cost without redownloading bytes. It does not establish the cause or prove a fix for the intermittent phone failure. The deterministic damaged FLAC still fails both attempts and cannot replace the existing file.

The final signed phone build launched from installation `073065D8-0DA3-4F49-926E-656421D91621`, PID 69422. Both target originals were retained (65.7 MB), the download preference was restored to High, playback showed Nothing Playing, and the phone was locked afterward.

An explicit replacement after recovery initially skipped the retained High-quality file because the requested quality still said Original. The action now uses the existing shared installed-quality helper for completed records. Its regression test failed before the fix and passed after it, while preserving the playable file and manual pause.

## Instruments

The 61.77-second Time Profiler capture covers process 68956 from 11:20:58 through 11:21:59, including both High-quality transfers. Validation appeared in 30 ms of sampled stacks across two non-main threads; this is sampled stack weight, not elapsed-time or energy measurement. Thermal state was nominal. Instruments recorded one 1.14-second potential hang during the lock transition; sampled main-thread work included SwiftUI/AttributeGraph trait and layout updates, not a demonstrated download-decoder hang. This remains a separate UI transition lead.

The exporter reported compatibility warnings for newer engineering types and topology. Exported time profiles and lifecycle tables were usable; neither empty hang-risk tables nor nominal thermal state establish smoothness or battery savings. The original healthy Mac FLAC decode took about 0.54 seconds for 24.5 MB. There is no new throughput or battery-saving claim.

## Verification scope

Final verification: 72 API tests and 40 focused Core tests passed; signed iOS-device and exact-simulator workspace builds passed. The final simulator executable and debug dylib matched the installed build. A repeated final suspension run grew the daemon temporary file from 1,114,112 to 24,527,090 bytes while Ensemble was stopped and installed the expected hash after resuming.

The native HTTP test uses a real NWListener server and covers nine cases in one table: valid 206 resume, changed entity 200, ignored range 200, malformed 206, corrupted resume data, stricter network policy, unavailable validator, 416 clean restart, and active removal. It also covers durable completion and recovery from a synchronous delegate receipt before actor acknowledgment.

The original full Core baseline and first changed full run both had 1,175 tests with 15 assertions failing in three existing tests: case-sensitive merged-playlist title selection and two remote library-cleanup tests. A later full run had one additional artist/album cache-event ordering assertion in SyncExecutionControllerArtworkInvalidationTests; that unchanged suite passed in isolation on both baseline and current trees. These failures are not claimed as fixed.

Three-day device reliability, reboot/first-unlock recovery, physical cellular/Low Data Mode transitions, and measured battery/network savings remain unproven. No remote push or server-media change is part of this work.

[Sanitized evidence](artifacts/2026-09-08-native-background-downloads/). Raw traces, private logs, and copyrighted audio remain outside the repository under `/tmp/ensemble-native-implementation-20260908`.
