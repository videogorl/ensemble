# Step 6d: one track-list host, one row model, the queue on it

Date: 2026-11-10 (work on 2026-11-09). Baseline and rollback point: `e51fed2e`
(`develop` with 6a–6c). Design:
[`browse-detail-panes-design.md`](../reference/browse-detail-panes-design.md)
section 2.5. Parts 2 (the shared row model) and 3 (the queue on it) are in
their own sections below. Part 1 evidence is under `$TMPDIR/step6d-1/` on
the test Mac (temporary).

## What changed

- `SongsTrackListHost` is now `TrackListHost`. Every caller passes tracks or
  sections plus one `NativeTrackListConfiguration`. The host picks UIKit
  `MediaTrackList` or AppKit `MacNativeTrackTableView`, and owns disc
  grouping and the section index. No call site has an `#if os(iOS)` table
  fork any more.
- Both tables take the configuration instead of spread fields.
  `MediaTrackList` has one internal initializer (it had two public ones, one
  with 41 parameters) and lost its unused per-action closures
  (`onPlayNext` … `recentPlaylistTitle`, all superseded by
  `TrackRowInteractionModel`) and its native section index, which no caller
  turned on.
- Configuration: added `managesOwnScrolling` (iOS tables embedded in a parent
  `ScrollView`, used by Search and artist favourites). Removed
  `topContentInset` and `tableHeaderExtraHeight` (no caller set them), the
  `.songs` preset (it equalled the defaults) and the host's two convenience
  initializers. `tableHeaderRevision` moved to the host beside the header
  content.
- Disc grouping moved from `MediaTrackList` (iOS) and a Mac-only helper in
  `MediaDetailView` to `NativeTrackListSection.discSections(for:)`, used by
  the host on both platforms.

Behaviour kept on purpose:

- iOS shows section headers only with the section index; without it the
  sections are flattened into one list (as the old flat path did on iPad
  and narrow widths).
- The host adds `.ignoresSafeArea(.container, edges: [.top, .bottom])` on iOS
  only for self-scrolling tables. Detail already bled under both edges
  through `DetailScreen`; Mood applied the same modifier itself; Stage Flow's
  parent ignores the whole safe area, so the modifier is a no-op there
  (hypothesis, not checked in landscape).
- One-section updates keep the caller's array storage, so the UIKit table's
  shared-storage shortcut still skips the per-track comparison. Favorites now
  gets that shortcut too (it went through the host's flattening before).

One deliberate alignment: Mac playlist removal used the first matching
track's index (`firstIndex` by identity); it now passes the clicked row's
index, as iOS always did. They differ only when a playlist holds the same
track twice.

## Call-site inventory (before)

| Caller | iOS | Mac | Configuration fields used |
| --- | --- | --- | --- |
| Songs, 4 calls | host convenience init | same | currentTrackId, contentRevision, availability, downloads, bottomContentInset, supplementalMetadataWidth, showsSectionIndex, usesDynamicTableHeaderHeight, interactionModel; header, footer, refresh |
| Favorites | host + `.songs` | same | currentTrackId, availability, downloads, bottomContentInset, supplementalMetadataWidth, interactionModel; header, footer |
| Mood | `MediaTrackList(tracks:)` | host + `.songs` | as Favorites |
| Album / playlist / merged detail | `MediaTrackList(tracks:)`, groupByDisc, header revision | host with Mac-built disc sections | showArtwork, showTrackNumbers, showAlbumName, groupByDisc, bottomContentInset, supplementalMetadataWidth, trackSourceLabels, currentTrackId, selectedTrackId, availability, downloads, interactionModel; header, header revision, footer, playlist removal |
| Artist favourited tracks | `MediaTrackList`, embedded | host + `.songs` | supplementalMetadataWidth, currentTrackId, availability, downloads, interactionModel; embedded |
| Search songs | `MediaTrackList`, embedded | host convenience init | currentTrackId, availability, downloads, interactionModel; embedded |
| Stage Flow panel | `MediaTrackList`, rowHeight 58 | host | showTrackNumbers, showAlbumName, rowHeight, bottomContentInset, currentTrackId, availability, downloads, interactionModel |

After: every row above calls `TrackListHost(tracks:|sections:, configuration:)`.

## Line counts (track-list files)

| File | Before | After |
| --- | ---: | ---: |
| `MediaTrackList.swift` | 1,689 | 1,371 |
| `SongsTrackListHost.swift` → `TrackListHost.swift` | 292 | 153 |
| `NativeTrackListConfiguration.swift` | 100 | 68 |
| `NativeTrackListSections.swift` | 67 | 91 |
| `AppKit/MacNativeTrackTableView.swift` | 1,097 | 1,076 |

Whole branch: 14 files under `Packages/`, 461 insertions, 1,084 deletions (track-list files: 3,245 → 2,759 lines).

## Results

Commits `0c6b8e62`…`ea5b1f2c` (migration) and `b6d82488` (simplify pass).
Simulator runs used `b6d82488` plus the temporary UI test only
(`EnsembleLaunchUITests.with-step6d-temp.swift` in the evidence folder;
reverted, not committed).

Build identity:

- iPhone 17 Pro Max `B07151D0-…` and iPad Pro 11-inch (M5) `6511F397-…`,
  iOS 27: Debug build in `dd-ios`; installed `Ensemble.debug.dylib` SHA-256
  `9bcd19167e00b8a7…` equals the built one on both (`identity.txt`). Tests ran
  with `-parallel-testing-enabled NO`, so on the exact UUIDs, not clones. An
  earlier run without that flag ran on an Xcode clone and is not counted.
- Mac: Debug `0.4.0 (202611091741.5129)` from `dd-mac` at `ea5b1f2c`,
  launched with `open -n <explicit .app>`; PID 17024's executable path (`ps`,
  `lsof`) is that bundle's `MacOS/Ensemble`.

| Check | iPhone | iPad | Evidence |
| --- | --- | --- | --- |
| Songs: rows, fast scroll, 15,398-track library | PASS | PASS | `iphone3/uitest.log`, `ipad/uitest.log` |
| Songs scroll index (tap S lands on S rows and header) | PASS | n/a (iPhone only by design) | `iphone3/uitest.log` |
| Album detail "Seconds Out": track numbers, Disc 1 and Disc 2 headers | PASS | PASS | `shots/*album-*` |
| Playlist detail "The Greatest": rows with artwork | PASS | PASS | `iphone4/shots/iphone-playlist-rows.png` |
| Artist "Au4" favourited tracks (embedded table) | PASS | PASS (rerun with rows scrolled clear of the mini player) | `iphone3`, `ipad2` |
| Mood "Acerbic", Search songs "Au4", Favorites | PASS | PASS | `iphone3`, `ipad` |
| Each surface: long-press context menu opens; tapping Play Next dismisses it (queue effect not checked) | PASS | PASS | logs, `*-context-menu.png` |
| Each surface: trailing swipe reveals Favorite and Add to Playlist; Add to Playlist opens its sheet (cancelled) | PASS | PASS | logs, `*-swipe*.png` |
| Each surface: tap plays (mini player shows Pause); the row's duration gives way to the play-state indicator | PASS | PASS | logs, `*-playing.png` |
| `PhoneBrowseAcceptanceUITests` | PASS 5/5 | n/a | `iphone3/run.log` |
| Mac Songs: rows, double-click plays, speaker indicator, context menu | PASS | | `mac/songs-playing.jpg`, `mac/songs-context-menu.jpg` |
| Mac album detail (via Go to Album): track numbers, Disc 2 header from the host's grouping, double-click plays, context menu | PASS | | `mac/album-detail.jpg`, `mac/album-playing-menu.jpg` |
| Mac re-check on `b6d82488` | PARTIAL | | launched (PID proven) but opened no window and would not take focus after two attempts; main thread idle. Cause unknown; the simplify commit only moved a flattening helper (hypothesis: unrelated launch state after the earlier instance was terminated) |
| iOS and macOS builds | PASS | | `build-*.log` |
| EnsembleUI package tests | PASS 124/124 (twice) | | `test-ui*.log` |
| EnsembleCore package tests | PASS 1172/1172 at the end | | `test-core-2.log` |

`PlexWebSocketCoordinatorTests.testDownloadCompletionEventsAreDebounced`
failed once in the first full EnsembleCore run and passed 3/3 alone and in
the final full run. EnsembleCore is untouched; hypothesis: its 3.1 s sleep
against a 3 s debounce is tight under load.

Fixture note: smart playlist "❤️ Tracks" and "Lyrics" hold tracks marked
"Library not synced" in this simulator. Their rows correctly offer only
Remove from Playlist and no swipe actions, so the playlist check used "The
Greatest".

## Not run

- Physical iPhone, iPad and Mac acceptance: listed in
  [`physical-device-backlog.md`](../reference/physical-device-backlog.md).
- Leading swipe (Play Next, Play Last) on iOS; Mac trackpad row actions,
  drag-out on either platform, Mac Search, Favorites, Mood, artist and
  playlist tables; Mac re-check on `b6d82488` (see above).
- Stage Flow's track panel (landscape) and pull to refresh on Songs.
- Playlist removal from a playlist row (destructive; not exercised).
- Scroll restoration on back navigation beyond what
  `PhoneBrowseAcceptanceUITests` covers.

## Part 2: one row model for both tables

Work on 2026-11-09, branch `refactor/share-track-row-model` from `a5c23da7`. Evidence is under
`$TMPDIR/step6d-2/` on the test Mac (temporary).

### What changed

1. **Row content** (`461dbf1e`). New `TrackRowContent` holds what a row
   shows: title, track number (empty while playing), subtitle, the artist and
   album column texts and widths, duration or play indicator, dimmed state,
   download state (none, downloading, downloaded) and favourite.
   `TrackTableViewCell` and the AppKit cell render it with their own views.
   Both coordinators keep the one `NativeTrackListConfiguration` instead of
   10–13 copied fields.
2. **Row bookkeeping and change detection** (`d7c4388a`). `TrackListRows`
   replaces `MediaTrackGroup`, the UIKit section and global-index arithmetic,
   and `NativeTrackListFlattening`. The AppKit flat rows store positions, not
   track copies, so a redraw reads fresh tracks without rebuilding the list.
   `TrackListChange.between(old, new)` returns reload, redraw visible rows,
   or nothing for both tables, with one table-driven test.
   `compareTrackListState`, `trackIdentityOrderMatches`, the favourite-state
   scan and the two old comparison tests are gone.
3. **Artwork** (`b7f7eee6`). `TrackCellArtwork` (in
   `TrackArtworkThumbnailLoader.swift`) loads a cell's thumbnail with
   `QueueItemCell`'s generation-token pattern: a cached image at once,
   otherwise an async load that a newer generation drops. Redrawing the track
   already shown requests nothing.
4. **Metrics** (`770b894d`). `TrackListLayoutMetrics.metadataColumnWidths(for:)`
   replaces four show/width functions and the cells' private wrappers. The
   dimmed alpha (0.45) and the Mac section row height (40) moved there too.
5. **Decision log** (`db15d5b9`). One debug line per table update that
   reloads or redraws (decision and section count, no titles).
6. **Simplify pass** (`1122796a`) and **one wide-column rule** (`d27961ee`,
   Felicity's decision; see below).

Lines (sources only): `MediaTrackList` 1,371 → 1,104,
`MacNativeTrackTableView` 1,076 → 957, `NativeTrackListSections` 91 → 214,
`TrackListLayoutMetrics` 138 → 128, `TrackArtworkThumbnailLoader` 34 → 89,
`TrackRowContent` new 67; host and configuration unchanged. Total 2,931 →
2,780. The branch touches 1,327 lines (599 added, 728 deleted, tests
included), over the brief's rough 900-line guide; most of it is deletion.

### Change-detection differences and how they were resolved

| # | Case | iOS before | Mac before | Now (both) |
| --- | --- | --- | --- | --- |
| 1 | Are the tracks unchanged? | Equal revision, or shared array storage, else an identity scan | Equal revision, else full `==` | Equal revision if the caller sets one, else shared storage per section, else one identity-and-equality pass |
| 2 | Same tracks, edited details (title, rating, download flag) | Nothing: stale until the row scrolled away | Full reload | Redraw visible rows |
| 3 | When visible rows redraw | Only on specific flags (playing track, downloads, availability, offline, favourites) | Every update | Only when row state or track details changed |
| 4 | Favourites | Ratings revision plus a per-track favourite scan | Covered by the always-redraw | Ratings revision in row state; scan removed |
| 5 | Offline | Tracked | Not tracked | In row state |
| 6 | Display flags (artwork, numbers, album name, row height, width, source labels) | Not detected | Covered by the always-redraw | In row state |
| 7 | Header revision | Reload | Hosted header refreshed on every update | Kept per table: `headerRevision` (UIKit), `bottomSpacer` (AppKit) |
| 8 | Row-count mismatch after a non-reload update (Mac) | — | Safety reload | Kept |
| 9 | Selection after reload | Re-selects the same track | Native | Kept per table |

Felicity approved the single rule, including the visible change in row 2.
Recorded-reason check (`known-issues`, its 2026-05-13 archive, and
`git log -S` for `reconfigureRows`, `compareTrackListState` and
`trackIdentityOrderMatches`): no recorded reason for iOS not redrawing on
edited details. Related records: `c7cf4a6a` (February 2026) stopped a reload
on every update that flashed artwork and re-requested same-track artwork;
the archive's "singleton observer cascade" entry stopped every publish from
redrawing all visible cells in every table instance; `80821127` and
`4f882583` reduced scans and moved to source-scoped identity. None argues
against a redraw when details change. The rule still redraws only on a
change, and `TrackCellArtwork` keeps the same-track guard, so no iOS-only
parameter was kept.

### Wide columns: one rule (Felicity's decisions)

At widths with the artist column (≥ 700 pt) the iOS cell differed from the
Mac. Both now use the Mac behaviour (`d27961ee`), with the branches deleted:

- Unavailable tracks: the artist column shows the artist (iOS showed the
  unavailable reason) and the album column shows the album (iOS left it
  blank). The reason is still reachable on iOS: the row stays dimmed, the
  narrow subtitle includes it, and tapping the row shows a "Library not
  synced" toast. On the Mac the reason appears only in the narrow subtitle;
  at wide widths it appears nowhere and double-click shows no toast.
- Album detail: no album column (iOS showed the album's own name on every
  row).

In practice `unavailableReason` is "Library not synced", set for playlist
members missing from the synced library.

### Visible changes

- iOS track lists show edited track details (a rating, a download finishing,
  a rename from sync) without scrolling.
- Wide iPad and iPhone rows show the artist and album for unavailable tracks.
- Album detail on a wide iPad no longer repeats the album's name in a column.

### Hypotheses and follow-ups

- `QueueItemCell` bumps its generation on every configure, so redrawing the
  same item before its load finishes may drop that image (hypothesis, not
  observed). `TrackCellArtwork` skips the same track instead. Settled in
  part 3: real but unreachable.
- The Mac track table has no artwork retry when servers come back
  (`artworkServersAvailable` is iOS-only). Not added: it would change Mac
  behaviour. Part 3 or later.
- iOS row accessibility text goes stale after a redraw (see `known-issues`).

### Results

Final checks ran on `d27961ee` (after the simplify pass and the wide-column
change). Installed build proven equal to the built one on each simulator
(`identity.txt`: iPhone build 202611092242.2796, iPad 202611092330.2796 and
202611100019.2796, same `Ensemble.debug.dylib` hash `ae0a4065…`, no source
changes outside the commit). The Mac ran PID 73399 from
`step6d-2/dd-mac/Build/Products/Debug/Ensemble.app` with
`-ApplePersistenceIgnoreState YES`, version 0.4.0 (202611092239.2796), at
`d27961ee` (`mac-final/identity.txt`). Earlier passes on `db15d5b9` gave the
same results and are not repeated here.

The Mac was heavily loaded during the simulator runs (another agent's Computer
Use session and builds); some UI tests took three times their usual time.

| Check | iPhone 17 Pro Max | iPad Pro 11 | Evidence |
| --- | --- | --- | --- |
| Songs, album, playlist, artist favourites, Mood, Search, Favorites: rows, context menu, swipe, tap to play | PASS | PASS for Songs, playlist, Mood, Search, Favorites. Album: rows, Disc 1 and Disc 2 headers and numbers PASS; menu, swipe and play NOT RUN (the test could not query the table element). Artist: see below | `iphone-final/`, `ipad-final/`, `ipad-rerun3/` |
| Fast scroll away and back: same titles, same artwork | PASS (artwork distance 0) | PASS (distance 0) | `*-final/uitest.log`, `shots/*recycle*` |
| Play indicator moves to the tapped row and leaves the old one | PASS by screenshot pixels; the UI test assertion FAILS on stale accessibility text, as on the `a5c23da7` baseline | PASS by pixels; same assertion failure | `shots/*indicator*`, `base-iphone/` |
| Pull to refresh with Songs visible and a track playing | PASS: incremental sync ran (0 changes), no table update logged, same titles, artwork distance 0, scroll position unchanged, indicator drawn before and after, rows area pixel-identical. Its indicator assertion fails on the same stale accessibility text | NOT RUN | `iphone-final/uitest.log`, `shots/iphone-refresh-*` |
| `PhoneBrowseAcceptanceUITests` (`-parallel-testing-enabled NO`) | PASS 5/5 run alone; 3/5 during the loaded run (Artists and Playlists sort menus timed out waiting for the app to idle, not track tables) | n/a | `iphone-rerun2/`, `iphone-final/` |
| Wide Songs (1,210 pt window): title, artist column, album column, duration | n/a | PASS | `ipad-final/uitest.log`, `shots/ipad-wide-songs.png` |
| Wide album detail: artist column on the title's line, no album column | n/a | PASS ("Genesis" at x 868 on the title's line; no "Seconds Out" text in rows) | `ipad-rerun3/uitest.log`, `shots/ipad-album-disc2.png` |
| Unavailable rows ("❤️ Tracks"): wide rows show the artist, not the reason; narrow rows keep "Library not synced" in the subtitle; tap shows the "Library not synced" toast | n/a | PASS (album column for these rows not reached: the playlist pane was under 940 pt) | `ipad-final/`, `ipad-rerun3/` |
| iOS Simulator and macOS builds | PASS | | `build-*.log` |
| EnsembleUI package tests | PASS 123/123 on `d27961ee` | | `test-ui-*.log` |
| EnsembleCore package tests | PASS 1172/1172 (the branch does not touch EnsembleCore) | | `test-core.log` |

Mac (built app, Felicity's library, nothing changed):

| Check | Result | Evidence |
| --- | --- | --- |
| Songs (16,982 rows): fast scroll 2,205 rows away and back | PASS: same titles, artwork distance 0 | `mac-final/songs-*.txt`, `fp-*.txt` |
| Double-click plays; indicator moves from "(Anesthesia)" to "[Anthems]" and the old row shows its duration again | PASS | `mac-final/first-play.txt`, `after-doubleclick.txt` |
| Context menu opens (Songs, album, playlist) and Escape closes it; nothing chosen | PASS ("Remove from Playlist" present on the playlist, not chosen) | `mac-final/*menu*`, `playlist-playing.txt` |
| "Seconds Out" via Go to Album: Disc 1 and Disc 2, numbers, double-click "Squonk" plays | PASS | `mac-final/album-*.txt` |
| Playlist "The Greatest": artwork, double-click "Platform" plays | PASS | `mac-final/playlist-*.txt` |
| Table decisions during the session | 14 redraws, 0 reloads | `mac-final/decisions.txt` |
| Ended paused and quit | PASS (`playing → paused`; PID 73399 exited) | `mac-final/end-state.txt` |

Indicator evidence: the screenshots' trailing column was measured for colour
saturation per 20 pt band. On the iPhone, duration text measured at most 9 of
255 and the indicator 255. The coloured band sat on the first row, then on
the third row only; the iPad shots show the same move.

The Mac redrew visible rows at launch while the startup sync and availability
checks ran (hypothesis: availability or ratings revisions changing); none
reloaded the table.

iPad artist favourites: PARTIAL. Opening Au4 from the Search result showed
"Select an Artist" on every part 2 run although the app logged the push (a
suspected routing issue, recorded in `known-issues`; it passed on `b6d82488`).
Opened from the Artists list and scrolled in the detail pane, Au4's table
showed its 4 favourite rows ("Lost Her Way Home" first) and the context menu
opened with Go to Album and Add to Playlist; Play Next ran and closed it. The
swipe step then failed (XCTest reported the cell's visible frame as empty),
so swipe and tap to play were not exercised there (`ipad-rerun5/`). The same
embedded table passed every step on the iPhone and in iPad Search. That run
built at `b61da2c1` (this note only) with the same `Ensemble.debug.dylib`
hash as `d27961ee`.

### Not run

- A redraw caused by edited track details at runtime (a rating, a download
  finishing, a rename): it would change data, and the sync found no changes.
  Covered by the table-driven unit test.
- Physical devices (see the backlog), VoiceOver, Stage Flow's track panel,
  leading swipe on iOS, Mac trackpad swipe and drag-out, Mac Search, Mood,
  Favorites and artist tables, iPad refresh.
- The unavailable rows' album column at ≥ 940 pt (only reached in a wider
  pane than the playlists split gives on an 11-inch iPad).

## Part 3: the queue on the shared row model

Work on 2026-11-10, branch `t3/0d4101ef` from `6a77b3e9`. Evidence is under
`$TMPDIR/step6d-3/` on the test Mac (temporary).

### What changed

1. **Row content and artwork** (`6dc28d59`). `QueueItemCell` takes its title
   and artist from `TrackRowContent(queueTrack:)` and loads artwork through
   `TrackCellArtwork`; the server-recovery retry goes through the same
   object. The queue keeps its own table, sections (History, Up Next,
   Continue Playing, Autoplay, "N more songs"), drag reorder within Up Next
   with the current index + 1 offset, remove, autoplay styling (purple title
   and badge) and menus.
2. **Dead code removed.** `QueueCard` has always passed
   `currentQueueIndex: -1` (since `2b8f5a3d`), because the table shows only
   what plays after the current track. The parameter, its visible-row redraw
   branch, the never-shown playing indicator and the always-hidden duration
   label are gone, and the leading constraints are set once instead of on
   every configure. The table has the accessibility identifier
   `nowPlaying.queue.table` for automation.
3. **Change detection kept.** `TrackListChange` does not fit the queue. It
   compares tracks by identity, while queue rows are queue items (duplicates
   of one track are separate rows), and its row state (playing track,
   availability, downloads, favourites, display flags) is nothing a queue row
   shows. The queue keeps its one rule: reload when the shown items, the
   hidden count or the History toggle change; otherwise nothing. Adopting
   `TrackListChange` would have needed an item-ID check and an empty row
   state beside it, a second mechanism.
4. **Mac queue unchanged.** Its SwiftUI row reads the title and the artist
   (shown only when not empty) and uses `ArtworkView`. Moving that to
   `TrackRowContent` would replace two field reads with two others and remove
   no logic, so it stays as it was.

`TrackRowContent(queueTrack:)` keeps the queue's subtitle as the artist
only. The table initializer would add the unavailable reason ("Library not
synced"), a visible change for such tracks if one reaches the queue.

Lines: `QueueTableView.swift` 908 → 809, `TrackRowContent.swift` 67 → 87,
`QueueCard.swift` 605 → 604; one test (+68 lines in `EnsembleUITests.swift`).

### The artwork-generation hypothesis

Confirmed as a latent defect, never reachable in shipped code. At
`6a77b3e9`, `QueueItemCell.configure` incremented its generation on every
call (lines 161–162) but started a load only when the queue item ID changed
(line 164). A second configure of the same item while its load was in flight
therefore made that load stale (line 180 drops it) and started none, leaving
the grey placeholder until the cell was reused. The only caller that
configured a visible cell again without reuse was the redraw branch for a
changed current index (line 336), and the index was always −1, so it never
ran. Reloads go through dequeue and `prepareForReuse`, which cleared the item
ID and started a fresh load (UIKit's reuse behaviour; not traced at runtime).

`TrackCellArtwork` skips a redraw of the track already shown and keeps its
load. `testTrackCellArtworkKeepsLoadAcrossRedrawAndDropsItForAnotherTrack`
holds a load in flight, redraws the same track (one request, the image
arrives) and, separately, moves to another track (the first load is dropped,
the second arrives once). It runs on macOS; `QueueItemCell` itself is UIKit
and has no unit test.

Artwork identity is now the track and its artwork, not the queue item, so a
reused cell showing another item of the same track reloads from cache, and a
cached thumbnail appears synchronously instead of after a task hop.

### Results

Build identity: both simulators ran Debug builds of `6dc28d59` with no
package changes; the installed `Ensemble.debug.dylib` hash `797f679915e85246`
equals the built one (`identity.txt`; iPad build 202611100455.6285, iPhone
202611100455.6285). Simulator runs used a temporary UI test
(`Step6d3QueueUITests.swift` in the evidence folder; not committed) that reads
the queue from one accessibility snapshot per check, with seeding through
Songs (play, then Play Next on one song twice and another once) and
`ensemble://debug/now-playing?page=queue&shuffle=off&repeat=off&autoplay=off`.
Artwork was checked from screenshots: each row's artwork square has a colour
spread of 40–105 (a flat placeholder is near 0), and an 8×8 fingerprint
compared across shots (`tools/artcheck`).

| Check | iPhone 17 Pro Max | iPad Pro 11 | Evidence |
| --- | --- | --- | --- |
| Up Next and Continue Playing sections with titles, artists, artwork | PASS | PASS | `*/uitest.log`, `*/shots/*-queue-initial.*` |
| Same track twice: two Up Next rows (plus a third in Continue Playing), same artwork | PASS | PASS | same |
| Reorder within Up Next (drag the third row to the top) | PASS: "[Anthems]" moved up, keeping its artwork fingerprint; log `Moved queue item … from 32 to 30` | PASS | `*-queue-after-reorder.*`, `iphone/app.log` |
| Remove a row (long-press menu) | PASS | NOT RUN | `iphone-queue-after-remove.*` |
| Track change: tap the first Up Next row; it leaves Up Next | PASS | NOT RUN | `iphone/uitest.log` |
| Scroll to the end ("15319 more songs") and back: same titles and artwork | PASS | NOT RUN | `iphone-queue-scroll-*` |
| History section | PASS | NOT RUN | `iphone-queue-history.*` |
| Autoplay section after Start Track Radio from Songs: purple titles, artwork | PASS | NOT RUN | `iphone-queue-autoplay.*` |
| Long-press context menu opens (Play Next, Go to Album, Remove from Queue present; nothing chosen) | PASS | NOT RUN | `iphone/uitest.log` |
| Swipe: no swipe actions (the queue table has none, as before) | PASS | NOT RUN | same |
| EnsembleUI package tests | PASS 124/124 (before and after the simplify pass) | | `test-ui*.log` |
| EnsembleCore package tests | PASS 1173/1173 (EnsembleCore is untouched) | | `test-core.log` |
| iOS Simulator and macOS builds | PASS (before and after the simplify pass) | | `build-*.log` |

Mac: NOT RUN. The built app (0.4.0 (202611100313.6285) at `6dc28d59`)
launched with `-ApplePersistenceIgnoreState YES`; PID 61328's executable was
that bundle's `MacOS/Ensemble` (`mac/identity.txt`). The Mac's session was
locked (`CGSSessionScreenIsLocked = 1`, front process `loginwindow`) on both
attempts, so its window had no accessibility tree and synthesized clicks
could not reach it. The instance was quit without any change to the queue.
The Mac queue code is unchanged by this part; its checks are in the
physical-device backlog.

Simplify pass (`f9ba64f0`): one comment made precise; nothing else to
remove. Builds and both package suites were re-run on it; the simulator runs
were not repeated for a comment change.

Notes:

- The queue shows no now-playing row on either platform (only what plays
  after the current track), so "the playing row follows a track change" was
  checked as the tapped row leaving Up Next.
- The queue shows at most 50 upcoming rows and a "N more songs" row, so a
  100-row scroll is not possible; the check scrolled the 50 rows end to end.
- Play Next appends to the end of Up Next (observed).
- Found, not fixed: after a drag reorder, a row's Track Actions button still
  removes the item at that row's old position (recorded in `known-issues`).
  The long-press menu is correct.
- iPad ran in portrait, where the queue spans the full width over the
  sidebar shell.

### Not run

- Physical devices and the Mac (see the backlog).
- Artwork retry when servers come back (`artworkServersAvailable`), offline
  rows, VoiceOver, iPad landscape and Split View, and the Now Playing wide
  panel. The Mac still has no artwork retry in its queue or track table;
  adding one would change Mac behaviour and is left as a question.
