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
- App account/data state:

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

| ID | Severity | Confidence | Platform | Surface | Evidence | Fix report section |
|---|---|---|---|---|---|---|
| SWEEP-001 | P1/P2/P3 | High/Medium/Low | | | | |

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
- [ ] Artists
- [ ] Playlists
- [ ] Search
- [ ] More
- [ ] Songs
- [ ] Albums
- [ ] Genres
- [ ] Favorites
- [ ] Downloads
- [ ] Profile
- [ ] Mini-player
- [ ] Now Playing
- [ ] StageFlow/landscape where available

## iPad Checklist

- [ ] Cold launch/root chrome
- [ ] Sidebar
- [ ] Search
- [ ] Feed
- [ ] Songs
- [ ] Artists
- [ ] Albums
- [ ] Genres
- [ ] Favorites
- [ ] Playlists
- [ ] Pins/smart playlists where available
- [ ] Downloads
- [ ] Profile
- [ ] Mini-player
- [ ] Now Playing wide sheet
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
- [ ] Favorites
- [ ] Playlists
- [ ] Pins/smart playlists where available
- [ ] Downloads
- [ ] Profile
- [ ] Music source detail
- [ ] Add Plex Account
- [ ] Logs/settings subviews
- [ ] Mini-player
- [ ] Now Playing viewport
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
