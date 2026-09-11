# Native browse container experiment — 2026-09-09

> Historical record: the adaptive-tab composition described here was removed.
> The current content-column implementation and evidence are in
> [native-browse-content-column-sources-2026-09-10.md](native-browse-content-column-sources-2026-09-10.md).

## Historical integration checkpoint

The experiment now uses the existing `SidebarView` and its shared actions instead
of a second sample sidebar. This is a **gated integration checkpoint, not a
shipping replacement**. Normal launches and Release builds still use the legacy
shell. The iOS 15/macOS 12 deployment targets and ordinary iPhone StageFlow path
are unchanged. Nothing has been merged or pushed.

### What is integrated

- All library destinations, Hidden, existing enabled-tab defaults, profile and
  downloads controls, real Pins, smart/regular playlist shortcuts, and sidebar
  artwork. Native customization is persisted separately; Pin ordering is applied
  through the existing Pin owner and its native ordering override is then reset.
- Existing Pin context menus and playlist-drop execution are shared by both
  shells. The native drop uses `MediaDragPayload`'s Codable Transferable
  representation; source resolution and mutation handling are not duplicated.
- Artist/genre/playlist selections live above replaceable tab content. An
  inactive stack cannot write back into a newly selected root's shared path.
  External and Now Playing routes select library stacks rather than relying on
  a possibly absent playlist/Pin shortcut.
- The shared root chrome owner uses native content bounds and the native sidebar
  footer's measured horizontal span. The footer can sit below the root safe area;
  its appearance/disappearance callbacks clear stale geometry when hidden.
  There is no guessed native sidebar width or delayed layout correction.
- Native Tab labels extract their image without preserving ordinary frame
  modifiers. Intrinsically sized images now use the existing `ArtworkView` loader
  and cache. Artist rows use native Buttons for selection accessibility.
- The standalone sample-Pin fixture was removed. `NativeBrowseSection.swift` is
  151 lines. Compared with the committed prototype, production Swift grows by
  227 net lines, largely native tab composition and shared action wiring. No new
  package, service, cache, custom divider, or navigation coordinator was added.
  This measures source size, **not** binary size or runtime overhead.

### Verification and its limits

| Check | Integration evidence |
| --- | --- |
| Builds | Full iOS simulator and macOS workspace Debug builds pass with existing deployment targets. |
| Package coverage | All 123 EnsembleUI tests pass. Focused additions cover inactive-root path writes and a floating sidebar footer outside the root safe area. |
| Drag-export test | Corrected an existing intermittent test: read the exported temporary file inside the NSItemProvider callback, before the system deletes it. Production export code was not changed. |
| iPadOS 26.5 | Real cached Artists and Albums, native sidebar playlist artwork, and opening/closing the sidebar inspected. Final callback version restores the mini-player's full width when the sidebar closes. |
| Compact navigation | Isolated iPhone 17 Pro / iOS 26.5 clone, forced native flag: Artists → ABBA → Gold: Greatest Hits → Back → ABBA → Back → selected artist list. This is simulator evidence, not physical-device or StageFlow signoff. |
| Real Pin | Created a temporary AJR Pin in the offline/no-iCloud simulator clone; native Pin → The Maybe Man → AJR → The Maybe Man produced logged depths 0→1→2→3. Three Back actions returned to Pin root (3→2→1→0), with no Back at root. Removed the test Pin afterward. This exercises the real Pin store, not the removed in-memory fixture. |
| iPadOS 15.5 | Integrated binary launches with the native argument and shows the legacy Artists shell. Empty library: launch/fallback proof only. |
| iPadOS 27 | Rotation and Artists→Albums→Artists test passes in 268.108 seconds. Four 60-second animation-idle waits remain. Screenshots prove column composition, not complete chrome correctness. This run precedes the final footer-lifecycle adjustment, which was inspected on 26.5. |
| macOS runtime | Explicit built app launched and its PID/executable path was verified. Desktop capture returns `cgWindowNotFound`; no live window, resizing, keyboard or menu parity claim. |

The existing drag test fix follows [Apple's documented temporary-file lifetime](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation%28fortypeidentifier%3Acompletionhandler%3A%29).

### Still required before enabling the modern shell

1. **Fix and recheck chrome across transitions.** On 26.5, open then hide the app
   sidebar: the Artists toolbar can move into the top-tab region and its inner
   sidebar toggle becomes obscured. The landscape 27 screenshot also shows
   different mini-player centering between Artists and Albums. The portrait
   overlay fix does not establish complete rotation/window chrome parity. Resolve
   ownership here; do not add arbitrary padding, delays, or OS-specific widths.
2. **Close runtime coverage gaps.** No iPadOS 18 runtime is installed. Desktop
   capture is unavailable. Test actual 18, current iPad, macOS minimum modern OS,
   narrow/resizable windows, Dynamic Type, keyboard/VoiceOver, and multiwindow.
   The existing phone shell needs its own StageFlow regression pass.
3. **Complete state/action acceptance.** Native customization versus Settings,
   Pin reorder/iCloud reconciliation, unpin while deep, actual drag/drop onto a
   disposable playlist, hidden/removed sources while selected, and external/Now
   Playing routes need acceptance coverage. Wired code is not proof of parity.
   Observed: unpinning from the selected Pin's detail menu returns to Feed and a
   smart-playlist shortcut appears in the top bar. Resolve dynamic-tab identity/
   customization and the selected-Pin fallback before accepting this behavior.
4. **Measure performance.** Compare the same cached library and interactions
   against legacy: launch/selection/resize, steady-state memory and CPU, and
   release size. Investigate the XCTest idle waits separately from user-visible
   responsiveness. No zero-regression or negligible-overhead claim is justified.
5. **Promote only after those checks.** Enable the native shell for the intended
   iPadOS 18+/macOS 15+ scope, explicitly settle iPad rotation policy, retain the
   older-OS fallback, and perform release/TestFlight signoff. Do not enable it for
   ordinary phones merely because the compact experiment can run there.

Current launch arguments are the four listed in Reproduce below; the old
`-EnsembleNativeBrowseSamplePin` argument no longer exists. The compact clone is
`8C415280-3613-483E-88E4-869FA53C6063` (verified iPhone 17 Pro, iOS 26.5).

Evidence: `integrated-sidebar-open.png`, `integrated-sidebar-closed.png`,
`integrated-compact-back.png`, `integrated-pin-depth-three.png`,
`integrated-ios15-fallback.png`, and `integrated-*-landscape.png` under
`/Users/felicity/.codex/artifacts/native-browse-20260909/`.
The closed-sidebar screenshot deliberately records the remaining toolbar issue.
Final integration test result:
`/tmp/ensemble-native-browse-27/Logs/Test/Test-Ensemble-2026.09.09_21-11-28--0700.xcresult`.

## Initial feasibility experiment (historical, commit f313dea8)

The remainder records the earlier bounded prototype. Its implementation counts,
sample-Pin argument and incomplete-sidebar list are superseded by the integration
checkpoint above; its evidence remains useful but is not final-build signoff.

## Verdict

The proposed composition works: a native sidebar-adaptable TabView can contain
an Artists NavigationSplitView while Albums uses a single NavigationStack.
There is no need to force every section into the same three-column root.
This is a feasibility prototype, **not a regression-free replacement ready to merge**.

Branch: `codex/native-browse-prototype`, based on `8764180e`.
Worktree: `/Users/felicity/Developer/projects/ensemble-native-browse-prototype`.
Nothing has been merged or pushed. No library, playback, persistence, or provider
implementation was replaced. Testing used isolated simulator clones and simulated
offline mode; the sample Pin exists only in memory and is never saved or synced.

## Implementation and cost

- Debug-only `NativeBrowsePrototype.swift`: 193 lines, including an optional
  sample-Pin fixture. Artists, Genres, and Playlists reuse their existing
  selection-column views and detail screens; other sections reuse the destination
  factory. All pushes use the existing scene NavigationCoordinator.
- Root selection gate: 18 added lines, iOS 18+/macOS 15+ only. Normal launches and
  Release builds retain the old shell, and deployment targets remain iOS 15/macOS 12.
- Six net lines permit iPad rotation only under the modern prototype flag.
  The existing app delegate otherwise locks all devices to portrait unless
  StageFlow is active. A production migration must explicitly resolve this policy.
- One focused UI test, 43 added lines; skipped on phones and pre-18 systems. No package dependencies, new services,
  custom drag gestures, container introspection, width breakpoints, or timing fixes.
- This is an additive experiment, not a net code reduction: the existing
  242-line custom browse split and legacy root shells remain for older systems.
  The prototype size is a feasibility floor, **not an estimate of complete parity**.

## Verified

| Check | Evidence and limit |
| --- | --- |
| Native iPad build | Xcode 26.6, final Debug simulator build, iOS 15 deployment target retained. |
| Older OS fallback | The same built app launched on iPadOS 15.5 with the prototype argument and displayed the existing tab shell/Artists empty state. No connected sources on this clone; this is launch/fallback proof, not a full legacy regression sweep. |
| Real Artists content | iPadOS 26.5: native top tabs plus artist list/detail; selected AJR and loaded its four albums. |
| Albums grid and Back | iPadOS 26.5: switched to full-width Albums, opened Abbey Road, and returned to the grid using native Back. |
| Genres | iPadOS 26.5: selected Jazz; native detail displayed seven albums. Existing saved filters remained in effect. |
| Playlists | iPadOS 26.5: selected Ambient Electric; native detail displayed its 18 tracks. No playlist mutations were performed. |
| Pin route depth | Final 26.5 build: in-memory artist Pin → The Maybe Man → AJR → The Maybe Man; journey logs prove path depths 0→1→2→3 in Artists. Three Back actions returned through artist, album, then Pin root; Back was absent at the root. |
| Section state | Returning from the Pin to Artists retained the previously selected AJR. |
| macOS compilation | Full workspace build succeeded; 22 existing NavigationRootHelperTests passed. No live macOS window, drag-resize, keyboard, or menu parity claim. |
| Rotation | iPadOS 27 UI test asserts landscape→portrait→landscape window geometry; full-screen screenshots confirm sidebar/list/detail in landscape and top tabs/list/detail in portrait. This clone has no sources. |
| Three→two→three columns | The same 27 UI test switches Artists→Albums→Artists through the native sidebar, asserts the corresponding detail/empty-state changes, and captures the two-column Albums result. Passed; the final run took 322.759 seconds because of repeated animation-idle waits. |

The installed app was checked against the explicit build using simulator UUID,
PID executable path, bundle version, and matching debug-library SHA-256 hashes.
The build script generates CFBundleVersion; a requested numeric build-setting
override is not the effective version, so it was not used as proof.

## Regressions and unfinished integration

1. **Root chrome:** the new shell does not publish the old sidebar geometry
   registration. The mini-player uses the root fallback and can extend across the
   app sidebar or obscure content. Reuse/adapt the shared root chrome owner before
   shipping; do not add per-screen padding fixes.
2. **Toolbar placement:** after returning from a Pin to Artists, existing sort
   controls can occupy the top-tab region. The existing browse toolbars need to be
   reconciled with the new native container's toolbar ownership. Native containers
   do not automatically repair existing chrome assumptions.
3. **Deliberately absent parity:** fixed prototype tabs omit user tab preferences,
   some destinations, profile controls, sidebar playlist shortcuts, row artwork,
   reordering, drag/drop, and sidebar context-menu actions. The actual content
   screens retain their existing actions. The Pins TabSection also appears as a
   group in the top bar when selected; presentation needs a product decision.
4. **Width/compact behavior:** the inner split requests a 300-point list width;
   no custom divider is installed. Runtime evidence is for two full-screen iPad
   widths, not arbitrary window widths, user-draggable panels, Dynamic Type,
   external displays, iPhone, or iPhone Duo. Compact selection/Back restoration
   still needs an explicit acceptance test.
5. **Platform coverage:** no iPadOS 18 runtime was installed. Availability gates
   compile, but 18-specific runtime behavior remains unverified. macOS evidence is
   compilation/tests only, not full desktop compatibility.
6. **Test tooling:** the 26.5 XCTest runner failed to launch. The 27 runner worked;
   some runs logged 60-second animation-idle waits. These are not proof of a
   60-second user-visible freeze, nor proof that performance is unaffected.

No claim is made about memory, CPU, binary-size overhead, playback/AirPlay,
source changes while a detail is selected, deep-link restoration, accessibility
parity, or multiwindow behavior. Those were outside this bounded experiment.

## Reproduce

Use the worktree's `Ensemble.xcworkspace`, scheme `Ensemble`, Debug configuration.
Launch with:

```
-EnsembleNativeBrowsePrototype
-EnsembleAutomationMode YES
-EnsembleAutomationSimulateOffline YES
-EnsembleAutomationStartSurface artists
```

Optionally add `-EnsembleNativeBrowseSamplePin` on a library containing AJR with
no existing pins. Omit the prototype argument for the baseline shell.

Exact test clones:

- iPad A16, 26.5: `BA2EED6F-FC16-4903-BFB5-E2A8528F062D`
- iPad Air 5, 15.5: `29AE941D-A0A9-4213-9087-ABC42FA9C23F`
- iPad A16, 27: `66A1479E-5175-437C-83B9-B74ACE002DEB`

Focused checks:

```sh
swift test -q --package-path Packages/EnsembleUI --filter NavigationRootHelperTests
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -workspace Ensemble.xcworkspace -scheme Ensemble \
  -destination 'platform=iOS Simulator,id=66A1479E-5175-437C-83B9-B74ACE002DEB' \
  -derivedDataPath /tmp/ensemble-native-browse-27 -parallel-testing-enabled NO \
  -only-testing:EnsembleUITests/EnsembleLaunchUITests/testNativeBrowsePrototypeRotation test
```

Local evidence is kept outside the repository to avoid committing screenshots
and build products: `/Users/felicity/.codex/artifacts/native-browse-20260909/`.
Build/test logs and result bundles are under `/tmp/ensemble-native-browse-*`.

- [Artists: three columns](/Users/felicity/.codex/artifacts/native-browse-20260909/artists-three-columns.png)
- [Albums: two columns](/Users/felicity/.codex/artifacts/native-browse-20260909/albums-two-columns.png)
- [Artists: portrait](/Users/felicity/.codex/artifacts/native-browse-20260909/artists-portrait.png)
- [Real-library Albums grid](/Users/felicity/.codex/artifacts/native-browse-20260909/albums-portrait.png)
- [Pin at navigation depth three](/Users/felicity/.codex/artifacts/native-browse-20260909/pin-depth-three.png)
- [iPadOS 15 fallback](/Users/felicity/.codex/artifacts/native-browse-20260909/legacy-ios15-final.png)

The real-library grid and initial Pin-return screenshots include an earlier
temporary Rotate Test button; it was removed from the final source. Final Pin
depth-three evidence and the column UI test use the version without that control.

Before a production migration, close the chrome/toolbar gaps, restore the existing
sidebar contract through shared owners, and pass compact-width and iPadOS 18
acceptance checks. This experiment supports proceeding to that work; it does not
justify accepting fragile behavior or promising zero regressions.
