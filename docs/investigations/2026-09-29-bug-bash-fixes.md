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
- AirPlay timing, external displays, and physical Watch behavior remain separate
  investigations; this batch does not establish hardware behavior.
