# Sync And Refresh Policy

- Feed and library surfaces are offline-first: publish cached/last-good data
  immediately and refresh without blanking it. Failed or empty remote results do
  not replace a usable snapshot.
- Bootstrap/no-source/disabled/empty decisions come from settled readiness, not
  transient account, provider, hub, playlist, or row arrays. Credential and
  discovery failures preserve provisionally scoped cache until explicit removal.
- Provider data and identity remain source-scoped. Apple Music is an iOS/iPadOS
  18+ device-local source and does not enter KVS, CloudKit, Plex credential sync,
  or Watch library payloads.
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
- Siri/Spotlight indexing is source-scoped, coalesced, and material-change-only.
  No-op syncs do not rewrite an identical shared index; bounded healing remains
  available for lost system state.
- Nonessential sync, indexing, artwork healing, and analysis yield to launch,
  navigation, playback, requested downloads, thermal pressure, and constrained
  devices. User-requested data/playback work remains eligible.
