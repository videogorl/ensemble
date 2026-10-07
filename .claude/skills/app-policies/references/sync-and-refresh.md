# Sync And Refresh Policy

- Feed and library surfaces are offline-first: publish cached/last-good data
  immediately and refresh without blanking it. Failed or empty remote results do
  not replace a usable snapshot.
- Watch persists normalized source, media, playlist, and Home rows in its own
  Core Data store. Launch may read only Home rows before loading the full catalog;
  Watch artwork uses the shared source-scoped durable artwork cache.
- Bootstrap/no-source/disabled/empty decisions come from settled readiness, not
  transient account, provider, hub, playlist, or row arrays. Credential and
  discovery failures preserve provisionally scoped cache until explicit removal.
- Provider data and identity remain source-scoped. Apple Music authorization,
  tokens, enablement, caches, playback state, and library payloads remain device
  local. Exact typed Hidden references may sync through private CloudKit only.
- Merge choices and preferred library order sync as one KVS preference. Watch
  consumes that preference without exposing management controls or publishing defaults.
- Each provider maps normalized hubs and metadata at its boundary.
  `HomeHubLoader` alone merges, globally orders, and saves the combined Feed
  snapshot; Search reads it rather than creating a second fetch/save path.
- A partial multi-provider refresh accepts successful provider data and retains
  last-good data for failed providers. Same IDs from different exact sources are
  distinct; aliases of the same physical item may be reconciled without losing
  provider-actionable identity.
- Destructive orphan cleanup requires a complete authoritative inventory. Every
  page must agree on boundaries/total, and an inventory that would remove data
  must satisfy the owning safety check. Failure, incompleteness, malformed data,
  or unavailable credentials preserves rows and files.
- WebSocket events accelerate exact-item reconciliation but are safe to miss.
  Cold start, foreground/background lifecycle, polling, manual refresh, and
  periodic authoritative reconciliation remain correctness paths.
- iOS Background Refresh persists outstanding enabled sources before remote work.
  Expiration, interruption, and provider failure retain that handoff for cold
  launch and foreground recovery. A source clears only after its committed data
  has completed the awaited Siri catalog and existing offline-target follow-ups.
  An unavailable configuration never clears outstanding work as if no sources exist.
- Background attempts use cooperative deadlines and preserve incremental cursors;
  successful sources remain committed when another source cannot finish.
  Authoritative inventory and deletion safety requirements still apply.
- Cursors capture the query start boundary and commit only after success.
  Overlapping writes remain monotonic so a later completion cannot skip changes
  made during an earlier request.
- Source cleanup occurs only after explicit account/library removal or explicit
  cache clearing. It rejects new source writes, drains in-flight source/server
  leases, rechecks restoration, and publishes completion only after exact-source
  rows, artifacts, downloads, and pending mutations are safely reconciled.
- Source restoration during cleanup cancels destructive completion and resyncs
  the restored source. Cleanup failure remains visible/retryable and never
  masquerades as success.
- Durable artwork is source-scoped. Sync pre-caches detail-usable media artwork;
  invalidation and orphan cleanup cannot stale or delete another source's asset.
  A server-limited smaller image remains valid until its source identity changes.
- Provider mutations update the exact local row optimistically and protect it
  from older concurrent sync snapshots until authoritative reconciliation.
- Siri catalog publication is source-scoped, coalesced, material-change-only,
  and eligible in background. Spotlight acknowledges its own applied snapshot
  only after all required deletion and indexing work succeeds; foreground
  catch-up retains outstanding updates even after the Siri catalog has changed.
- On iOS 27+, Now Playing relevance exposes only the current source-scoped track and removes it when playback has no current track.
  No-op syncs do not rewrite an identical shared index; bounded healing remains
  available for lost system state.
- Nonessential sync, indexing, artwork healing, and analysis yield to launch,
  navigation, playback, requested downloads, thermal pressure, and constrained
  devices. User-requested data/playback work remains eligible.
