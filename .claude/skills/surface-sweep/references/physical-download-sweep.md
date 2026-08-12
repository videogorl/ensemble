# Physical iPhone Download Sweep

Use this runbook for an end-to-end download sweep on the user's physical iPhone 16 Pro. Drive visible UI through Device Hub, use `devicectl` for provenance and device facts, and attach Instruments to the exact Ensemble PID.

## Authorization Boundary

The user authorized adding and removing device-local downloads, download targets, queued work, and their local sidecars on this phone. The user also authorized rapid enable/disable cycles for configured library sources and destructive mutation of playlists created by this sweep.

Never use this authorization to:
- delete a track, album, collection, library, or other Plex library item;
- edit or delete a pre-existing playlist or its membership;
- edit Plex metadata;
- remove a Plex account, server, or configured library source;
- clear all synced library data or reset the app;
- incur cellular data charges without separate current approval.

For local-download operations, confirm the selected action says `Download`, `Remove Download`, `Remove Downloads`, or `Remove All Downloads`. Never select adjacent `Delete Track` or `Delete Album` actions; select `Delete Playlist` only after proving the exact playlist identity belongs to the current sweep.

Name every disposable playlist `Ensemble Download Sweep <run-id> <suffix>` and record its provider-returned identity immediately. Rename, reorder, add/remove tracks, or delete a playlist only when that exact identity was created during the current sweep. A title match alone is insufficient authorization.

## Definition Of Complete

Do not call the download system fully swept until every applicable row below passes or is recorded as blocked with an exact reason:

| Area | Required proof |
|---|---|
| Track | Add, complete, play offline, remove, and confirm local eviction. |
| Album | Complete a small album target and verify detail counts, progress, playable rows, and removal. |
| Artist | Complete or deliberately bound a small artist target; verify membership and cleanup. |
| Playlist | Complete a small existing playlist without mutating the Plex playlist. |
| Sweep-owned playlist | Create, mutate, download, reconcile, and delete a uniquely identified disposable Plex playlist. |
| Favorites | Reconcile a favorites target and verify only downloadable provider members are queued. |
| Overlap | Put one source-scoped track in two targets; removing the first target preserves the file, removing the final target evicts it and its sidecars. |
| Library | Exercise enable, queue creation, pause/resume, backgrounding, completion or a documented capacity blocker, disable, and bounded cleanup. |
| Source-library reconciliation | Rapidly enable/disable a configured library at the earliest UI-permitted boundary; verify scoped cleanup, restoration, and no duplicate or stale state. |
| Quality | Exercise Original, High (320 kbps), Medium (192 kbps), and Low (128 kbps), including redownload at current quality. |
| Playback | Download during active streaming, play a downloaded item while the queue runs, and prove offline playback. |
| Lifecycle | Foreground, background, lock, foreground recovery, terminate/relaunch recovery, and stale `.downloading` repair. |
| Network | Wi-Fi, offline, Low Data Mode, and cellular-policy UI; transfer on cellular only with separate approval. |
| Failure | Failed row, retry, invalid/truncated payload rejection, direct-original fallback where applicable, and queue wind-down. |
| Removal | Per-track/target removal and the authorized `Remove All Downloads` flow, with no remote Plex mutation. |
| UI/UX | Cross-surface state freshness, counts, progress, errors, retry controls, queue controls, toasts, Dynamic Island/Lock Screen activity, accessibility, and empty state. |
| Performance | Download-only, playback-plus-download, and lifecycle traces with logs aligned to trace timestamps. |
| Plex mutation convergence | Only with separate explicit authorization: foreground and cold-start add/edit/remove, downloaded-playlist add/remove/re-add/delete, timer lifecycle, failure safety, bounded indexing, no-op polling cost, and full disposable-fixture cleanup. |

## Preflight And Baseline

1. Start from a clean worktree and record the source commit.
2. Discover the current physical device instead of hard-coding its identifier. Confirm it is Felicity's iPhone 16 Pro and record its current iOS version.
3. Build `Ensemble.xcworkspace` into a fresh DerivedData directory, install it, relaunch with `--terminate-existing`, and prove the installed build number and running executable path.
4. Check device lock state before installation. Use the passcode from `.env` only through Device Hub when needed; never print or persist it in artifacts.
5. Create an artifact root such as `/tmp/ensemble-download-sweep-<run-id>` with `screenshots`, `ui`, `logs`, `traces`, and `reports` subdirectories.
6. Capture a baseline before changing downloads:
   - every download-library toggle and every configured source-library enabled flag, with account/server/library labels kept distinct;
   - every existing target, status, downloaded/total count, and estimated/on-disk size;
   - pre-existing playlist identities and the current server playlist count needed to prove they were not mutated;
   - active queue reason, quality, cellular setting, Low Data Mode, network path, free device storage, and active playback state;
   - installed build number, PID, app log session, and visible Dynamic Island/Lock Screen activity;
   - existing failures and the names/IDs of test fixtures chosen below.
7. Use only existing Plex media as track/album/artist fixtures. The only remote Plex objects this sweep may create, edit, or delete are its uniquely identified disposable playlists.

## Fixture Selection

Choose the smallest existing fixtures that cover behavior while keeping the sweep fast:

- one known-good two-to-five-minute Plex track;
- one small album, preferably 12 tracks or fewer;
- one small artist, preferably 25 tracks or fewer;
- one small existing playlist, preferably 20 tracks or fewer;
- one disposable Plex playlist created by the sweep from three to six existing tracks;
- an album and playlist sharing at least one identical source-scoped track;
- favorites with at least one Plex item and, when configured, one non-downloadable provider item;
- the smallest enabled Plex library for the library-target run.

Record title, rating key, source composite key, duration, and expected membership for each fixture. If no safe fixture exists, record the blocker rather than modifying Plex.

## Optional Plex Mutation-Convergence Extension

Run this extension only when the user explicitly authorizes live Plex fixture mutation. The default download-sweep authorization is insufficient. Use a uniquely named disposable two-track artist/album plus a sweep-owned playlist on the local Plex server. Create media from copies, record every path and Plex identity, and never edit or delete pre-existing media, metadata, or playlists.

Use the exact freshly installed Ensemble build for both lifecycle modes:

1. Baseline Plex responses, Ensemble source-scoped database rows, target memberships/counts, local audio and `.freq` files, lyrics/chord/artifact-state caches, narrow sync/download logs, and visible browse/detail/search/playlist UI.
2. Foreground library convergence:
   - scan in the disposable artist, album, and two tracks and verify one row per identity;
   - edit a track title and verify every cached/rendered occurrence updates without a relaunch;
   - edit the album title and verify the album plus denormalized child-track album names update;
   - retain an unaffected track throughout so source scoping and selective cleanup are observable.
3. Cold-start convergence: terminate Ensemble, make representative add/edit/removal changes, relaunch the exact installed build, and verify startup health plus authoritative reconciliation reaches Plex state without manual refresh. Cached rows must remain visible while reconciliation runs, and foreground periodic timers must start before idle-budgeted startup sync or indexing finishes.
4. Downloaded-playlist convergence:
   - create a sweep-owned playlist containing track one, enable its Ensemble download target, and wait for audio, frequency, lyrics, and chords to complete;
   - add track two through Plex while Ensemble remains foreground; within one 60-second target poll plus transfer time, verify membership, counts, download row, and all artifacts;
   - remove track two from the Plex playlist without removing it from the library; verify the next poll removes its membership and, when no other target references it, all offline artifacts;
   - re-add track two and verify it downloads again without relaunch, manual refresh, duplicate membership, or duplicate completion.
5. Authoritative removal: while the downloaded target exists, remove only track two from the disposable Plex library and scan. Verify Ensemble deletes its track/download/membership rows plus audio, frequency, lyric, chord, and artifact-state files while track one and its files remain.
6. Whole-playlist removal: terminate Ensemble, delete the exact sweep-owned Plex playlist, and relaunch. Verify authoritative startup reconciliation removes the playlist, target, memberships, download rows, and final-reference artifacts while retaining track one in the library. If playlist deletion is the changed behavior, repeat once with Ensemble foreground to cover the target poll.
7. Failure, lifecycle, and efficiency evidence:
   - use automated stubs—not a destabilized live server—to prove failed, malformed, partial, premature-empty, or inconsistent inventory preserves last-good data;
   - observe an unchanged foreground target poll and prove it contacts only distinct servers with downloaded Plex playlist targets, performs no full library inventory, artwork recache, or target reconciliation, and remains active when WebSocket health relaxes ordinary library polling;
   - background and foreground Ensemble, prove periodic timers stop and restart, then make a Plex change and verify the next poll converges even when startup/indexing work is still idle-deferred;
   - on a no-op cold start, prove the shared Siri index is not rewritten, Spotlight skips an unchanged update, and duplicate vocabulary registration is skipped within the launch. After a material change, compare the expected source-scoped database delta with the Spotlight updated/deleted count rather than accepting a full-corpus rebuild. A once-daily full republish is valid; repeat afterward to exercise the no-op path;
   - record mutation time, detection time, completion time, request counts, CPU/thermal state, and when work returns to idle.
8. Cleanup in dependency order: remove any remaining Ensemble download target through UI, verify its local rows/files are gone, delete the exact sweep-owned playlist if it still exists, move/delete only the disposable media, rescan Plex, and verify every recorded Plex and Ensemble fixture identity is absent. Preserve a recoverable media copy until these checks pass, then restore filters/navigation and baseline settings.

For background download lifecycle evidence, correlate track ID, queue item ID, requested quality, completion rows, and files across expiration/recovery. Require exactly one durable completion per track and unchanged requested quality; `remainingPending=0` alone does not pass. For a missing lyric stream, require one request per unchanged signature and no retry storm. Inspect exported diagnostics for token and Plex filesystem-path redaction, and record thermal state before, during, and after the run.

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

### 3. Disposable Playlist Lifecycle

1. Create `Ensemble Download Sweep <run-id> A` on a Plex source that supports playlist deletion. Record its returned playlist ID and source key before mutation.
2. Add three to six existing tracks, including the overlap fixture; verify optimistic UI, server convergence, ordering, duplicate prevention, and refresh without touching any pre-existing playlist.
3. Rename, reorder, remove, and re-add tracks in this sweep-owned playlist. Exercise an offline-queued mutation and reconnect if the provider supports it.
4. Download the playlist and verify membership, counts, order, target detail, shared-file reference counting, and offline playback.
5. Delete the sweep-owned playlist while its download target exists. Verify authoritative reconciliation removes the playlist, target, memberships, download rows, and final-reference artifacts while preserving shared files and library tracks. A stale local target is a failure.
6. Confirm the exact playlist ID is absent from Plex after deletion and every baseline playlist remains present and unchanged.
7. Do not create an Apple Music playlist for cleanup testing because MusicKit exposes no supported delete operation; use an existing Apple playlist read-only when provider comparison is useful.

### 4. Quality Matrix

Use the same known-good track for repeatable comparison:

1. Set Original, download, verify displayed/stored quality, duration validation, size, and offline playback.
2. Change to High, use `Redownload at Current Quality`, and verify old-quality playback remains available until replacement succeeds.
3. Repeat for Medium and Low.
4. Change quality while a transfer is active; verify old work cancels, the item returns to pending at the new quality, and no stale `.downloading` record remains.
5. Verify Manage Downloads and Profile > Audio Quality show the same current quality and cellular preference.
6. Restore the baseline quality after evidence capture.

### 5. Playback Concurrency

1. Start audible streaming playback and record stable system progress.
2. Start the small album or playlist download while playback continues.
3. Navigate Feed, Downloads, target detail, Now Playing, Queue, and back while progress updates.
4. Verify no skip, pause, audio glitch, queue replacement, artwork regression, or repeated UI publication occurs.
5. Play an already-downloaded track while other downloads remain active.
6. Verify online source selection follows quality policy and Airplane Mode falls back to the local file.

### 6. Background, Lock, And Relaunch

Use a target long enough to remain active through the transition:

1. Start downloads, press Home in Device Hub, lock the phone before completion, and wait through a meaningful transfer interval.
2. Verify Lock Screen/Dynamic Island activity is current rather than stale.
3. Unlock and foreground Ensemble. Confirm completed work or policy-compliant resumable pending work; background execution is best-effort, so lack of uninterrupted transfer alone is not a failure.
4. Repeat while playback is active and confirm audio/system Now Playing continuity.
5. Terminate Ensemble during an active transfer, relaunch the exact installed build, and verify launch recovery repairs stale state without duplicate records or files.
6. Background during recovery, foreground again, and verify the deferred recovery runs once and the queue winds down cleanly.

### 7. Network And Scheduler Policy

1. On Wi-Fi, verify normal queue start and pause/resume.
2. Enable Low Data Mode, verify the explanatory paused state, exercise `Resume Downloads for One Hour`, and confirm the persistent setting is unchanged.
3. Go fully offline, verify pending state is retained, downloaded playback works, and unavailable remote tracks explain why they cannot play.
4. Restore Wi-Fi and verify automatic recovery without duplicate enqueueing.
5. Verify the cellular preference is synchronized between both settings surfaces. Do not transfer over cellular without separate current approval.
6. Exercise user pause during target reconciliation and ensure Resume stays visible while resumable work exists.

### 8. Failure And Retry

Use naturally occurring server failures; do not corrupt Plex content.

1. Verify a failed row has an actionable reason and retry control.
2. Retry one track and `Retry All Failed`; verify only failed work is requeued.
3. Confirm truncated or invalid payloads are rejected before completion and partial files are not playable.
4. Confirm direct-original fallback is attempted only when policy permits and repeated unsupported transcodes do not loop indefinitely.
5. After failure, verify pending count reaches zero, queue controls settle, background activity ends, and relaunch does not resurrect completed failure handling.

### 9. Library Target And Soak

1. Enable the smallest library and verify target shell publication, estimated size, membership count, and immediate UI responsiveness.
2. Pause, resume, background, lock, relaunch, and disable while partially downloaded; verify bounded cleanup and responsive progress publication.
3. If free storage exceeds the estimate plus a 25% safety margin, re-enable and allow the library to complete. Verify count, bytes, random offline playback from the beginning/middle/end, and no duplicate memberships.
4. If the safety margin is unavailable, record full-library completion as blocked; do not fill the phone to manufacture a low-storage test.
5. Disable the library and verify cleanup preserves files still referenced by another target.

### 10. Rapid Source-Library Reconciliation

This tests Profile > Music Sources library enablement, not the download-library toggle in Downloads.

1. Choose a Plex library with another enabled library still available when possible. Record its source composite key, synced row counts, Feed hubs, playlists, download targets/files, artwork, pending mutations, and the unaffected-source baseline.
2. If needed, create and download a uniquely identified sweep-owned playlist on that server so playlist/download reconciliation is observable without risking existing playlists.
3. Disable the source library through Device Hub. As soon as the UI operation finishes and the control becomes available, re-enable it; never bypass the in-flight guard with direct persistence or API edits.
4. Repeat three UI-permitted disable/enable cycles. In separate cycles, background once and terminate/relaunch once while sync or cleanup is settling.
5. On each disable, verify source-scoped library rows, Feed items, artwork, offline targets/files, and pending mutations are purged only for that source. Unrelated sources and their downloads must remain usable.
6. On each re-enable, verify one provider registration and one authoritative sync restore the expected content without duplicate rows, memberships, artwork records, targets, or concurrent sync storms. Older cleanup/sync generations must not overwrite the newest enabled state.
7. Verify Songs, Albums, Artists, Favorites, Search, Feed, Playlists, Downloads, Siri/App Intent index state where observable, and source-detail counts converge without an unrelated navigation workaround.
8. If multiple libraries share the server, test both boundaries: disable a non-final library and verify server playlists remain; then disable the final enabled library once and verify server-scoped local playlist cleanup. Re-enable the baseline libraries and verify Plex playlists resync from the server.
9. Record `AccountManager: library selection changed`, `[SourceReconciliation]`, cleanup completion, provider refresh, sync start/finish, target reconciliation, and duplicate-count evidence. Capture an Instruments trace spanning the fastest complete cycle.
10. Confirm no Plex track, album, collection, library, or pre-existing playlist changed remotely. Restore every source enabled flag to its baseline and wait for local and synced preference convergence before continuing.

### 11. Destructive Local Cleanup

After scoped removal passes, exercise `Remove All Downloads` as the final destructive case:

1. Capture the confirmation copy, execute `Remove All`, and wait for cleanup completion.
2. Verify targets, queued rows, audio files, and offline sidecars are removed; library toggles are off and Downloads shows its true empty state.
3. Verify Plex browse/search still contains the same remote tracks, albums, artists, playlists, favorites, and libraries sampled at baseline.
4. Delete any remaining sweep-owned playlist by its recorded provider identity and verify all pre-existing playlists remain unchanged.
5. Do not restore removed pre-existing downloads unless the active sweep request asks for restoration; report exactly what local state was removed.

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
- background/foreground transitions stop and restart periodic sync, and a no-op cold start avoids shared-index writes, Spotlight updates, and duplicate vocabulary work;
- rapid source-library cycles converge to the last user-selected state without cross-source cleanup or duplicate content;
- playback remains coherent during transfer activity;
- UI state converges without manual refresh and system activity ends when work ends;
- local removal never mutates Plex content, and only exact sweep-owned playlists are changed or deleted remotely;
- every sweep-owned playlist is accounted for and deleted when its provider supports deletion;
- Instruments shows no unexplained app-owned hang, sustained post-queue work, or playback starvation;
- the temporary UI runner is removed, settings are restored, playback is paused, and the phone is locked with lock state verified independently.

If Device Hub shows fresh frames but ignores input, restart it before classifying an app failure. Use one narrow physical XCUITest only when a semantic control cannot be operated reliably; remove temporary test code and the runner afterward.
