# Physical iPhone Download Sweep

Use this runbook for an end-to-end download sweep on the user's physical iPhone 16 Pro. Drive visible UI through Device Hub, use `devicectl` for provenance and device facts, and attach Instruments to the exact Ensemble PID.

## Authorization Boundary

The user authorized adding and removing device-local downloads, download targets, queued work, and their local sidecars on this phone.

Never use this authorization to:
- delete a track, album, playlist, collection, library, or other item from Plex;
- edit Plex metadata or playlist membership;
- remove a Plex account, server, or library source;
- clear all synced library data or reset the app;
- incur cellular data charges without separate current approval.

Confirm the selected action says `Download`, `Remove Download`, `Remove Downloads`, or `Remove All Downloads`. Do not select adjacent `Delete Track`, `Delete Album`, or `Delete Playlist` actions.

## Definition Of Complete

Do not call the download system fully swept until every applicable row below passes or is recorded as blocked with an exact reason:

| Area | Required proof |
|---|---|
| Track | Add, complete, play offline, remove, and confirm local eviction. |
| Album | Complete a small album target and verify detail counts, progress, playable rows, and removal. |
| Artist | Complete or deliberately bound a small artist target; verify membership and cleanup. |
| Playlist | Complete a small existing playlist without mutating the Plex playlist. |
| Favorites | Reconcile a favorites target and verify only downloadable provider members are queued. |
| Overlap | Put one source-scoped track in two targets; removing the first target preserves the file, removing the final target evicts it and its sidecars. |
| Library | Exercise enable, queue creation, pause/resume, backgrounding, completion or a documented capacity blocker, disable, and bounded cleanup. |
| Quality | Exercise Original, High (320 kbps), Medium (192 kbps), and Low (128 kbps), including redownload at current quality. |
| Playback | Download during active streaming, play a downloaded item while the queue runs, and prove offline playback. |
| Lifecycle | Foreground, background, lock, foreground recovery, terminate/relaunch recovery, and stale `.downloading` repair. |
| Network | Wi-Fi, offline, Low Data Mode, and cellular-policy UI; transfer on cellular only with separate approval. |
| Failure | Failed row, retry, invalid/truncated payload rejection, direct-original fallback where applicable, and queue wind-down. |
| Removal | Per-track/target removal and the authorized `Remove All Downloads` flow, with no remote Plex mutation. |
| UI/UX | Cross-surface state freshness, counts, progress, errors, retry controls, queue controls, toasts, Dynamic Island/Lock Screen activity, accessibility, and empty state. |
| Performance | Download-only, playback-plus-download, and lifecycle traces with logs aligned to trace timestamps. |

## Preflight And Baseline

1. Start from a clean worktree and record the source commit.
2. Discover the current physical device instead of hard-coding its identifier. Confirm it is Felicity's iPhone 16 Pro and record its current iOS version.
3. Build `Ensemble.xcworkspace` into a fresh DerivedData directory, install it, relaunch with `--terminate-existing`, and prove the installed build number and running executable path.
4. Check device lock state before installation. Use the passcode from `.env` only through Device Hub when needed; never print or persist it in artifacts.
5. Create an artifact root such as `/tmp/ensemble-download-sweep-<run-id>` with `screenshots`, `ui`, `logs`, `traces`, and `reports` subdirectories.
6. Capture a baseline before changing downloads:
   - every library toggle and its account/server/library label;
   - every existing target, status, downloaded/total count, and estimated/on-disk size;
   - active queue reason, quality, cellular setting, Low Data Mode, network path, free device storage, and active playback state;
   - installed build number, PID, app log session, and visible Dynamic Island/Lock Screen activity;
   - existing failures and the names/IDs of test fixtures chosen below.
7. Use only existing Plex media. Do not create, edit, or delete remote Plex content to manufacture fixtures.

## Fixture Selection

Choose the smallest existing fixtures that cover behavior while keeping the sweep fast:

- one known-good two-to-five-minute Plex track;
- one small album, preferably 12 tracks or fewer;
- one small artist, preferably 25 tracks or fewer;
- one small existing playlist, preferably 20 tracks or fewer;
- an album and playlist sharing at least one identical source-scoped track;
- favorites with at least one Plex item and, when configured, one non-downloadable provider item;
- the smallest enabled Plex library for the library-target run.

Record title, rating key, source composite key, duration, and expected membership for each fixture. If no safe fixture exists, record the blocker rather than modifying Plex.

## Ordered Journey

Run in this order so each phase creates state used by the next.

### 1. Typical User Journey

1. From a normal browse surface, find the small album as a user would.
2. Choose `Download`, confirm immediate row/menu feedback, and navigate through More > Downloads.
3. Verify the Items row, target detail, per-track statuses, aggregate count/bytes, pause/resume control, and progress update without refresh or relaunch.
4. Leave Downloads, return, and verify the same state remains current.
5. Let the album finish, enable Airplane Mode, play two downloaded tracks including a track boundary, and verify artwork, metadata, queue, and Now Playing remain correct.
6. Return online, remove the album download, and verify the local target disappears without any Plex item disappearing.

### 2. Target And Reference-Counting Matrix

Exercise track, album, artist, playlist, and favorites targets through their normal context menus and through Downloads detail where applicable.

For the overlapping album and playlist:
1. Download both and verify the shared track has one local file represented by both targets.
2. Remove one target and prove the shared track remains downloaded and playable.
3. Remove the final target and prove the audio file plus frequency, lyrics, and chord sidecars are evicted.

For merged/cross-provider favorites or playlists, verify unsupported provider members remain visible online but never create Ensemble download memberships or queue rows.

### 3. Quality Matrix

Use the same known-good track for repeatable comparison:

1. Set Original, download, verify displayed/stored quality, duration validation, size, and offline playback.
2. Change to High, use `Redownload at Current Quality`, and verify old-quality playback remains available until replacement succeeds.
3. Repeat for Medium and Low.
4. Change quality while a transfer is active; verify old work cancels, the item returns to pending at the new quality, and no stale `.downloading` record remains.
5. Verify Manage Downloads and Profile > Audio Quality show the same current quality and cellular preference.
6. Restore the baseline quality after evidence capture.

### 4. Playback Concurrency

1. Start audible streaming playback and record stable system progress.
2. Start the small album or playlist download while playback continues.
3. Navigate Feed, Downloads, target detail, Now Playing, Queue, and back while progress updates.
4. Verify no skip, pause, audio glitch, queue replacement, artwork regression, or repeated UI publication occurs.
5. Play an already-downloaded track while other downloads remain active.
6. Verify online source selection follows quality policy and Airplane Mode falls back to the local file.

### 5. Background, Lock, And Relaunch

Use a target long enough to remain active through the transition:

1. Start downloads, press Home in Device Hub, lock the phone before completion, and wait through a meaningful transfer interval.
2. Verify Lock Screen/Dynamic Island activity is current rather than stale.
3. Unlock and foreground Ensemble. Confirm completed work or policy-compliant resumable pending work; background execution is best-effort, so lack of uninterrupted transfer alone is not a failure.
4. Repeat while playback is active and confirm audio/system Now Playing continuity.
5. Terminate Ensemble during an active transfer, relaunch the exact installed build, and verify launch recovery repairs stale state without duplicate records or files.
6. Background during recovery, foreground again, and verify the deferred recovery runs once and the queue winds down cleanly.

### 6. Network And Scheduler Policy

1. On Wi-Fi, verify normal queue start and pause/resume.
2. Enable Low Data Mode, verify the explanatory paused state, exercise `Resume Downloads for One Hour`, and confirm the persistent setting is unchanged.
3. Go fully offline, verify pending state is retained, downloaded playback works, and unavailable remote tracks explain why they cannot play.
4. Restore Wi-Fi and verify automatic recovery without duplicate enqueueing.
5. Verify the cellular preference is synchronized between both settings surfaces. Do not transfer over cellular without separate current approval.
6. Exercise user pause during target reconciliation and ensure Resume stays visible while resumable work exists.

### 7. Failure And Retry

Use naturally occurring server failures; do not corrupt Plex content.

1. Verify a failed row has an actionable reason and retry control.
2. Retry one track and `Retry All Failed`; verify only failed work is requeued.
3. Confirm truncated or invalid payloads are rejected before completion and partial files are not playable.
4. Confirm direct-original fallback is attempted only when policy permits and repeated unsupported transcodes do not loop indefinitely.
5. After failure, verify pending count reaches zero, queue controls settle, background activity ends, and relaunch does not resurrect completed failure handling.

### 8. Library Target And Soak

1. Enable the smallest library and verify target shell publication, estimated size, membership count, and immediate UI responsiveness.
2. Pause, resume, background, lock, relaunch, and disable while partially downloaded; verify bounded cleanup and responsive progress publication.
3. If free storage exceeds the estimate plus a 25% safety margin, re-enable and allow the library to complete. Verify count, bytes, random offline playback from the beginning/middle/end, and no duplicate memberships.
4. If the safety margin is unavailable, record full-library completion as blocked; do not fill the phone to manufacture a low-storage test.
5. Disable the library and verify cleanup preserves files still referenced by another target.

### 9. Destructive Local Cleanup

After scoped removal passes, exercise `Remove All Downloads` as the final destructive case:

1. Capture the confirmation copy, execute `Remove All`, and wait for cleanup completion.
2. Verify targets, queued rows, audio files, and offline sidecars are removed; library toggles are off and Downloads shows its true empty state.
3. Verify Plex browse/search still contains the same remote tracks, albums, artists, playlists, favorites, and libraries sampled at baseline.
4. Do not restore removed pre-existing downloads unless the active sweep request asks for restoration; report exactly what local state was removed.

## Continuous UI And Performance Checks

At every phase capture the changed surface itself, not only the Downloads root:

- action label changes between Download and Remove Download;
- target and library row counts, bytes, quality, status, and failure text;
- per-track Queued, Downloading, Downloaded, Failed, and paused states;
- pause/resume and one-hour override affordances;
- toast wording, confirmation dialogs, swipe actions, VoiceOver labels/hints, mini-player clearance, and final-row reachability;
- Dynamic Island and Lock Screen activity start, progress, completion/failure, and dismissal;
- state propagation across browse rows, context menus, Downloads, detail views, mini-player, Now Playing, and offline relaunch.

Capture three separate Instruments Time Profiler/Hangs traces against the exact current PID:

1. download-only foreground activity;
2. playback plus concurrent downloads and navigation;
3. background/lock transition and subsequent foreground recovery.

Align trace timestamps with app logs. Investigate every hang-risk event and every potential hang over 250 ms. Record thermal state, CPU behavior, time to first visible progress, queue wind-down, and whether CPU/log activity returns to idle. Treat trace compatibility warnings separately from app findings and compare critical timing once without profiler overhead.

## Evidence And Pass Gates

Save one row per scenario with starting state, Device Hub steps, expected/actual state, screenshots, accessibility/UI evidence, log excerpt, trace path, cleanup result, and policy status.

The sweep passes only when:
- the installed/running artifact is proven fresh;
- every applicable target kind and quality completes or has a precise external blocker;
- offline files play and invalid files do not;
- overlapping targets preserve and evict shared files correctly;
- lifecycle and network transitions leave no stuck or duplicate work;
- playback remains coherent during transfer activity;
- UI state converges without manual refresh and system activity ends when work ends;
- local removal never mutates Plex content;
- Instruments shows no unexplained app-owned hang, sustained post-queue work, or playback starvation;
- the temporary UI runner is removed, settings are restored, playback is paused, and the phone is locked with lock state verified independently.

If Device Hub shows fresh frames but ignores input, restart it before classifying an app failure. Use one narrow physical XCUITest only when a semantic control cannot be operated reliably; remove temporary test code and the runner afterward.
