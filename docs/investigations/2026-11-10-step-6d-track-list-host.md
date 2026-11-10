# Step 6d part 1: one track-list host

Date: 2026-11-10 (work on 2026-11-09). Baseline and rollback point: `e51fed2e`
(`develop` with 6a–6c). Design:
[`browse-detail-panes-design.md`](../reference/browse-detail-panes-design.md)
section 2.5, first bullet. Part 2 (shared row model, queue on it) is not
started. Evidence is under `$TMPDIR/step6d-1/` on the test Mac (temporary).

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
