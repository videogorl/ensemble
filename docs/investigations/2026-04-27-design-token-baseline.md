# Design Token Baseline

Date: 2026-04-27

## Purpose

This baseline captures the starting point for the Ensemble design-system token
pass. Phase 1 adds semantic tokens, material roles, and adaptive scaffolds.
Phase 2 should be a reviewed whole-app literal sweep, not blind replacement.

## Current Literal Inventory

Counts are broad `rg` matches across `Packages/EnsembleUI/Sources` and
`EnsembleWatch/Views`. They include token definitions added in Phase 1, so use
them as drift indicators rather than exact debt counts.

| Category | Count |
|---|---:|
| Font calls | 487 |
| Font weight calls | 62 |
| Foreground/tint calls | 506 |
| Accent color references | 135 |
| Numeric spacing arguments | 311 |
| Numeric padding arguments | 230 |
| Explicit corner radii | 65 |
| SF Symbol references | 472 |
| Geometry/breakpoint references | 137 |
| Effects/material/gradient references | 195 |

## First-Pass Migration Map

| Pattern | Decision |
|---|---|
| Track row sizing, row inset, mini-player clearance | Keep `TrackListLayoutMetrics`, bridged to `EnsembleDesign.Spacing` |
| Artwork corner radius | Keep `ArtworkCornerRadius`, bridged to `EnsembleDesign.Radius` |
| Card title/subtitle/metadata typography | Replace with `EnsembleDesign.Typography` |
| Shared grid/card spacing | Replace with `EnsembleDesign.Spacing` |
| Mini-player radius/shadow and common icons | Replace with `EnsembleDesign.Radius`, `Effect`, and `Icon` |
| Empty/loading/error presentation | Convert to `EnsembleStateScaffold` where behavior is generic |
| OS-adaptive filter behavior | Convert to `EnsembleScaffold.FilterPresentation` when each screen is touched |
| Liquid Glass/material fallback stacks | Convert to `EnsembleDesign.Material.Role` or documented custom material composition |
| Screen-specific geometry values | Ask before normalizing if the value changes layout behavior |
| Visual one-offs tuned for a specific surface | Keep local and document the reason |

## Phase 2 Review Gates

Stop and check with Felicity before changing:

- Conflicting icons for the same intent unless the app already has an established answer.
- Breakpoints that affect iPadOS/macOS pane behavior, toolbar placement, or Now Playing collapse.
- Material opacity/strength on prominent glass or aurora-adjacent surfaces.
- Values that are numerically close but produce visibly different rhythm, such as card gutters, chip heights, or detail hero spacing.
- Any literal that appears tuned to a performance-sensitive or platform-specific surface.

## Suggested Sweep Order

1. Library browse screens: Songs, Artists, Albums, Genres, Playlists, Favorites.
2. Detail screens: MediaDetail, artist/album/playlist detail sections, download detail.
3. Discovery: Home, Feed hubs, Search.
4. Account/settings/modals: Profile, Downloads, Add Plex Account, source settings.
5. Now Playing and external display.
