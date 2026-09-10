# Native browse container experiment — 2026-09-09

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
