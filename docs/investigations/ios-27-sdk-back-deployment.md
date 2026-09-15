# iOS 27 SDK and deployment targets

Checked with Xcode 27 on 2026-09-15. Ensemble still targets iOS 15 and macOS 12.

## What back-deploys

- `ContentBuilder` supports any SwiftUI deployment target. The SDK's builder implementation adapts the generated code to the deployment target; it does not require iOS 27. Existing `ViewBuilder` code already benefits from the updated compiler. A repository-wide annotation rename would not remove compatibility branches.
- The new `State` macro lazily initializes observable reference models. Apple back-ports that behavior to iOS 17/macOS 14, where Observation was introduced. This does not make `@Observable` available on iOS 15 or replace Ensemble's `StateObject` ownership requirements.
- An SDK can explicitly back-deploy individual functions using `@backDeployed`, or export implementations into client code. The symbol's declared availability still determines whether a call needs a guard. New OS framework behavior is not automatically bundled into the app.

## Navigation consequences

- `NavigationSplitView` starts at iOS 16/macOS 13; the preferred compact-column initializer starts at iOS 17/macOS 14. Ensemble's native browse implementation additionally uses iOS 18/macOS 15 scroll APIs.
- `defaultTabBarPlacement` is declared `@available(anyAppleOS 27.0, *)` in the installed SwiftUI interface. It has no back-deployment implementation there. The older `defaultAdaptableTabBarPlacement` is iOS 18-only and is a different API; its availability does not grant the new iPhone behavior on older systems.
- Reusing the iPad sidebar removes the phone's adaptive-tab-sidebar wrapper and its availability branches. Compact phones use the existing automatic tab style. This simplification comes from sharing the navigation owner, not from treating all iOS 27 APIs as back-deployed.
- Keep the iOS 15 navigation fallback and the iOS 27 gate for the new resizable phone shell. Do not raise the minimum OS version or migrate unrelated observable models for this change.

## Local compiler checks

Using the installed iPhoneSimulator SDK and `swiftc -typecheck`:

- A two-child `@ContentBuilder` view compiles for `arm64-apple-ios15.0-simulator`.
- An unguarded `.defaultTabBarPlacement(.sidebar)` call fails for `arm64-apple-ios26.0-simulator`, with “only available in iOS 27.0 or newer.”

These checks prove source availability, not runtime UI behavior on those releases. Probe sources/logs: `/tmp/ensemble-shared-browse-20260915/{builder,placement}-probe.*`.

## Sources

- [Apple: What's new in SwiftUI, WWDC26](https://developer.apple.com/videos/play/wwdc2026/269/) — compiler/builder changes, State back-port, and resizable iPhone scenes.
- [Apple: TN3211, State and ContentBuilder source incompatibilities](https://developer.apple.com/documentation/technotes/tn3211-resolving-swiftui-source-incompatibilities-for-state-and-contentbuilder) — deployment-dependent builder representations and migration constraints.
- [Swift: Attributes — backDeployed and export](https://docs.swift.org/swift-book/ReferenceManual/Attributes.html) — explicit function back-deployment and client-emitted implementations.
- Installed declarations: `Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`.
