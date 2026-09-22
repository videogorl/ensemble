# Bug bash follow-ups

Source: [Bug bash](https://app.notion.com/p/videogorl/Bug-bash-3d11906996c08018aac0cfe2a2b3256d)

## Open

- Feed artwork refreshes or disappears after relaunch: reproduce on a fresh build, then compare the artwork request, durable cache identity, and cancellation path across launches.
- Mac Songs/profile-menu stall: baseline build became CPU-bound while opening the menu from Songs. A process sample showed native menu tracking plus track-table updates and merge-identity normalization. Relaunching on Albums avoided it. Investigate separately; the sample identifies a hot path, not a confirmed root cause. Local sample: `/tmp/ensemble-mac-bugbash-20260922/baseline-sample.txt`.

## Completed Mac follow-up

- Option-selection in the profile menu now shows all enabled libraries on the selected server and hides other servers. Ordinary selection still toggles one library. Existing hidden preferences for disabled sources and Focus filtering are preserved.
- Aurora and the mini-player waveform use the native accent on macOS. Sidebar rows use SwiftUI's preferred item tint: the app color under Multicolor, the explicit system color otherwise. Native selection highlighting remains system-managed.

Verification on macOS 27.0 (26A428):

- Reproduced the old Option action toggling one library, and purple playback visuals alongside system-Pink sidebar icons before edits.
- Fresh workspace build passed. Explicitly launched `/tmp/ensemble-mac-bugbash-20260922/DerivedData/Build/Products/Debug/Ensemble.app`; final process 21321 ran that executable, version `202609221327.1227`.
- Native menu Option+Return isolated Hiigel-Server (filtered album results changed from two to one); Show All restored the library. This exercises the modifier action through the native menu; a physical Option-mouse-click was not separately automated.
- Visually verified sidebar icons, waveform, and playing Aurora in macOS Multicolor with Ensemble Purple, then live switching back to macOS Pink. Original Pink system setting, Purple app setting, all sources, and paused playback restored. Native list selection highlight stays system-managed.
- All 14 `LibraryVisibilityProfileTests` passed, including server isolation with multiple libraries, separate accounts, initially hidden sources, persistence, malformed input, and Focus protection.
- Older supported macOS versions and the Canvas fallback were not runtime-tested.
