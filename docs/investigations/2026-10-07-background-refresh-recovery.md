# iOS Background Refresh recovery

## Delivered behavior

`SyncCoordinator` writes the enabled source keys to an atomic app-support file
before a background attempt starts remote work. Each source retains its key until
the library and applicable playlists complete, along with awaited Siri catalog
publication and reconciliation of existing offline targets. Interruption retains
unfinished keys; already committed data and incremental cursors survive.

Cold launch, warm foreground activation, and the existing foreground timer retry
the handoff. Foreground recovery also adds every currently enabled source, since
a source that completed in background may have changed again before opening.
Unavailable configuration preserves outstanding work; authoritative source
disablement can remove its key.

The background coordinator uses a cooperative 25-second deadline, with six-second
source budgets and Plex before Apple Music. Cancellation reaches the owned source
task and providers check cancellation at pagination and persistence boundaries.
These are cooperative deadlines, not a guarantee that a native framework await
returns within a fixed wall-clock interval. The persisted handoff remains the
recovery mechanism if iOS suspends or terminates the process first.

The shared Siri catalog can update in background. Spotlight compares it with a
separate applied snapshot, acknowledged only after deletion and indexing succeed.
Foreground activation retries Spotlight even when no source handoff remains.
Offline reconciliation only refreshes existing selections and uses the existing
persistent download queue and network/pause policies.

## Physical-device evidence

Verification uses the physical iPhone 16 Pro over USB and the signed workspace
Debug build. Installed app receipts, process executable paths, and debugger image
UUIDs distinguish the produced build from previously installed artifacts.

- The registered SwiftUI refresh handler saved five source keys while the app was
  in background. Those keys survived explicit process termination.
- Cold launch resumed the handoff automatically, advanced all five library source
  timestamps, completed the awaited library/playlist follow-ups, cleared the
  marker, and indexed changed Spotlight items.
- A debugger-assisted one-second budget with a three-second cancellable delay
  returned incomplete after approximately 1.04 seconds and retained all five
  source keys. This timer check ran in foreground; it is not natural OS expiration
  evidence. The existing foreground fallback later recovered the handoff.
- A normal-budget invocation in actual background committed all four Plex
  library phases and the three server playlist phases before Apple Music work
  remained pending. The test's UIKit assertion had started before the callback,
  so suspension in that run does not establish a failure of the full deadline.
- On the final installed artifact (debug image UUID
  `37610F40-F192-3D76-9205-22EF57FA8123`), the app entered background at
  09:41:10.460. A host-side fixture append was confirmed at 09:41:17.245;
  the registered handler entered at 09:41:17.522. Before reopening, the cached
  playlist grew from three to four tracks, offline membership included the new
  track with a persisted pending high-quality download, and Siri saved a changed
  catalog. All four Plex library phases and three server playlist phases finished.
  Apple Music cancellation was handled at its six-second source budget; its
  source remained pending. The handler returned incomplete at 09:41:34.191,
  approximately 16.7 seconds after entry, with the last-good Feed also refreshed.
  The UIKit assertion used to assist this check began only after actual
  background transition. This proves background discovery and queueing;
  download transfer completion is checked separately.
- Terminating that final process and cold launching the same artifact retained
  the Apple Music-only marker. Startup resumed at 09:45:27.110, expanded the
  handoff to all five enabled sources, completed every library and playlist
  follow-up, and cleared it at 09:45:38.334. Spotlight indexed three changed
  items at 09:45:40.440. The four-track playlist and offline membership survived
  the relaunch without a manual refresh.
- With no source handoff pending, foreground-only verification restored the
  previous three-track Spotlight applied snapshot while leaving the four-track
  Siri catalog intact. An ordinary Home/reopen cycle indexed the outstanding
  changes and acknowledged the four-track snapshot. No manual sync or indexing
  method was invoked. Spotlight waited for its existing foreground idle gate;
  Siri's shared catalog remained fresh throughout.

The two later fixture file transfers reached immediate native media retrieval
but timed out after 60 seconds and were retained for retry. Discovery and durable
queueing are proven; completion of those two files is not. These checks involved
the debugger, so the cause is not established. The existing successful fixture
files are positive controls, not completion evidence for the newly discovered
track. The follow-up is recorded in the project's known-issues watchlist.
An additional uninterrupted foreground minute with the debugger detached also
left those two files unfinished. Their retained queue state was captured before
fixture cleanup.

Debugger-assisted handler invocation proves the registered route and observed
work, not natural scheduling frequency. iOS chooses when to run refresh tasks;
see [Apple's background strategy guidance](https://developer.apple.com/documentation/BackgroundTasks/choosing-background-strategies-for-your-app).

No unit or integration suites were run. Both signed iPhone and macOS workspace
builds passed. Disposable playlist fixtures and their device-local downloads are
cleaned up separately from the user's existing offline selections.

Cleanup verification restored the original six target keys and all 322 completed
download rows (127 high quality, 195 original). The disposable playlist, target,
memberships, and four fixture download links were absent; the remote server
returned its original 38 audio playlists. Existing library tracks were preserved.
