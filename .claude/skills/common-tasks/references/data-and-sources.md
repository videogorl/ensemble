# Data And Source Recipes

## CoreData Entity

1. Update the model under `EnsemblePersistence/Sources/CoreData`.
2. Add the managed object, domain model, mapper, and owning repository behavior.
3. Run `scripts/compile_coredata_model.sh` before persistence tests.
4. Preserve source-scoped identity and never use the shared production stack in
   tests.

## Hubs

Providers implement `MusicSourceSyncProvider.getHomeHubs(limit:)` and map
semantic kind, scope, identity, and ranking fields at their boundary.
`HomeHubLoader` alone merges and persists the combined last-good snapshot.
Search reads that cache; it must not create a second provider fetch/save path.

## Music Source

Add the provider/type/configuration, register it with the existing coordinator,
publish it through the provider-neutral source configuration, and opt into only
the capabilities it truly supports. Map provider models at the boundary and use
source-scoped durable identities for media, artwork, mutations, and playback.
Shared UI/ViewModels must not receive a provider client or infer permissions.

## Visibility And Filters

Visibility is device-local browse filtering, not source enablement. Key it by
full source identity and apply it after repository loads. Reuse
`MediaFilterEngine`, a named configuration, `FilterPersistence`, and
`MediaFormatters`; do not build per-screen filter or formatting copies.

## Sync Triggers

Use the current `SyncCoordinator`, `BackgroundRefreshCoordinator`, and
`HomeHubLoader` entrypoints. Full sync is for explicit setup/repair;
incremental refresh is routine. WebSocket events accelerate the same owners and
must not become the only correctness path.
