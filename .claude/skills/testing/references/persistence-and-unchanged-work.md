# Persistence And Unchanged-Work Checks

## Multiple Sources And Large Collections

For cross-source, merged, download, Feed, or large-detail changes, use at least
two visible sources and exercise the largest available collection. If that
environment is unavailable, report the missing coverage.

When content doubles or a detail freezes, distinguish three costs:

- Persistent child rows: count memberships by their domain identity and source;
  inspect legacy duplicates separately from rows created during this run.
- Publication: count repeated equal snapshots and overlapping full loads.
- Rendering: correlate track-list updates with the same interaction window.

A fetch before insert is not atomic across Core Data contexts. Trace overlapping
fetch-then-insert and delete-and-replace writers; serialize at the owning writer
or enforce suitable persistent uniqueness. Identity must preserve legitimate
playlist occurrences and exact-source copies. Do not blindly deduplicate by
track ID or merge display identity.

Verify the fix with the affected overlapping-write case and current-build
runtime evidence. A clean store alone does not prove legacy-store recovery;
read-time deduplication alone does not prove writes stopped creating duplicates.
Do not erase user data to make the reproduction disappear.

## Repeat With Unchanged Inputs

For sync, indexing, artwork, or browse-publication changes, establish a warm
baseline, repeat the same operation without changing inputs, then apply one
material change. Inspect only the affected owner:

| Owner | Unchanged pass | Material-change pass |
|---|---|---|
| Sync/persistence | No unnecessary replacement writes or concurrent full loads | Correct source-scoped delta and last-good retention on failure |
| Siri/Spotlight | No unnecessary shared-index rewrite or duplicate vocabulary registration | Expected updated/deleted items are published |
| Artwork | No repeated encoding or durable writes for unchanged identity/size | Changed artwork reaches the current item; stale work cannot replace it |
| Browse | Equal large snapshots do not republish or trigger repeated full projections | The affected visible result updates |

Account for scheduled healing, invalidation, and explicit refresh policy before
calling work redundant. If a daily full republish is due, repeat afterward to
exercise the unchanged path. Use existing logs, counters, store queries, and
focused tests; add instrumentation only when those cannot distinguish the work.
Compare matching build/device/data and interaction windows. Simulator timing is
directional, and fewer operations alone do not prove physical energy savings.
