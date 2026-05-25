# iPhone 6s Stability Refactor Context

## Evidence

- iOS 15/offline-mode logs showed repeated hub cache loads, source availability changes, endpoint failover, startup sync, offline healing, Spotlight/Siri indexing, and WebSocket download activity during early interaction.
- The same log showed a burst of `ArtworkView[160]` cancellation failures during endpoint/cache invalidation, consistent with global artwork retry fan-out.
- Run 3 Instruments trace showed a long foreground session with no qualifying hangs, but many GCD performance events and hot samples in SmartMix/audio analysis, Swift metadata, AttributeGraph, CoreData/sqlite, artwork/image I/O, UIKit list layout, share sheet, and system media paths.
- User-visible symptoms mapped to mutable list identity and broad publish fan-out: Feed bouncing to Add Sources, pushed Feed details popping after refresh, artist detail showing the previous artist image, playlist flashes, choppy album scrolling, slow NPV gestures, delayed mini-player appearance, and audio stutter during log sharing.

## Refactor Direction

- Browse surfaces should publish last-good snapshots and never replace visible content with transient empty arrays during bootstrap or degraded refresh.
- Empty/add-source UI is owned by `AppReadinessCoordinator`, not by each ViewModel independently interpreting account, hub, playlist, or source arrays.
- Nonessential CPU/file work is routed through `ForegroundWorkScheduler`: SmartMix analysis, sidecar analysis, offline healing, Spotlight/Siri indexing, artwork retries, log export preparation, and full download-progress recomputation.
- Feed navigation is route-owned through scene-local `NavigationCoordinator` destinations so replacing hub rows cannot pop an already-pushed detail.
- Artist artwork continuity is identity-scoped. Previous artist artwork is never reused for a different `artist.sourceScopedID`.

## Acceptance Focus

- First 20 seconds on iPhone 6s should not bounce Feed between Add Sources and content.
- Feed refresh must not pop album/artist/playlist detail navigation.
- Endpoint recovery should not trigger global artwork cancellation bursts comparable to the observed 62 cancellations in about 35 ms.
- Spotlight/Siri indexing, offline healing, and analysis work should move out of active navigation, Now Playing, share-sheet, and startup-sync windows.
- SmartMix remains available on iPhone 6s, but cached/serialized analysis and graceful fallback should prevent analysis from blocking UI or audio-critical paths.
