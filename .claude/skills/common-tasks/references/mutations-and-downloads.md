# Mutations And Downloads Recipes

## Playlist And Metadata Mutations

Enter playlist work through `SyncCoordinator` and the resolved provider-neutral
mutation owner. Use `PlaylistMutationWorkflow` or `MetadataMutationWorkflow` for
shared validation, optimistic state, remote/queued result semantics, and toast
payloads. Views own only presentation, confirmations, and post-delete routing.

Use `PlaylistActionPresentationHost` for Add to Playlist follow-up UI and
`PlaylistDropResolver` for drag/drop expansion, compatibility, and dedupe. Never
infer a missing source owner or mutate smart/read-only targets.

## Menus And Swipes

Add actions to the shared settings/action model and `MediaMenuCatalog`; render
through existing native/SwiftUI menu owners. Use native track-list swipe
delegates. Follow-up actions use an ellipsis.

## Download Targets

1. Persist a stable source-scoped target key.
2. Resolve membership through repositories.
3. Upsert exact source-scoped download records with the selected quality.
4. Remove artifacts only when the last target reference is gone.
5. Reconcile through `OfflineDownloadService` and existing background/lifecycle
   coordinators; app delegates and URLSession callbacks must not start their own
   queue.

Recovery normalizes stale in-progress rows without losing requested quality.
New-download capability gates never disable removal of already local data.
