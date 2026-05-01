# 2026-05-01 Design Token Consolidation Baseline

Scope: `Packages/EnsembleUI/Sources`

Excluded: `.build`, `EnsembleWatch`

This baseline was captured before the project-wide consolidation behavior pass. The audit now separates raw literal inventory, tokenized usage, and tuned literal inventory for StageFlow, Aurora, and Now Playing surfaces.

## Summary Counts

| Category | Count |
|---|---:|
| Font calls | 322 |
| Font weight calls | 29 |
| Foreground/tint calls | 337 |
| Accent references | 35 |
| Numeric spacing | 1 |
| Numeric padding | 12 |
| Explicit corner radius | 5 |
| SF Symbol references | 383 |
| Geometry/breakpoints | 151 |
| Effects/materials | 138 |
| Raw literal inventory | 1398 |
| Tokenized usage | 2741 |
| Tuned literal inventory | 255 |

## Largest Raw Literal Domains

| Domain | Raw Hits |
|---|---:|
| `NowPlaying` | 160 |
| `Screens/AccountSettings` | 154 |
| `Utility` | 141 |
| `Screens/Library` | 140 |
| `DesignSystem` | 104 |
| `Screens/Downloads` | 102 |
| `TrackLists` | 87 |
| `Screens/Root` | 65 |
| `Screens/Discovery` | 62 |
| `PlaybackChrome` | 52 |

## Notes

- StageFlow, Aurora, and Now Playing tuned values are counted separately so future sweeps can avoid unintentional visual retunes.
- `DesignSystem` itself is expected to contain literal definitions; its count should be interpreted differently from screen/component domains.
- `Screens/AccountSettings`, `Utility`, `Screens/Library`, and `Screens/Downloads` are the highest-value follow-up domains for literal reduction after this consolidation pass.
