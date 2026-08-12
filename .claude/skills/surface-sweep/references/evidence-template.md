# Surface Sweep Evidence Template

Use this structure for the final notes file in the artifact root, usually `surface-sweep-notes.md`. Pair it with `fix-report.json` when findings need agent follow-up.

```markdown
# Ensemble Surface Sweep

Run ID:
Date:
Commit:
Artifact root:

## Environment

- iPhone simulator:
- iPad simulator:
- macOS:
- Physical device and OS:
- Source commit and installed app version:
- Enabled providers:
- App account/data state:

## Provider Evidence

| Journey | Provider | Library/catalog scope | Playback engine | Audio proof | Remote result | Local result | Cache before/after |
|---|---|---|---|---|---|---|---|
| | | | | heard/system progress/log only | | | |

## Plex Mutation Convergence

| Mutation | App lifecycle | Plex before/after | Ensemble convergence | Latency | DB/files/log/UI evidence | Cleanup |
|---|---|---|---|---:|---|---|
| Library add | foreground/cold | | | | | |
| Track metadata edit | foreground/cold | | | | | |
| Album metadata edit | foreground/cold | | | | | |
| Downloaded-playlist add/remove/re-add | foreground | | | | | |
| Downloaded track removal | foreground/cold | | | | | |
| Unchanged target poll | foreground | unchanged | no artwork/reconciliation/full inventory | | | n/a |
| Failed/incomplete inventory | automated stub | invalid/incomplete | last-good preserved | | | n/a |

## Build Results

- iPhone build:
- iPad build:
- macOS build:

## Coverage Summary

| Platform | Status | Screens touched | Screens blocked | Artifact folder |
|---|---|---:|---:|---|
| iPhone | | | | |
| iPad | | | | |
| macOS | | | | |

## Findings

| ID | Severity | Confidence | Policy status | Platform | Surface | Evidence | Fix report section |
|---|---|---|---|---|---|---|---|
| SWEEP-001 | P1/P2/P3 | High/Medium/Low | matches/contradicts/missing/unclear | | | | |

## Policy Review

| ID | Status | Policy reference | Platform/surface | Observation | Follow-up |
|---|---|---|---|---|---|
| POLICY-001 | Contradiction/Missing/Unclear | `app-policies/references/...` or `missing` | | | |

## Repro Index

| ID | Repro route | Screenshots | UI dumps | Logs | Verification after fix |
|---|---|---|---|---|---|
| SWEEP-001 | | | | | |

## Runner Reports

- iPhone:
- iPad:
- macOS:

## iPhone Checklist

- [ ] Cold launch/root chrome
- [ ] Feed
- [ ] Feed contextual actions/navigation
- [ ] Artists
- [ ] Playlists
- [ ] Search
- [ ] More
- [ ] Songs genre chips, filters, and bottom scroll
- [ ] Albums
- [ ] Genres
- [ ] Favorites sorting/filtering
- [ ] Downloads
- [ ] Profile
- [ ] Add-to-playlist sheets
- [ ] Go-to contextual navigation
- [ ] Mini-player spacing/position
- [ ] Now Playing controls/queue/history/lyrics/info
- [ ] Lyrics scroll/blur behavior where available
- [ ] Aurora/accent propagation and restoration
- [ ] StageFlow/landscape where available
- [ ] Provider-aware source, browse/sort, search/cache, mutation, playback, and system-integration journeys where available
- [ ] Explicitly authorized disposable Plex mutation convergence and cleanup, when in scope

## iPad Checklist

- [ ] Cold launch/root chrome
- [ ] Sidebar root/detail collapse-expand
- [ ] Search
- [ ] Feed
- [ ] Songs genre chips, filters, and bottom scroll
- [ ] Artists
- [ ] Albums
- [ ] Genres
- [ ] Favorites sorting/filtering
- [ ] Playlists
- [ ] Pins/smart playlists where available
- [ ] Downloads
- [ ] Profile
- [ ] Add-to-playlist popovers/sheets
- [ ] Go-to contextual navigation
- [ ] Mini-player root/detail/sidebar spacing
- [ ] Now Playing wide sheet controls/queue/history/lyrics/info
- [ ] Queue bottom and History panel
- [ ] Lyrics scroll/blur behavior where available
- [ ] Aurora/accent propagation and restoration
- [ ] Regular-width sheets/popovers

## macOS Checklist

- [ ] Cold launch/root chrome
- [ ] Sidebar
- [ ] Search
- [ ] Feed
- [ ] Songs native table
- [ ] Artists
- [ ] Albums
- [ ] Genres
- [ ] Favorites sorting/filtering
- [ ] Playlists
- [ ] Pins/smart playlists where available
- [ ] Downloads
- [ ] Profile
- [ ] Music source detail
- [ ] Add Plex Account
- [ ] Logs/settings subviews
- [ ] Add-to-playlist windows/sheets
- [ ] Go-to contextual navigation
- [ ] Mini-player spacing/position and resize
- [ ] Now Playing viewport controls/queue/history/lyrics/info
- [ ] Queue bottom and History panel
- [ ] Lyrics scroll/blur behavior where available
- [ ] Aurora/accent propagation and restoration
- [ ] App/View/Playback menus
- [ ] Window resizing

## Blocked Or Skipped

| Platform | Surface | Reason | Residual risk |
|---|---|---|---|
| | | | |

## Risky Actions Not Completed

- Account removal:
- Playlist deletion:
- Clear cache/data:
- Mass download mutations:
- Credential submission:

## Generated Fix Report

- JSON path:
- Markdown path:
- Findings promoted:
- Needs recheck:
```
