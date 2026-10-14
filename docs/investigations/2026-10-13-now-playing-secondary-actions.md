# Customizable Now Playing secondary actions

Implemented four optional slots, duplicate swapping, reset, JSON normalization,
provider availability, default-on KVS sync, an always-present complete overflow,
and explicit guarded native AirPlay presentation on iOS and macOS.
The default remains AirPlay / Favorite / Add to Playlist / empty.

## Verification

- Final serialized workspace builds passed for macOS, iOS Simulator, and physical
  iOS. Logs: `/tmp/ensemble-nowplaying-{mac,se,phone}-acceptance-build.log`.
- Focused Core layout, storage, provider availability, sync bootstrap/push/pull,
  toggle gating, and disabling during bootstrap tests passed. Reset repairs
  malformed stored JSON. Overflow catalog completeness test passed.
- macOS explicit built app path and PID were verified. Slot duplicate swapping,
  reset, complete overflow, and AirPlay menu presentation were exercised.
  The native route picker displayed available outputs; no route was changed.
- SE iOS 26.5, UUID `6D08A51E-1E64-4FAB-8A68-6D94F6D0537A`: actual settings
  defaults, duplicate swapping, reset and relaunch persistence passed. Rows with
  0–4 configured slots centered; five items fit at 375 points. Maximum Dynamic
  Type initially overlapped row icons; the final icon-only type cap resolved it.
  Menu text retains its normal scaling. Built and installed executable AND debug
  dylib hashes matched before final UI evidence. Native Device Hub accessibility
  showed only the pinned AirPlay target. WDA additionally enumerates the hidden
  native button, so its raw node inventory is not VoiceOver evidence.
- SE sync was disabled during injected layout/render cases, then restored ON
  after a real Reset. UI displayed a local push and an actual remote pull on
  re-enable. Defaults and sync ON were verified in persisted preferences after
  the final reset. This is not a controlled two-device convergence check.
- iPad Pro 13-inch iOS 26.5, UUID `8300E2C6-6EEF-4D6B-A8EC-740DFA2389A3`:
  explicit installed executable/debug dylib hashes and running process matched.
  Landscape wide Now Playing empty state displayed the centered default row.
  Populated wide and connected external-display behavior remain unexercised;
  both reuse the shared ControlsCard/wide owner and compile in the app build.
- Screenshots: `/tmp/nowplaying-se-*-slots.png`,
  `/tmp/nowplaying-se-max-type-final.png`, `/tmp/nowplaying-ipad-wide.png`.

## Remaining evidence

Physical iPhone `00008140-00023030117B001C` remained locked. The completed app is
built and installed, but no physical runtime success is claimed. Both pinned and
menu AirPlay showed no picker on the SE simulator; macOS presentation passed.
Remaining checks are in the [physical-device backlog](../reference/physical-device-backlog.md).

Unrelated findings were recorded without repair:

- [Metadata and transport overlap at largest Dynamic Type](https://app.notion.com/p/3f91906996c081cdb9a2c4adbfe1abce).
  Screenshot upload awaits approval because it contains library metadata.
- [Physical runtime helper launch argument parsing](https://app.notion.com/p/3f91906996c081868fdcea50eceea560).

## Cleanup

Both exact simulator UUIDs above were shut down and their Shutdown states were
independently verified. Their agent-device sessions and T3 streams were released.
The phone lock state was independently verified as passcodeRequired. No playback,
provider mutation, or audio-route change was performed on the physical phone.
