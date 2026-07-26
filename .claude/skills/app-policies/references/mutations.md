# Mutations Policy

Load this reference for playlist changes, ratings/favorites, metadata edits/deletes, pins, downloads, drag/drop, scrobbles, offline queued mutations, toast policy, or cross-screen mutation feedback.

## Policies

- Shared workflows own cross-screen business rules. Views and view models keep presentation, navigation, local optimistic state, and confirmation UI.
- Offline-capable mutations should queue through the unified mutation path when the server is unavailable and replay when connectivity returns.
- Playlist deletion treats Plex `404 Not Found` as terminal convergence for that source: clear the queued mutation, the local cached playlist, and that playlist's owned composite artwork file through the normal success path, while preserving other HTTP failures for retry or user feedback. A playlist artwork fallback may reference a shared album asset; destructive playlist actions must not delete that shared fallback. Plex may also use `404` when the source credentials no longer have access, so diagnostics must describe the playlist as absent or inaccessible rather than claiming confirmed server deletion.
- Mutation feedback should be centralized in the workflow that owns the mutation, not duplicated per screen.
- Pin mutations are local reversible preferences and should stay intentionally quiet unless the user action needs explicit feedback. A merged Watch playlist is pinned when any constituent is pinned; its Unpin action removes every pinned constituent, while Pin from an unpinned group pins every constituent.
- Playlist mutation policy must be source-aware. Reject incompatible sources, smart targets, and duplicate tracks according to the shared resolver rules. The add-to-playlist picker and sidebar drop targets disable a destination that cannot accept every dragged item, including a different-server destination or a cached destination that already contains every compatible selected track. A merged sidebar playlist delegates to the first constituent in display order that can accept the drop and remains enabled when any constituent can; it is disabled only when none can. Exclude cached source-scoped target members before enqueuing. An all-duplicate selection is a warning/no-op, while an unavailable cache leaves Plex as the authority. A successfully persisted optimistic add immediately makes its concrete destination the recent add-to-playlist target, including sidebar drops and offline-queued adds. Persist Plex playlist item IDs, order, and display metadata independently from synced tracks so memberships from disabled libraries remain visible and removable/reorderable. Playback and download are unavailable only for those membership rows. Never rebuild a partially available playlist from its locally synced tracks.
- Metadata edit/delete flows use shared request construction and success/failure feedback while parent views own editor presentation and post-delete navigation.
- Rating/favorite changes may update UI optimistically, but server success/failure and queued-state feedback stay in the shared workflow.
- Scrobbles and playback tracking must remain source-exact and should not cross Plex source boundaries.

## Owners

- `MutationCoordinator` owns online/offline mutation queuing for ratings, playlist changes, and scrobbles.
- `SyncCoordinator.deleteRemotePlaylist` owns idempotent Plex playlist-delete convergence before `PlaylistMutationController` refreshes the local server cache.
- `PlaylistMutationWorkflow`, `TrackRatingMutationWorkflow`, `MetadataMutationWorkflow`, `PinMutationWorkflow`, and `DownloadMutationWorkflow` own their respective business rules and feedback.
- `PlaylistDropResolver` and `MediaTrackResolver` own drag/drop media expansion, source compatibility, target rejection, and dedupe.
- `MediaMenuCatalog` owns shared media menu action order, grouping, and destructive/editing gating.

## Implementation Hooks

- Route new row, card, detail, menu, and batch actions through the existing workflow or catalog before adding local mutation logic.
- Keep add-to-playlist follow-up UI in `PlaylistActionPresentationHost` rather than local sheet payloads.
- Keep destructive confirmations and post-delete navigation in the parent view, but keep mutation success/failure semantics in the workflow.
- Use source-scoped media references and identities for all Plex-affecting mutations.
- `PlaylistMutationController.editPlaylistItems` must use Plex item delete/move endpoints for playlist detail edits; `PlaylistDetailView` may optimistically edit the complete cached membership list.

## Verification

- Add focused workflow tests for success, failure, offline queued, and incompatible-source paths when mutation policy changes.
- Add UI or simulator evidence for new user-visible mutation flows, especially confirmation, toast, optimistic state, and post-delete navigation.
- Verify duplicate prevention and source compatibility for drag/drop and playlist mutations.
