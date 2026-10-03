# Code cleanup follow-up

Approved follow-up to the code audit, after the download and mood-cache safety fixes.

## Removed and consolidated

- Removed both `saveQueueSnapshot` forwarding methods after a repository-wide search found no callers. Queue-to-playlist actions continue through the existing add-tracks workflow.
- Playlist pins now use the same `mergePins` implementation as album and artist pins, with the canonical `PlexPlaylistMergeRules` identity. First-occurrence placement, smart/regular separation, preferred source order, and paired pin metadata remain intact.
- Seven browse sort menus now share `EnsembleBrowseSortMenu`: Songs, Albums, Artists, Playlists, Favorites, Genre albums, and Artist albums. The native menu keeps each context's options, accessibility labels, option defaults, and active-option direction toggle. Artist albums omit Album Artist; global Albums and Genre albums retain it.
- The small sort-menu view observes its owning view model. It reads current state when an action executes and updates the direction indicator even when sorting leaves the visible collection unchanged. The large browse screens continue to consume their existing committed snapshots.
- Playlist list/detail feedback now uses one private typed notification channel instead of six names, string dictionaries, and six conversion publishers. Pending rename/delete toasts are dismissed by the mutation task's `defer`, rather than by a list subscriber or duplicated success/failure cleanup blocks.

## Verification

- Existing focused Core checks passed before and after the Core refactor: 28 XCTest tests and one Swift Testing test, covering pin reordering, playlist grouping, normalized browse sorting, and playlist workflow feedback.
- Another 14 existing playlist view-model checks passed, including source-scoped optimistic rename, stale-cache deletion, creation/materialization, last-good snapshots, and source authority. There are 43 distinct passing focused tests; repeated workflow runs are not counted again.
- A temporary probe executed the production private event enum and publisher on macOS. All six cases delivered with their exact source identities and rename titles.
- Workspace app builds passed for iPhone Simulator, iPad Simulator, and macOS. No new compiler warnings were introduced in the changed files.
- Fresh iOS 26.5 installs were verified by matching the built and installed executable/debug-library hashes, running process paths, build versions, and hashes of the changed Swift sources.
- iPhone 17 Pro simulator: `C01A1C06-F40B-4B39-93A7-7D1D9C89D9A1`. Repeated Year descending/ascending/descending toggles passed on an unchanged one-album result; screenshots verified the direction indicator. Albums and Favorites menus rendered. Playlist rename/delete prompts canceled with the title and track count preserved. Playback remained paused, and the dedicated phone simulator was shut down afterward. Hardware lock commands reported success without changing the visible screen, so they were not accepted as lock-state evidence.
- iPad A16 simulator: `08CA3DD8-D174-40E9-A361-62B95671B969`. All seven sort-menu contexts rendered with the expected choices. Default directions and active toggles were checked through UI interactions and persisted sort state. The slow Favorites accessibility tree triggered a runner watchdog; the runner recovered through its native accessibility fallback, and the actual menu was then inspected.
- Full evidence, build logs, snapshots, screenshots, source/hash provenance, and the temporary event probe are in `/tmp/ensemble-cleanup-runtime.jTso4Q`.

## Kept and deferred

Active native table, toast-window, root-chrome, and older-OS adapters remain in place. No changes were made to audio engines, PCM locking, playback transport, source ownership, or persisted media.

Batch playlist creation still combines optimistic view-model state with aggregate feedback. Moving that orchestration requires preserving placeholder materialization and partial-source results; this pass only consolidates the list/detail rename/delete event wiring and pending-toast lifetime.

Dependency-container orchestration, remaining singleton access, and playback state ownership remain candidates for subsequent focused architecture work. Audio/performance changes still require measurements.

Live provider rename/delete success, failure, and offline replay were not exercised through the UI. Their existing workflow/view-model coverage passed, but that is not remote convergence proof. macOS was built rather than visually tested; older supported OS versions and physical devices were not exercised in this pass.
