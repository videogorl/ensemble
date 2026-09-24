# Design And State

- Use `EnsembleDesign`, `EnsembleScaffold`, and specialized existing metrics
  before adding raw repeatable values. Keep deliberate one-off StageFlow visual
  tuning local unless explicitly retuning the whole surface.
- Use `EnsembleStateScaffold` and `EnsembleLibraryEmptyStateScaffold` for common
  loading, error, empty, restore, and no-source decisions. Show actionable retry
  states rather than unexplained blank content.
- A surface that has shown cached content keeps it visible while refreshing.
  Reserve full loaders for the first load with no usable cache. Stable headers,
  list hosts, and compact footer progress prevent layout swaps.
- Media detail surfaces use `MediaDetailSurface`, shared header/action helpers,
  and `artworkBackedToolbarBleed()`. Avoid parallel detail metrics or leaf-level
  titlebar/safe-area fixes.
- Artwork display uses downsampled requests and durable cache-first resolution.
  Large washes use cached pre-rendered blur, never live SwiftUI blur. Keep prior
  artwork only for the same continuity identity.
- Keep toolbar behavior declarative. On modern OS versions use native SwiftUI
  toolbar background/visibility APIs; AppKit/UIKit appearance bridges are narrow
  compatibility owners only.
- Liquid Glass controls use native interactive glass and explicit capsule/circle
  border shapes on supported OS versions. Do not apply a plain/chromeless button
  style that suppresses native glass interaction.
- Shared media rows/cards/headers/actions use existing components so typography,
  icon meaning, source labels, spacing, and accessibility do not drift.
- Use system fonts and semantic colors. App accent comes from the environment;
  do not pipe the stored accent value into every ambient surface.
- When introducing a new shared visual rule, add it here only if source/component
  ownership cannot communicate it clearly. Do not record resolved incident
  history or per-screen implementation inventories.
