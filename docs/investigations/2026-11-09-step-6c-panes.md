# Step 6c verification: panes

Date: 2026-11-09. Branch `step6/panes`, source `a3bb2cc6` (app code unchanged
by this run; the only source edit is the test fix in `f28f2312`). Follows the
earlier run on `c0b33b0d`; checks it passed are not repeated. Evidence is under
`$TMPDIR/step6c-verify2/` on the test Mac (temporary; `report.md` there indexes it).

## Build identity

- Simulators: Debug build in `DD-sim`, version `0.4.0 (202611091606.2823)`.
  Installed `Ensemble.debug.dylib` hash equals the built one on both simulators
  (`b875f07c8a48…`). The iPhone's stub executable hash also matches; the iPad's
  differs (relinked by a later incremental build, hypothesis), same version string.
- Mac: signed Release build in `DD-mac`, `0.4.0 (202611091416.2823)`, executable
  SHA-256 `72fa71c6843fd5ce…`. Launched with `open -n <explicit .app>`; every PID
  was selected by its full executable path (`pgrep -f …/DD-mac/…/MacOS/Ensemble`,
  `ps`/`lsof` agree for the first PID).
- Simulators: iPhone 17 Pro Max `B07151D0-…`, iPad Pro 11-inch (M5) `6511F397-…`,
  both verified `Shutdown` at the end.

## `testArtists` on the iPhone 17 Pro Max: test fragility, not a product defect

The failure was `Failed to determine hittability of "Avant-Garde" Button:
Activation point invalid and no suggested hit points based on element frame`.
The accessibility dump shows 'Avant-Garde' is a genre chip with a valid frame
`{492, 241, 110.7, 30}` inside a horizontal scroll view 13,903 pt wide, in a
440 pt window, so it is off screen. XCTest cannot compute an activation point for
it. The test evaluated `isHittable` before its frame and label checks, so the
chips (earlier in element order) were probed first. Artist tiles are labelled
buttons with valid frames (`ABBA {34, 342, 100, 126}`). Why the SE passes is
not established (hypothesis: its narrower layout or element order never reaches
a clipped chip first). Minor unconfirmed note: each tile carries an empty-label
static text with a zero frame.

Fix (`f28f2312`): one `firstBrowseRow()` helper, frame check before `isHittable`,
and the Albums-only `", "` label test dropped (most artist labels have no comma).
`PhoneBrowseAcceptanceUITests` 5/5 on the iPhone 17 Pro Max simulator, twice
(`a1-fix.log`, `a2-fix.log`). The SE was not run (another worker had it).

## Simulator results (new commits `0e21684a`, `bf268d59`, `67abc619`, `cd8ba014`)

Temporary XCUITests (reverted, source kept as `EnsembleLaunchUITests.with-temp.swift`)
drove the app. Debug links went through `simctl openurl`; iOS shows an
"Open in Ensemble?" alert for the custom scheme, so the test taps Open. The runtime
guide does not mention that alert.

| Check | Result | Evidence |
| --- | --- | --- |
| iPad: artist, genre, playlist pick opens detail in next column; merged playlist ("2 sources") too | PASS | 16 screenshots at about 0.2 s intervals after each tap. First frames viewed for artist (header, disabled Play) and playlist (title plus skeleton rows): no loader-only frame. Genre and merged judged from the settled hierarchy and screenshot. Sampling cannot see a frame shorter than 0.2 s |
| iPhone: the same four push | PASS | `PhoneBrowseAcceptanceUITests` Artists, Genres, Playlists open a detail with Back; merged playlist screenshot shows the pushed detail |
| Mood tracks loads and plays | PASS | iPad: 70 rows, Pause appeared. iPhone: 69 rows, Pause after Play (a row tap did not start playback on the phone, so the test taps Play) |
| iPad `surface=artists` with an artist picked | PASS | list root and "Select an Artist" |
| iPad pinned item, `surface=albums` | PASS | Albums bar, Albums row selected, pin not selected |
| iPad `surface=settings` by link and by launch argument | PASS | Profile bar |
| iPhone `surface=songs` | PASS | More tab selected, Songs bar |
| iPad full-width Songs, Favorites, Home push a detail | PASS | Songs/Favorites via Go to Album, Home via an artist tile |
| iPad Search pushes a detail | FAIL, pre-existing | see below |
| iPhone back keeps scroll position (Albums) | PASS | row y 407.67 before and after |
| EnsembleUI package tests, `NavigationCoordinatorTests` | PASS | 124 XCTest tests, 0 failures; 24 tests, 0 failures |

Search finding: on iPad, tapping an artist result switches the sidebar to Artists
and shows "Select an Artist". The log shows `externalRoute destination=artist
targetTab=Artists`, `push depth=0->1`, then 0.44 s later `setPath depth=1->0`.
The same test on the pre-6c parent `cf4e8d19` fails identically, so 6c did not
cause it. Which code clears the path is not established. Non-artist search results
were not tried.

## Mac (explicit built app)

| Check | Result | Evidence |
| --- | --- | --- |
| Artists, Genres, Playlists: list in picker column, detail in next | PASS | screenshots under `mac/` |
| Debug routes on the Mac: `surface=artists` with artist picked; pinned item then `surface=albums`; `surface=settings` by link and launch argument | PASS | list root plus placeholder; Albums selected and pin deselected; Profile window both ways |
| Ten sidebar switches with music playing | PASS, with notes | eight screenshots per switch. No empty or chrome-only frame (detail-area contrast never dropped). Two switches (Songs to Albums, Albums to Home) showed placeholder artwork in the first frame after the click, then artwork: a small pop. Header fade not seen at this sampling. Home resets scroll (expected) |
| Sampled main-thread median against 299 ms | PASS | below |

Re-measure, 2026-10-01 method (fresh process starting on Songs and on Artists,
four alternating clicks each, Time Profiler attached to the PID, sampled
main-thread ms within tabChanged − 150 ms to + 1 s). Three sets, each two
launches, so six warm and two cold transitions per set:

| Set | Warm transitions (ms, sorted) | Warm median | Cold (ms) |
| --- | --- | ---: | --- |
| 1 | 153, 155, 181, 183, 191, 208 | 182 | 156, 204 |
| 2 | 151, 153, 176, 182, 187, 191 | 179 | 159, 221 |
| 3 | 161, 163, 172, 181, 181, 190 | 176.5 | 161, 212 |

Pooled 18 warm: median 181 ms, range 151–208, against the 299 ms baseline
(251–351). A trial set run first to prove the pipeline (131–171, median 150) is
excluded. Cold: 156–161 for Songs to Artists, 204–221 for Artists to Songs.
Differences from 2026-10-01: Release build of a later commit; clicks synthesized
at fixed coordinates 6.5 s apart (not the earlier dwell protocol); window set to
1152 × 883 pt (2304 × 1766 px); Time Profiler only (no Activity Monitor, no
potential-hang table); tabChanged wall-clock mapped to the trace start date; the
Mac was not otherwise idle (other apps were open and in use), so the absolute
numbers carry that risk. No focus loss was detected in any run.

## Not run

- iPadOS 17: accepted gap (Felicity, 2026-11-09).
- iPad Split View resizing: NOT RUN (no tool to drive it).
- Physical iPhone SE (in use by another worker); `testArtists` after the fix was
  not run there.
- Rotation, track tables, and the earlier run's passed checks were not repeated.
