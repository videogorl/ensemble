---
name: common-tasks
description: "Load only for a matching Ensemble recipe: adding a ViewModel/view, CoreData entity, music source, hub, playlist mutation, download target, Siri/App Intent flow, or KVS sync feature."
---

# Ensemble Recipe Router

Inspect the existing neighboring implementation before using a recipe; source
code is authoritative when names have moved. Load only the reference matching
the requested addition:

- [views-and-navigation.md](references/views-and-navigation.md): new ViewModel,
  SwiftUI view, detail loader, large-screen browse surface, or Now Playing panel.
- [data-and-sources.md](references/data-and-sources.md): CoreData entity, hub,
  provider/source, visibility, filter, or sync trigger.
- [mutations-and-downloads.md](references/mutations-and-downloads.md): playlist
  mutation, drag/drop, menu/swipe action, or offline download target.
- [system-integration.md](references/system-integration.md): SiriKit, App Intents,
  Spotlight/system media, portable links, Watch package placement, or KVS.

Do not load this skill for ordinary edits to an existing owner. Reuse the
current service, repository, workflow, catalog, and factory rather than creating
a parallel path.
