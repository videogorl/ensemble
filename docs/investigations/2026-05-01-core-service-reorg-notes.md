# 2026-05-01 Core Service Reorg Notes

Core service file movement is intentionally deferred. This consolidation pass keeps `EnsembleCore` structurally unchanged so UI folder movement and shared UI contracts can be validated independently.

## Future Service Domains

- `Services/Playback`: playback facade, audio engine, queue, transport, session, recovery, prefetch, now-playing bridge, waveform/frequency analysis.
- `Services/Sync`: sync coordinator, sync execution, refresh orchestration, websocket sync, playlist refresh, periodic sync, network lifecycle.
- `Services/Downloads`: offline download service, target reconciliation, queue coordination, transfer execution, retry policy, cleanup, background execution.
- `Services/Account`: account manager, account discovery, profile/cloud sync, local-network permission probe.
- `Services/Library`: artwork loading, hubs, moods, visibility profiles, cache management, metadata mutation.
- `Services/Siri`: Siri playback, affinity, add-to-playlist, index store, user context.
- `Services/Sharing`: share service and song.link resolution.
- `Services/Infrastructure`: network monitor, server health, server connection controller, persistent logging, diagnostics, toast coordination.

## Suggested Migration Guardrails

- Move one service domain per commit after package tests pass.
- Keep public type names and dependency container construction stable during the first move.
- Update `architecture`, `project-structure`, and `common-tasks` as each service domain moves.
- Avoid touching `EnsembleAPI` and `EnsemblePersistence` layout during the Core service reorg unless a compile issue requires it.
