---
name: app-policies
description: "Canonical Ensemble behavior policy router. Load before changing app behavior, playback, queue, offline/connectivity, downloads, sync/refresh, mutations, platform UI behavior, or verification expectations; update the relevant policy reference when implementation changes or clarifies behavior."
---

# Ensemble App Policies

This skill is the policy-first entry point for behavior-changing work. It does not replace `architecture`, `ui-conventions`, `code-style`, `testing`, `known-issues`, or `plex-api`; it tells agents which app behavior contract must be followed or updated before implementation is handed back.

## Policy-First Workflow

1. Identify whether the task changes user-visible behavior, app lifecycle behavior, data freshness, playback/queue behavior, offline behavior, mutation semantics, platform UI behavior, or verification expectations.
2. Load the relevant policy reference below before editing code.
3. If a policy exists, implement within it unless the user explicitly asks to change the behavior.
4. If implementation requires a new or changed behavior, update the relevant policy reference in the same logical change.
5. If policy and implementation disagree, do not silently choose one. Reconcile the policy, the code, and tests together.
6. Keep policy docs concise: record durable behavior, owners, implementation hooks, and verification. Put historical incident detail in `docs/investigations/`.

## Reference Routing

| Reference | Load when changing... |
|---|---|
| [offline-and-connectivity.md](references/offline-and-connectivity.md) | Device offline state, per-server health, connection selection, track availability, WebSocket fallback, source availability |
| [downloads.md](references/downloads.md) | Offline download targets, queue scheduling, retry/fallback, background execution, quality refresh, recovery, download UI status |
| [playback-and-queue.md](references/playback-and-queue.md) | Playback start semantics, queue order, shuffle/repeat/autoplay, offline queue filtering, local-file playback, recovery |
| [sync-and-refresh.md](references/sync-and-refresh.md) | Feed/library freshness, stale-while-revalidate, pull-to-refresh, background refresh, WebSocket-triggered sync |
| [mutations.md](references/mutations.md) | Playlist, rating, metadata, pin, download, drag/drop, scrobble, or offline queued mutation behavior |
| [ui-platform.md](references/ui-platform.md) | Platform navigation, native UI ownership, cached-content stability, detail surfaces, utility screens, watch behavior |
| [testing-and-verification.md](references/testing-and-verification.md) | Policy-aware test selection, simulator proof, performance gates, documentation verification |

## Update Rules

- Update a policy reference when a change creates, removes, or clarifies durable behavior that future agents must preserve.
- Do not update policy for purely mechanical refactors that preserve existing behavior.
- Keep one source of truth per rule. If another skill contains operational details, summarize the policy here and point agents to that skill for implementation mechanics.
- Use `known-issues` for active limitations and fragile watchlist items. When an active limitation becomes durable intended behavior, move or summarize the durable rule here.
- Use `architecture` for package/service ownership changes. Use this skill for how the app should behave.
