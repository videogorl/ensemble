# Download retry, suspension, and byte-range recovery

Implemented after the offline/streaming investigation on `9f2233e8`.

## Causes and changes

- Transient failures previously paused a row, then the next worker iteration
  immediately promoted it back to pending while Wi-Fi still appeared online.
  They now remain pending but are excluded from claims until a 30-second retry
  deadline, doubling to a five-minute maximum. One cancellable wake task
  restarts eligible work; there is no polling loop while waiting. Other tracks
  continue. Device connectivity changes are not required for retry.
- Worker cancellation previously finished the background task unconditionally.
  Cancellation now leaves that decision to its lifecycle owner. Playback-buffer
  suspension retains an existing grant; explicit pause/removal, network-policy
  suspension, and OS expiration can still end it. Wind-down retains queue task
  ownership until it is actually finished, preventing overlapping teardown.
- Original downloads previously preferred a fresh universal-transcode URL even
  when a stable file key existed. They now prefer the original file resource.
  Universal conversion/fallback remains available.
- The existing byte-stream transfer now retains written partial bytes in a
  temporary cache. It resumes only with a strong ETag, matching Content-Range,
  and matching remaining length. HTTP 200 replaces the partial file; invalid
  ranges are rejected; HTTP 416 discards the old partial and retries fresh.
  Progress counts retained plus newly received bytes.
- Transcoded retries reuse the same prepared Plex queue item during the process
  lifetime. Media errors return to the queue's retry policy instead of holding
  a worker in a separate retry loop. Media retrieval uses the same resumable
  transport, with a mapped completed file passed to existing validation.

## Simulator evidence

Dedicated iPad A16 simulator `08CA3DD8-D174-40E9-A361-62B95671B969`, iOS 26.5
(23F77). Each experiment installed the newly built app and recorded its process;
installed executable hashes were compared with the build. The temporary
instrumentation uses the real download target, workers, persistence, transfer,
and completion validation. It substitutes only the media URL with a loopback
fault server serving unmodified Plex file bytes. The server supplies a strong
content hash ETag and controlled delivery. No production test hooks remain.

| Experiment | Result |
| --- | --- |
| Drop the first transfer after 262,144 bytes | Track 12937 deferred for at least 30 seconds. Other tracks completed. Its retry requested offset 262,144 and completed the 27,377,882-byte file. Total response payload sent for that track equaled the original file size. Installed SHA-256 matched the source. Eleven tracks completed within the bounded run; the harness stopped the remaining work. |
| Apply buffer pressure after progress exceeds 5%, release after two seconds | Both active transfers cancelled and automatically resumed. Retained offsets were 3,670,016 and 3,604,480 bytes. Each response sent 65,536 more bytes before cancellation than the client retained. Both final files matched source SHA-256. All 12 album tracks completed during the run. |
| Live PMS endpoint controls | The original file endpoints returned HTTP 206, strong ETags, and matching Content-Range. A request for bytes 262144–327679 returned exactly 65,536 bytes. |

Payload counts measure HTTP bodies written by the fixture, not radio energy or
TCP/TLS overhead. The first unsuccessful fixture run reached no media payload
and is excluded from byte-resume conclusions. A preliminary pressure run paused
before headers arrived; it proved queue recovery but is excluded from retained-
byte measurements.

## Verification and limits

- 37 focused Core tests passed, including cancellation ownership, explicit
  removal, user-pause preservation, retry classification, and transfer completion.
- 16 DownloadManager tests passed, including atomic claims that skip a deferred
  track and subsequently reclaim it.
- Three focused API tests passed. Their scenarios cover network interruption,
  explicit cancellation, changed-resource replacement, malformed-range rejection,
  prepared-job reuse after HTTP 503, and queue-ID recovery.
- Clean simulator workspace build passed after removing instrumentation.

Simulator BGContinuedProcessing requests were rejected by the OS. Unit tests
prove app-owned grant handling; this does not prove physical-device background
scheduling, locked execution, or battery savings. No physical device was used.

Servers without a strong validator safely restart instead of appending.
Prepared Plex job IDs are process-local, so transcoded preparation may restart
following process termination. Stable original-file partials can survive relaunch
while the OS retains the temporary cache. Startup cleanup removes abandoned
partials older than seven days; the cache is disposable.

Evidence: [artifacts](artifacts/2026-09-07-download-recovery/), including file
hashes, response byte counts, redacted lifecycle excerpts, provenance, and the
removed instrumentation patch.
