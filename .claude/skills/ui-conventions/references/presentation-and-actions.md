# Presentation And Actions

- Prefer native alerts for simple rename input and native sheets for create,
  filter, profile, downloads, and metadata editors. Use existing sheet navigation
  containers for OS fallbacks.
- Do not pre-hide root chrome, install global keyboard monitors, or add focus and
  dismissal delays. If a current reproduction proves a presenter conflict, fix
  the smallest owning presenter.
- Root auxiliary sheets use `auxiliaryPresentationSheets(...)` and the existing
  add-account host. Sheet-to-sheet handoffs store a pending target and continue
  from `onDismiss`.
- Actions and disabled reasons come from `MusicItemActionAvailability`, source
  capability contracts, and `MediaMenuCatalog`. Views must not infer provider
  permissions or branch directly on Plex/Apple Music.
- Build native table menus through `NativeMediaTableActionBuilder`; use
  `TrackActionsContextMenu` for standalone SwiftUI track cards. Parent views add
  only truly local handlers.
- Present add-to-playlist follow-up UI through
  `PlaylistActionPresentationHost`; do not duplicate picker payloads or recent
  playlist mutation logic.
- Track rows use the shared configured swipe layout and native table delegates.
  Do not restore custom SwiftUI swipe containers or give card/shelf interfaces
  row gestures.
- Global toasts are rendered once by the app-level host. Mutation workflows own
  success/failure semantics; screens only request feedback.
- Labels for actions that require more input end in the single ellipsis character
  `…`; immediate actions do not.
- Mini-player transport controls need explicit state-correct accessibility
  labels. Disabled actions remain visible when their context supports an
  explanatory reason.
- Use native commands and keyboard shortcuts. Do not install app-wide event
  swizzles or input monitors for ordinary shortcuts.
