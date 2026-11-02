# Step 6 design: browse, detail, and panes

Status: draft for Felicity's approval, written 2026-11-02 against `0ed447e1`.
Implementation waits for approval. Plan context:
[`rearchitecture-plan.md`](rearchitecture-plan.md) sections 4.7 and 5.

## 1. Where things stand

Paths are under `Packages/EnsembleUI/Sources/` unless noted.

- **Browse and detail share one file per kind.** `ArtistsView.swift` (1,665
  lines) is about 470 lines of browse plus a 1,050-line `ArtistDetailView`.
  `SongsView.swift` (479) is small because its table lives in the shared
  track-list host. Albums 750, Playlists 1,338, Genres 613, Favorites 241,
  Mood 301. These are the most-changed UI files: Artists 47 commits in 90
  days, Albums and Playlists 37 each, `MediaDetailView` 33.
- **Browse already shares its parts** (toolbar, sort menu, filter sheet,
  scroll index, empty and loading scaffolds, count footer) but every screen
  re-wires them: filter, sort and sheet wiring, the genre chip bar, the empty
  state, the loading/empty/content switch, and selection plumbing are copied
  across four to five screens.
- **Detail is built two ways.** Album, Playlist and Merged Playlist use
  `Screens/Details/MediaDetailView.swift` (1,717), configured by about 20 init
  flags, two `AnyView` slots and `as? PlaylistDetailViewModel` checks. Artist,
  Genre, Favorites, Mood and Downloads hand-build pages on
  `MediaDetailSurface`; Artist repeats the collapsing title, pin menu, artwork
  loading and playlist actions.
- **Browse screens know where detail goes.** Compact layouts push a
  `NavigationCoordinator.Destination` resolved by
  `NavigationDestinationFactory`. Large-screen layouts build detail inline in
  `LargeScreenBrowseSplitView`'s `detail:` closure, repeating the factory
  (Playlists even repeats the merged-or-single choice).
- **Panes.** iPhone uses tabs with one `NavigationStack` per tab. iPad on
  iPadOS 18+, wide iOS 27 iPhones, and the Mac use `NativeBrowseSection`:
  sidebar, a picker column for Artists, Genres and Playlists, and a detail
  stack. On iPad 18+ that is already native `NavigationSplitView`. The
  hand-built `LargeScreenBrowseSplitView` (242 lines) now serves only the
  iPadOS 17 `legacySidebar` shell, gated by an `iOS 18` availability check.
  `SidebarView` takes about 1,700 of `MainTabView.swift`'s 2,199 lines.
- **Mac split.** `MacBrowseSplitView` (146 lines) wraps one
  `NSSplitViewController`. It replaced SwiftUI's split because switching
  between two- and three-column splits rebuilt the root and sidebar; the
  AppKit controller cut warm sampled main-thread work from 471 to 299 ms
  ([investigation](../investigations/2026-10-01-macos-native-container.md)).
- **Track tables.** Three native backends: UIKit `MediaTrackList` (1,652,
  27 commits), AppKit `MacNativeTrackTableView` (1,097), UIKit
  `QueueTableView` (908), plus a SwiftUI queue `List` on the Mac. Action
  menus and swipe resolution are already shared. The two big tables duplicate
  the row cell, artwork loading and retry, header hosting, change detection,
  and row bookkeeping. `NativeTrackListConfiguration` exists but only
  `SongsTrackListHost` takes it; detail, search, artist, Mood and Stage Flow
  call `MediaTrackList` directly (two initializers, one with 41 parameters)
  behind an `#if os(iOS)` at each call site.

## 2. Design

### 2.1 One browse screen

A `LibraryBrowseScreen` scaffold owns everything the screens re-wire today:
toolbar, filter, sort and sheet wiring, the genre chip bar, the
loading/empty/content switch, search, refresh, scroll index, and count
footer. Each kind supplies a small configuration value: its sort options,
which filters apply, its empty-state copy, and its content.

Per kind, kept as content views:

| Kind | Content | Kind-specific behaviour kept |
|---|---|---|
| Albums | album grid, StageFlow | hide singles, year filter |
| Artists | artist list | none beyond the list |
| Playlists | playlist list | New, swipe delete, rename, mutation feedback |
| Genres | genre list | none beyond the list |
| Songs | track table | track sections, StageFlow rebuild |
| Favorites, Mood | track table | virtual-collection header |

The browse screen emits a `Destination` and never builds detail. The two
artist list layouts inside `ArtistsView` become one.

### 2.2 One detail screen

`MediaDetailView` takes one `DetailConfiguration` value per kind instead of
its flags, `AnyView` slots and type checks: header style, track-list options
(numbers, disc grouping, artwork), menu actions, pin action, and an ordered
list of extra sections. Artist and Genre move onto it:

- Artist supplies its hero, About and facts, related artists, release
  sections, and favourited tracks as sections. Its artwork continuity store
  is kept and shared, not rewritten.
- Genre supplies an album-grid body instead of a track list.
- Favorites, Mood and Downloads keep the `MediaDetailSurface` header and use
  the same track-list host.

Detail views move out of the browse files into `Screens/Details/`.

### 2.3 One pane container

- `NavigationDestinationFactory` is the only place a `Destination` becomes a
  view. The inline `detail:` closures are deleted.
- Each kind declares `.fullWidth` (Albums, Songs, Favorites, Search, Home) or
  `.listPlusDetail` (Artists, Genres, Playlists), as today.
- iPhone pushes. iPad 18+, wide iOS 27 iPhones, and the Mac show
  `.listPlusDetail` detail in the next column through `NativeBrowseSection`.
- iPad: the native split already runs on 18+. If `NavigationSplitView`
  behaves on iPadOS 17 (it exists since iOS 16), the `legacySidebar` shell,
  `LargeScreenBrowseSplitView`, and the `EnsembleScaffold.BrowseSplit` pane
  math are deleted. See open question 1.
- `SidebarView` moves out of `MainTabView.swift` into its own file.
- Selections stay above the adaptive containers, and roots stay structurally
  stable, per `ui-conventions`.

### 2.4 Mac split and the sidebar pop-in

`MacBrowseSplitView` stays. The pop-in known issue (`known-issues`, "Top-Level
Navigation Pop-In") is blamed on replaced screen subtrees and display data
that arrives late, not on the split container, so a container swap would not
settle it. Step 6 addresses the cause directly:

- the browse scaffold seeds its display state synchronously from the
  root-owned browse snapshots (`LibraryBrowseSnapshots`) on first render;
- view-local caches and unused view models in the listed screens are
  removed;
- top-level roots keep a stable identity across sidebar switches.

After the consolidation, re-measure Mac sidebar switching with the
2026-10-01 method. Re-testing the native SwiftUI split is optional (open
question 4).

### 2.5 Track tables

- Every caller passes one `NativeTrackListConfiguration` to one host
  (`SongsTrackListHost`, renamed `TrackListHost`). The per-call-site
  `#if os(iOS)` forks and `MediaTrackList`'s duplicate initializers go.
- The UIKit and AppKit tables share one row model: cell content, column
  widths, artwork loading and retry, change detection, and row bookkeeping.
  The cells themselves stay native.
- Kept native on purpose: Songs and long detail lists run to about 17,000
  rows, and the `architecture` skill and the known-issues archive record why
  SwiftUI lists were not enough there.
- The queue keeps its own table, because of its sections and reordering, but
  uses the shared row model. Downloads keeps its SwiftUI rows.

### 2.6 Penpot design system

Step 6 changes structure, not looks. Visual values stay in `DesignSystem/`
(`EnsembleDesign`, `View+DesignModifiers`, `TrackListLayoutMetrics`), so the
Penpot work can restyle the browse scaffold, the detail sections, and the
shared row model in one place each. Order: step 6 lands the shared
components first, then Penpot tokens and visuals map onto them. If a Penpot
component spec is ready before a sub-step starts, that sub-step builds to it.
The Penpot file could not be read on 2026-11-02 (plugin tab suspended), so
this alignment is unchecked (open question 2).

## 3. Sub-steps

Each sub-step ships alone on `develop` and deletes the path it replaces.

- **6a. Detail.** `DetailConfiguration`; Artist and Genre onto
  `MediaDetailView`; detail files moved out of browse files.
- **6b. Browse.** `LibraryBrowseScreen`; screens emit destinations only;
  inline detail closures deleted.
- **6c. Panes.** iPadOS 17 decision; legacy shell and hand-built split
  removed if approved; `SidebarView` split out; pop-in fixes; Mac
  re-measure.
- **6d. Track tables.** One configuration and host; shared row model; queue
  on the shared row model.

The freeze (plan section 6) covers browse, detail, and track-list code while
step 6 runs.

## 4. Acceptance

Simulator and Mac, with the build proven to be the one just produced. The
iPhone checks are deferred, so each is also added to
`physical-device-backlog.md`.

- **iPhone simulator, iOS 27:** each browse kind loads, sorts, filters,
  searches, refreshes, and shows its empty state; each detail kind opens,
  plays, and shows its kind-specific sections; deep links
  (`ensemble://album/…`, `ensemble://debug/open?surface=…`) land on the
  right screen; back navigation keeps scroll position.
- **iPad simulator, iPadOS 27, and iPadOS 17 if that path is kept or
  replaced:** Artists, Genres, Playlists show detail in the next column;
  rotation and Split View resizing keep the selection; full-width kinds push.
- **Mac, explicit built app:** the same list-plus-detail checks; sidebar
  switching shows no empty or chrome-only frame across ten switches with
  music playing; the warm sampled main-thread median stays at or under the
  299 ms baseline.
- **Track tables on all three:** a 1,000+ row list scrolls; swipe actions,
  context menus, drag-out, double-click on the Mac, the play-state
  indicator, and the scroll index work; queue reorder and remove work.
- **Tests:** the existing EnsembleUI and EnsembleCore suites pass. Add one
  table test for `Destination` resolution only if 6b creates a new mapping
  contract.

## 5. Size and risk

- **Size, information only.** In scope: about 7,500 lines of browse and
  detail screens, 4,948 of track lists, 1,203 of browse helpers, and 2,199 in
  `MainTabView.swift`. Expected removal: roughly 2,500 to 3,500 lines, mostly
  the duplicated artist detail plumbing, re-wired browse code, the duplicate
  table cell code, and the legacy iPad shell.
- **Success measure:** fewer fix commits in these files (plan section 8).
- **Risks:**
  - Artist detail is the most-changed file and has artwork-continuity
    behaviour that earlier fixes tuned. Move it last within 6a and keep its
    store.
  - Large lists: any change to the native tables can bring back the
    cell-recycling and layout bugs in the known-issues archive. 6d shares
    models, not cells.
  - Mac pop-in and sidebar latency have regressed before; 6c re-measures.
  - iPadOS 17 has no physical test device in the plan; it would rest on the
    simulator.

## 6. Open questions for Felicity

1. **iPadOS 17.** Should step 6 try native `NavigationSplitView` on iPadOS 17
   and delete the legacy shell if it behaves, or keep iPadOS 17 on the legacy
   shell? The current gate is an `iOS 18` check whose reason is not recorded.
2. **Penpot.** What state is the Penpot design system in, and which
   components come first? Should step 6 stay structure-only, as proposed, or
   build to Penpot specs where they exist?
3. **Artist detail.** Is folding Artist detail onto the shared detail screen
   acceptable, given it is the highest-churn file?
4. **Mac native split.** Re-test SwiftUI's split after consolidation, or keep
   the AppKit split without re-testing?
5. **iPad Pro.** The physical iPad is approved for step 6. Connect it for the
   pane checks, or defer it like the iPhone checks?
