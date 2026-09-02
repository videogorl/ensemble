# UI Platform Policy

- Root shells own platform navigation and persistent chrome: tabs on iPhone and
  native split/sidebar behavior on regular-width iPadOS/macOS. Navigation and
  auxiliary presentation are scene/window-scoped.
- Typed media routes append to the active scene stack. Feed/list refreshes do not
  pop a destination, opening a shared link does not start playback, and an
  existing macOS main window handles incoming navigation when available.
- Prefer native platform owners for tab/split navigation, sheets, keyboard,
  search, scrolling, toolbars, menus, tables, AirPlay, Metal, volume, and window
  behavior. Custom bridges are limited to capabilities SwiftUI does not expose.
- Persistent root/detail/list surfaces observe focused projections, not broad
  high-frequency managers. Root chrome changes only for scene geometry,
  presentation, keyboard, and explicit immersive state owned by the root.
- Cached browse/detail content remains mounted and interactive during refresh.
  Loading, error, offline, and true-empty decisions use shared scaffolds and do
  not replace last-good content with transient blank state.
- Alphabetic browse indexes stay bounded to A-Z plus `#`. Latin diacritics fold
  to their base letter; other scripts, numbers, and symbols share the final `#`
  section, while displayed titles remain unchanged.
- Shared menus/swipes use centralized action availability and retain unavailable
  actions with a reason where the context provides a handler. Views do not infer
  provider capabilities or source ownership.
- Artist-detail album sorting uses one option and direction for single-source
  details and every source section of a merged detail.
- Search pins are reordered by direct drag and removed from their context menu.
  A drag temporarily expands a collapsed pins grid and restores it after drop.
- Sharing quality is one preference used by Share Audio File and external audio
  drag export. It defaults to Original; a cached local file is reusable only when
  its recorded quality matches. Empty/incomplete exports are rejected and
  temporary files live long enough for receivers to finish reading.
- Portable Ensemble links contain descriptive metadata, never credentials or
  source IDs. They resolve only against enabled cached libraries and navigate
  without autoplay; unresolved links fail non-destructively into Search.
- File/library info may expose Plex media paths only outside Demo Mode. It does
  not mix static library metadata with live Now Playing/connection state.
- Artwork-backed surfaces use source/identity-scoped durable artwork and cached
  pre-rendered washes. A different media identity never displays the previous
  item's artwork as continuity, and live large-layer blur is not used. Remote
  failure retry state is scoped to the exact source asset identity and is reset
  by an identity change or Clear Artwork Cache.
- Root mini-player and Now Playing presentation remain persistent shared owners;
  leaf screens do not reproduce them. Covered root content is removed from hit
  testing/accessibility while a custom viewport presentation is active.
- Watch is a lightweight standalone Plex client plus optional phone remote, not
  an `EnsembleCore`/`EnsembleUI` client. Downloads are outside its current scope.
  Its catalog is cached/stale-while-revalidate, and one failed server does not
  hide healthy cached content.
- Watch album browsing, track details, Now Playing, Crown volume, toolbar
  placement, and list scrolling use their existing native/system owners. Custom
  gestures, page indicators, and manual Crown/scroll replacements are not added
  without an explicitly approved behavior change.
