---
name: app-policies
description: "Load only when Ensemble work may change a durable product, safety, privacy, offline, destructive-mutation, queue, cross-provider, or data-integrity contract. Not required for fixes that restore an existing contract or for implementation-only refactors."
---

# Ensemble Durable Policies

Policy is a product-invariant layer, not an implementation diary.

1. Load the single matching reference before changing a durable contract.
2. Follow the current invariant unless the user explicitly approves a behavior
   change.
3. Update policy only when the delivered result creates, removes, or changes the
   durable contract.
4. Do not update policy for a fix that restores it, a renamed owner, file move,
   refactor, callback/race mechanism, test command, cadence constant, or incident
   history. Put those facts in source, tests, architecture, or investigations.
5. Keep new policy bullets short, independently testable, and free of owner/file
   inventories. Keep each reference below 800 words; consolidate before growing
   past that limit.

## References

- [offline-and-connectivity.md](references/offline-and-connectivity.md): device
  and server availability, endpoint selection, cached/offline fallback.
- [downloads.md](references/downloads.md): offline targets, persistent queue,
  network constraints, quality, recovery, and artifact deletion.
- [playback-and-queue.md](references/playback-and-queue.md): logical queue,
  provider handoffs, availability, streaming, SmartMix, Watch playback.
- [sync-and-refresh.md](references/sync-and-refresh.md): last-good data,
  authoritative inventories, source cleanup, provider freshness, indexing.
- [mutations.md](references/mutations.md): exact-source mutations, offline replay,
  capability gating, playlist merging, optimistic convergence.
- [ui-platform.md](references/ui-platform.md): native platform ownership,
  scene-local navigation, persistent content, shared actions, Watch scope.

Use `testing` for proof, `architecture` for ownership, `ui-conventions` for UI
mechanics, `known-issues` for active limitations, and `plex-api` for endpoints.
