# Native networking: recovery validation and consolidation candidates

September 8, 2026, following `b4202124`. This pass changes investigation code
only; the shipping downloader remains unchanged.

## Recovery findings

A real loopback HTTP server and optimized Swift command-line client ran on
macOS 26.6.2. Cancellation and resume run in **different processes**, using an
8,388,608-byte deterministic payload. This validates native partial-file reuse
across process exit, not an iOS app's background-session reattachment.

Raw `URLSessionDownloadTask` behavior:

- Normal resume: HTTP 206 from byte 1,048,576; full hash matches.
- Changed resource, server returns 200: restarts from zero; new hash matches.
- Server ignores Range: restarts from zero; original hash matches.
- No entity validator: cancellation supplies no resume data; fresh request works.
- **Malformed Content-Range:** server starts 128 bytes later than requested.
  Native completion reports success, but the output is only 8,388,480 bytes and
  its hash is wrong. Native resume does not replace Ensemble's range validation.
- **Malformed resume data:** passing `Data("invalid".utf8)` directly to the native
  API raises `NSInvalidArgumentException` inside CFNetwork `_expandResumeData:`
  and aborts the process. Swift `do/catch` does not catch this Objective-C exception.

The guarded prototype adds a Codable record containing Apple-produced resume
bytes and their SHA-256 digest. Unreadable or mismatched records trigger a fresh
request before entering CFNetwork. The digest detects accidental corruption;
it is not authentication against an attacker who can rewrite the record. Resume
records can contain credentials and must remain private, never logged or synced.

For HTTP 206 it checks the native resumed offset and exact Content-Range against
the completed file's length before accepting output. It also validates status
and known full-response length. This preserves the important shape of the
existing `ResumableDownload.validContentRange` guard.

**Eight guarded cases passed:** normal resume, changed resource, ignored Range,
malformed Range rejection, missing validator, deleted native temporary file,
invalid saved record, and a readable record with corrupted resume bytes. Every
accepted file matches its expected hash. The missing-file case actually removes
the single temporary file named by this test's native archive before starting
the next process; inspecting that private archive is test-only fault injection,
not a proposed production API.

This is a migration gate, not a complete adapter. Production integration still
needs request-identity binding, entity-validator continuity, legacy partial-file
preservation, structured cancellation ownership, and background task-to-queue
association with completion delivery across relaunch. The raw native API is not
a safe drop-in replacement. The previous phone benchmark's speed advantage
remains promising, but does not override these data-integrity requirements.

## Broader native API candidates

| Existing owner | Native API opportunity | What must remain |
| --- | --- | --- |
| `ResumableDownload` | Download task file delivery and delegate progress replace the byte loop and its buffer writes. | Validated resume records, HTTP/range checks, safe installation, persistent queue. |
| `OfflineDownloadService.canExecuteDownloads` and `DownloadTransferExecutor.downloadWithProgress` | Set `URLRequest.allowsCellularAccess` and `allowsConstrainedNetworkAccess` from the queue's effective policy. The direct request currently carries neither restriction. Native enforcement closes the gap between path observation and actual request routing. Apply consistently to queue-media requests as well. | User settings and explicit temporary overrides; UI reasons and queue scheduling. Expensive interfaces are not synonymous with cellular, so do not silently turn cellular preference into an expensive-network ban. |
| Shared API/download transport | `URLSessionTaskMetrics` can supply DNS, connection/TLS timing, connection reuse, protocol, and transfer counters instead of inferring causes from elapsed time and error codes. | Privacy-safe summaries; app payload totals and system-level measurement are different quantities. Never log raw metric URLs or addresses. |
| Eligible deferred transfers | `waitsForConnectivity` can let the transport wait for an allowed interface rather than repeatedly creating requests. | Persistent retries after a connection drops, server failures, bounded endpoint failover, cancellation, and task-slot ownership. A waiting task must not silently occupy the queue forever. |
| Background bulk downloads | A stable background `URLSession` can transfer while suspended and deliver completion after system relaunch. | Plex transcode preparation, queue reconciliation, app completion handlers, file validation, and explicit user cancellation. A successful foreground test of a background-configured session is not lifecycle proof. |

`NetworkMonitor` already uses `NWPathMonitor`; `PlexWebSocketManager` already uses
`URLSessionWebSocketTask`; `StreamingAudioPipeline` already enables
`waitsForConnectivity`. Replacing these owners with another networking package
would not remove their app-specific responsibilities.

`ArtworkLoader` uses installed Nuke plus source-scoped persistent artwork. Its
URL lookup cache resolves Plex URLs; it is not an HTTP response cache that
`URLCache` can replace. URLCache also cannot promise durable offline artwork.
Likewise, `ProgressiveStreamLoader` delivers bytes to playback before completion;
it cannot simply become a completed-file download task. Keep both playback
engines and their shared playback contract.

Recommended order: finish the guarded download adapter, enforce effective
network restrictions at the request boundary, then add native task metrics to
measure connection reuse and repeated requests. Consider connectivity waiting
per workload after that evidence. No new dependency is needed.

Apple references: [connectivity waiting](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/waitsforconnectivity),
[Low Data Mode restrictions](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/allowsconstrainednetworkaccess),
and [task metrics](https://developer.apple.com/documentation/foundation/urlsessiontaskmetrics).

## Reproduction

Artifacts: [native recovery](artifacts/2026-09-08-native-recovery/).
Use a new private temporary directory as the argument to both Python scripts.
Compile `NativeResumeAudit.swift` with `swiftc -parse-as-library -O`, naming the
output `audit-guarded` in that directory. Write `normal` to its `mode` file, run
`server.py <directory>` (loopback port 18769), then `check.py <directory>`.
The check uses only synthetic local data, validates hashes/rejections, and
writes `guarded-results.txt`. Stop the owned server afterward. The retained
unguarded result records the failed baseline; the guarded runner intentionally
does not crash a process to repeat that failure.
