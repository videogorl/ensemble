# Bug bash fixes — 2026-09-29

Source: [Bug bash](https://app.notion.com/p/videogorl/Bug-bash-3d11906996c08018aac0cfe2a2b3256d).

## Changes and evidence

- **Albums / StageFlow handoff:** the first visible album was not captured on
  appearance, and a transient empty viewport during rotation cleared the last
  valid position. Preserve that position and capture the initial visible item.
  The fresh simulator build opened StageFlow on An Awesome Wave, returned from
  Asphalt Meadows to that album's grid position, and preserved the Z position
  through a second rotation cycle.
- **Mini player over tab buttons:** UIKit reported the tab bar as hidden while
  restoring its correct portrait frame, causing clearance to become zero.
  Measure the frame instead; the root already suppresses the mini player during
  StageFlow and keyboard presentation. Both rotation cycles restored separate
  mini-player and tab-bar rows, and tapping Feed worked immediately afterward.
- **Artist navigation:** Search now carries its resolved Artist into the detail
  loader. Album artist subtitles can route by name when metadata omits the ID;
  the loader tries local data first, then the exact provider. Apple Music can
  resolve an uncached catalog artist by ID or an exact normalized name match.
  Simulator Search and Feed album routes both retained the merged Miley Cyrus
  detail with two sources. Live Apple Music lookup still needs a signed-in
  physical-device check; the simulator has no enabled Apple Music source.
- **Artist punctuation:** inter-letter bullet/middle-dot separators match hyphens
  across Library, Feed, and Watch. Other punctuation and stored metadata remain
  unchanged. Shared identity and surface-grouping regression tests cover
  half•alive / half·alive / half-alive and typographic quotes.

## Verification

- iPhone 17 Pro (AW), iOS 26.5, UUID `C0C6CF8B-7B59-4402-9D8D-CB4CFBF5D64D`.
  Unique DerivedData; installed executable SHA-256 matched the built executable;
  running process verified. Playback remained paused.
- iOS workspace Debug build passed. Focused Domain (2), UI (32), Watch (3),
  DisplayArtist (4), and SyncProviderResolver (10) tests passed.
- Of four permalink resolver tests, three passed. The playlist title-case test
  failed with `road trip` versus `Road Trip`; the identical failure reproduced
  in a detached, untouched baseline checkout at `ca7deba5`.
- AirPlay timing and physical Watch behavior remain separate investigations;
  this batch does not establish hardware behavior.

## Architecture follow-up

- `ArtistDetailResolver` in Core now owns concrete, source/ID/name, and display-ID
  routes. It reuses committed library values, resolves exact-source IDs before
  falling back to names, applies current visibility, and then merges. UI owns
  loading/error presentation. The duplicate name-first navigation path and the
  loader's whole-library fetch/group implementation were removed.
- Remote artist lookup is an opt-in `MusicSourceArtistResolving` capability.
  Unsupported providers produce a routing error, distinct from a supported
  provider returning no artist. Apple Music owns the existing MusicKit mapping.
- The external scene now checks its noninteractive role. Available mode count
  no longer guesses the transport or suppresses window creation. Interactive
  extended-desktop windows remain with the application scene. Disconnect checks
  for remaining supplementary scenes before clearing the existing timing flag.
- The external shell fills its available width using the shared wide layout;
  iPad keeps the existing default width. Obsolete fixed-reference-size and
  `scaleEffect` comments were removed. Audio latency arithmetic was unchanged.

### Follow-up verification

- Fresh iOS workspace Debug builds passed. Built and installed executable hashes
  matched; process executable paths verified on the exact iPhone UUID above and
  iPad Pro 13-inch iOS 26.5 UUID `8300E2C6-6EEF-4D6B-A8EC-740DFA2389A3`.
- 19 focused Core tests passed, including four table-driven artist regressions
  and explicit unsupported-versus-not-found provider coverage. The resolver's
  final exact-ID/cache-order correction passed the four regression tests again.
  All 128 UI-package tests passed, including shared controls, navigation, and
  StageFlow coverage.
- Simulator Feed album-to-artist and Search routes opened Miley Cyrus with two
  sources when merging was enabled. With merging disabled, Search exposed
  separate copies and both routes opened a single-source detail. Merging was
  restored afterward. The final build's Feed route was checked again.
- TVOut screen 2: connection created a noninteractive scene and visible window,
  including the two-mode case that previously returned an empty windows array.
  Power off/on recreated the window. Selecting Lyrics on the phone before
  reconnecting showed Lyrics on the external display. The final build's external
  scene and window were verified again. Playback remained paused.
- `simctl io ... screenConfig --display=2 geometry` changed host framebuffers to
  1280x720 and 1920x1080, but UIKit retained a 720x480 current mode/window. Selecting
  a screen mode through UIKit did not establish a larger guest viewport. These
  images are not evidence of native full-HD layout or TV-distance readability.
  Native full-resolution sizing and physical AirPlay timing remain unverified.
- The final build's shared iPad landscape idle layout was visually inspected;
  that simulator had no configured sources, so this proves idle layout only.
- Local evidence: `/tmp/ensemble-architecture-fixes.daryqw/` contains build/test
  logs, process/hash proof, scene/window diagnostics, and screenshots. External
  TVOut geometry was restored to 720x480 and its power turned off after testing.
