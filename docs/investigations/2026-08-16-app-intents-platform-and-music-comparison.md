# App Intents Platform And Apple Music Comparison

Date: 2026-08-16

## Scope And Evidence Rules

This note covers Apple's public App Intents and media-intent capabilities plus first-party Apple Music behavior that is either documented by Apple or directly observable on the local Mac. It does not treat a visible Siri or Shortcuts action as proof of which private framework Apple used to implement it.

Evidence labels:

- **Documented**: current Apple Developer or Apple Support documentation.
- **Direct observation**: read-only inspection on macOS 26.6.1 (25G76), Music 1.6.6, Shortcuts 7.0, and the selected stable Xcode 26.6 toolchain (iPhoneOS 26.5 SDK). These observations are a point-in-time snapshot, not a public compatibility contract.

## Platform Capabilities

| Surface | Documented capability | Availability / caveat | Practical implication |
|---|---|---|---|
| Shortcuts and Siri phrases | `AppIntent`, `AppEntity`, and `AppShortcutsProvider` publish actions and content to the system. App Shortcuts are installed with the app and combine an intent with a title, symbol, phrases, and optional preconfigured parameters. Apple recommends shortcuts for only the most common actions: usually 2–5 and no more than 10. | App Intents and App Shortcuts start on iOS 16. Ensemble still needs an iOS 15 fallback where applicable. | Prefer a small, useful shortcut set. Do not mirror every app screen or every internal command. |
| Existing Siri media domain | SiriKit's Media domain supports play, search, add-to-library/playlist, and update-affinity requests. Apple says an intents extension should resolve and verify playback, then hand the request to the app because an extension is too short-lived to play media. Donated `INPlayMediaIntent` interactions can power Siri suggestions. | This remains the documented, shipped media integration for the OS range Ensemble currently supports. A visible Siri media action is not necessarily an App Intents-framework action. | Preserve one shared resolver and playback handoff behind the SiriKit handlers instead of duplicating search or playback logic in each entry point. |
| Playback intents | `AudioPlaybackIntent` tells the system an App Intent changes audio playback so system dialogue does not interrupt it. When used by an interactive widget, the system runs it in the app process. | iOS 17+. This protocol is narrower than the SiriKit Media domain; by itself it does not provide semantic song, album, artist, or playlist search. | Apply it to App Intents that actually start, pause, or alter playback; do not use it as a replacement for media resolution. |
| Foreground and background execution | `AppIntent.supportedModes` declares whether an action runs in the background, foreground immediately, or starts in the background and transitions dynamically or before completion. Runtime `systemContext` reports the current mode and whether continuing in the foreground is possible. | iOS 26+. `openAppWhenRun` is deprecated; Apple directs apps to `supportedModes`. Older deployment targets still need an availability-compatible declaration. | Classify each intent by what it truly requires. Keep non-UI work in the background and request a foreground transition only when the action needs app UI or user attention. |
| Spotlight entities | `IndexedEntity` connects an app entity to Core Spotlight. Indexed content becomes searchable, linkable back into the app, and easier for Siri to locate. Apple requires the index to be kept current. | iOS 18+. `IndexedEntityQuery` is iOS 27 beta; apps already supporting Core Spotlight reindexing do not need it. | Index bounded, durable nouns such as playlists. Add, update, and delete index rows with the source data; never let the index become an independent database. |
| Controls and widgets | WidgetKit controls are buttons or toggles placed in Control Center, the Lock Screen, the Action button, and other system locations; their action is an App Intent. A `ControlConfigurationIntent` describes configurable control parameters. | Controls and `ControlConfigurationIntent` start on iOS 18. | Add only app-specific controls whose action is useful when Ensemble is not already playing. Standard playback controls belong to the Now Playing / remote-command integration. |
| Standard playback controls | `MPNowPlayingInfoCenter` publishes track and playback metadata to the Lock Screen, Control Center, AirPlay, and accessories. `MPRemoteCommandCenter` is the documented stable path for play, pause, next, previous, seek, shuffle, repeat, like, dislike, and related system or accessory commands. | Shipped APIs. Apple's new Swift `NowPlaying` framework is iOS 27 beta. Neither stable surface is an App Intent. | Do not build duplicate Control Center intents for ordinary playback commands. Make the existing Now Playing state and remote commands complete and reliable first. |
| Rich results | Intent results may return dialog, values, or SwiftUI snippet views. Entity `DisplayRepresentation` supplies title, subtitle, and artwork used in results, disambiguation, Spotlight, and Shortcuts. | Snippet intents start on iOS 26; basic result/dialog/display support predates them. Voice-only devices still need a complete spoken response. | Prefer accurate entity display data and short results. Add custom snippets only where plain system presentation is inadequate. |

Sources: [App Intents framework](https://developer.apple.com/documentation/appintents), [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts), [Accelerating app interactions with App Intents](https://developer.apple.com/documentation/appintents/acceleratingappinteractionswithappintents), [SiriKit Media](https://developer.apple.com/documentation/sirikit/media), [`INPlayMediaIntentHandling`](https://developer.apple.com/documentation/sirikit/inplaymediaintenthandling), [`AudioPlaybackIntent`](https://developer.apple.com/documentation/appintents/audioplaybackintent), [`supportedModes`](https://developer.apple.com/documentation/appintents/appintent/supportedmodes), [deprecated `openAppWhenRun`](https://developer.apple.com/documentation/appintents/appintent/openappwhenrun), [Spotlight integration](https://developer.apple.com/documentation/appintents/spotlight), [WidgetKit Controls](https://developer.apple.com/documentation/widgetkit/controls-collection), [`ControlConfigurationIntent`](https://developer.apple.com/documentation/appintents/controlconfigurationintent), [`MPNowPlayingInfoCenter`](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter), [`MPRemoteCommandCenter`](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter), and [interactive widgets and Live Activities](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities).

## Apple Music: Documented User Surface

Apple documents a broad Siri vocabulary for Apple Music:

- play a named song, album, artist, playlist, radio station, decade, or genre;
- select music by mood, activity, lyrics, or personal recommendation;
- favorite or dislike the current song and ask for similar music;
- identify the current song, artist, or album;
- add the current song or album to the library or a named playlist;
- pause, resume, skip, change volume, and shuffle.

This breadth should be read as a user-experience benchmark, not an App Intents API inventory. Apple does not document which requests use private Music implementation, SiriKit Media, App Intents, MediaPlayer, or another system path. See [Play music and podcasts with Siri](https://support.apple.com/guide/iphone/iph905254b46/ios).

Apple also documents composability in Shortcuts: after `Get Current Song`, Shortcuts suggests actions such as `Add to Playlist` and `Get Details of Music`. That is the valuable pattern to copy: media-producing actions return structured media that media-consuming actions accept. See [Navigate the action list in Shortcuts on Mac](https://support.apple.com/guide/shortcuts-mac/navigate-the-action-list-apdc33e4f4da/mac).

## Apple Music: Direct Observations

### Shortcuts 7.0

Searching for `Music` in the Shortcuts action library exposed these Music-shaped actions:

- `Select Music`
- `Play Music`
- `Find Music`
- `Get Details of Music`
- `Import Audio Files into Music`
- `Create Playlist`
- `Add to Playlist`
- `Get Playlist`
- `Clear Playing Next`
- `Get Current Song`
- `Add to Playing Next`

The same search also returned generic media and store actions, so search membership alone does not prove that every result is owned by Music. The observation does show the first-party product shape: separate find/get/play/create/add/queue verbs that can be chained, rather than one large action with many modes.

### Installed Music 1.6.6 Metadata

Read-only binary and resource inspection found:

- the Music executable dynamically links public `AppIntents`, private `_AppIntents_AppKit`, and `MediaPlayer` frameworks;
- every inspected localization contains `AppIntents.strings`;
- the English error catalog contains explicit failure paths for adding entities to the cloud library or a cloud playlist, downloading an unsupported artist, locating entities and playlists, deleting library items, sharing a playlist, changing the search source, navigating, and opening the mini-player or full screen;
- binary strings include `AppIntentsBacking` entry points for adding entities, optionally downloading them after adding, and adding entities to a specified playlist.

These observations prove that this Music build contains App Intents-backed code. They do not provide a complete action list, establish OS availability, or prove that the similarly named Siri and Shortcuts actions all use that code.

Reproduction commands:

```sh
mdls -name kMDItemVersion -name kMDItemCFBundleIdentifier /System/Applications/Music.app
otool -L /System/Applications/Music.app/Contents/MacOS/Music
plutil -p /System/Applications/Music.app/Contents/Resources/en.lproj/AppIntents.strings
strings -a /System/Applications/Music.app/Contents/MacOS/Music | rg 'AppIntentsBacking|APPINTENTS_ERROR'
```

### Spotlight And Controls Caveat

No primary Apple source or local metadata inspected here provides an Apple Music-specific App Intent inventory for Spotlight or user-placeable WidgetKit controls. Apple documents the general system capabilities, and Apple Music participates in standard Now Playing controls, but neither fact proves a Music-specific App Intent on those surfaces. Do not use an undocumented Apple Music behavior as an Ensemble requirement.

## Ensemble Implementation Audit

### Current Surface

The iOS app currently emits nine App Intents and six entity types:

| Area | Current implementation | Audit |
|---|---|---|
| App Shortcuts | Play Track, Album, Artist, and Playlist; Open Media | Five is a sensible count, but four playback shortcuts duplicate the same operation and four parallel entity/query types. |
| Other App Intents | Get Ensemble Link; two hidden Shuffle intents | Get Link is a useful composable action. The hidden Shuffle intents are not referenced by the shortcut provider or elsewhere and should be deleted unless a current system route is proven to require them. |
| Focus | Playback & Libraries `SetFocusFilterIntent` | Distinctive and well-scoped. Keep it. |
| SiriKit Media | Play, Add Media, and Update Affinity in an intents extension | Correctly preserves iOS 15 support and the system media domain. Playback has substantial resolution, disambiguation, and main-app handoff logic. |
| Shared content | Source-scoped JSON media index, Spotlight publication, Siri vocabulary, interaction donation | Strong foundation: one shared resolver, stable cross-source identity, material-change writes, and live Core Data revalidation before playback. |

The stable Xcode 26.6 build succeeded and generated `Metadata.appintents` without App Intent validation errors. The metadata confirms that all nine App Intents are shipped, including the two non-discoverable Shuffle intents. It also confirms that the playback and open actions still use the deprecated foreground-launch declaration rather than explicit iOS 26 execution modes.

### What Is Already Strong

- The shared media resolver handles typed search, ranking, source scoping, equivalent-item deduplication, and SiriKit disambiguation instead of making each entry point invent its own matching behavior.
- Playback is revalidated against live Core Data before execution, so a stale shared index is not treated as authoritative.
- The system-media publisher avoids rewriting an unchanged index and updates Spotlight incrementally.
- The generic `EnsembleMediaEntity` already represents songs, albums, artists, and playlists and carries the metadata needed for portable links. It is the natural canonical entity for future App Intents.
- The Focus Filter is a genuinely app-specific system integration rather than a duplicate of an in-app screen.

### Reliability Findings

#### P0: Add-to-playlist and affinity can report success before anything happened

The SiriKit extension writes each request to one fixed App Group file, posts a Darwin notification, and immediately returns `.success`. The main app then deletes the file before execution and suppresses coordinator errors with `try?`. Darwin notifications are transient and do not provide durable launch or acknowledgement semantics. If Ensemble is suspended or terminated, the user can hear success while the mutation is never applied; a later request can also replace the single pending file.

The mutation coordinators compound this by treating invalid schema, no current track, and playlist-not-found as successful `Void` returns after showing an in-app toast. The extension therefore cannot distinguish completion, queued-offline success, and failure.

Recommendation: do not add a custom queue yet. Use the same foreground/`NSUserActivity` handoff pattern as playback and return success only after the main-app coordinator reports a typed outcome. If the system cannot keep that execution alive reliably, temporarily remove these two SiriKit handlers rather than retain false success. Add a durable queue only if app-terminated testing proves the foreground handoff insufficient.

#### P0: Advertised Siri phrases exceed implemented behavior

The vocabulary advertises “Add this album to my favorites” and “Like this album,” but the handlers always operate on the current track; Add Media always targets a playlist. Remove those examples immediately. The Siri usage description should also say that Ensemble can play and update music or playlists, not only play them.

#### P1: Open Media has an unconditional success response

`OpenEnsembleMediaIntent` returns “Opening…” even when no destination can be formed, and ignores whether routing happened immediately or was merely queued for a future scene. Return a failure dialog for an invalid/stale entity and describe a queued open honestly. The index identifier should remain a hint; live existence must be checked before claiming success.

#### P1: Entity discovery is search-only and may be stale

Every media query returns an empty `suggestedEntities()` list. Users can type a search, but the parameter picker starts empty and Spotlight/Siri have fewer useful candidates. The App Intent query also loads the full shared JSON without the one-hour freshness check used by `SiriMediaIndexStore`.

Return a small, stable suggestion set—recent/favorite tracks and playlists first—and reject or refresh stale index data. Do not simply expose all 4,500 indexed items.

The index caps also introduce selection bias: artists and playlists are alphabetically sorted before their 1,500/500 caps, and albums are sorted by artist/year before their 1,500 cap. Large libraries can therefore exclude entire later alphabetic ranges. Rank a bounded set by user relevance before raising any cap; measure misses before increasing memory or file size.

#### P1: Playback declarations lag the current platform

Playback App Intents should conform to `AudioPlaybackIntent` on iOS 17+ so system speech does not interfere with starting audio. On iOS 26+, replace `openAppWhenRun` with the narrowest truthful `supportedModes`; keep an availability-compatible fallback for iOS 16–25. Most successful playback should not require presenting Ensemble's UI.

### Simplification

The current file contains four parallel media entity/query pairs, four parallel Play intents, two Shuffle variants, and a newer generic entity. This is more surface than the user-visible behavior requires.

Use the existing `EnsembleMediaEntity` and source-scoped identifier as the single media value. Replace the four Play intents with one `PlayEnsembleMediaIntent(media:shuffle:)`, where shuffle is a simple optional `AppEnum` or Boolean only if Shortcuts needs to configure it. Keep separate App Shortcuts phrases for song, album, artist, and playlist only if phrase resolution measurably benefits; they can feed the same intent and entity type. Delete the hidden Shuffle intents and the four kind-specific entity/query types after migrating existing shortcuts safely.

Keep these distinct because they are different verbs with different results:

- Play Media
- Open Media
- Get Ensemble Link
- Playback & Libraries Focus Filter

Do not create App Intents for play/pause/next/previous/seek/shuffle-state/repeat-state. Those already belong to `MPRemoteCommandCenter`, and duplicating them creates a second playback-control contract.

### Apple Music Comparison

| Capability | Apple Music surface observed/documented | Ensemble today | Best next move |
|---|---|---|---|
| Find/select media | Find Music and Select Music produce typed music values | Entity parameters support typed string search, but there is no value-producing Find action and suggestions are empty | Add one Find Ensemble Media action returning the canonical media entity. |
| Inspect/current item | Get Current Song and Get Details of Music | No App Intent result for current track; entity metadata exists internally | Add Get Current Ensemble Track. Let entity properties satisfy most details before adding a separate details action. |
| Play | One Play Music consumer accepts music input | Four play-by-kind consumers | Consolidate to one Play Media consumer. Keep SiriKit's semantic media resolver for natural voice. |
| Playlist mutation | Create Playlist and Add to Playlist accept inputs | SiriKit Add acts only on the implicit current track and has unreliable delivery | First make delivery honest; later add an App Intent that accepts explicit media plus a playlist. Do not build Create Playlist unless real workflows need it. |
| Queue | Add to Playing Next and Clear Playing Next | No composable queue actions | Consider Add to Queue only after Find and Current Track exist. Standard skip/seek remain remote commands. |
| Portable sharing | No equivalent observed in the inspected Music action set | Get Ensemble Link returns a URL | Keep it; this is a useful Ensemble-specific advantage. |
| Focus behavior | No relevant Music action observed | Library visibility and scrobble override | Keep it; this is another differentiated integration. |

Apple Music's advantage is not a larger phrase file. Its useful actions form a small typed pipeline: find or get a song, inspect it, then play it or pass it to a playlist/queue action. Ensemble already has the source-scoped media model needed to build the same shape with fewer types.

### Recommended Delivery Order

1. **Make existing mutations truthful:** correct vocabulary; replace transient success with an acknowledged main-app result; stop suppressing execution failures.
2. **Delete duplication:** one canonical media entity/query and one Play intent; remove the hidden Shuffle intents; adopt `AudioPlaybackIntent` and availability-gated execution modes.
3. **Make selection useful:** bounded recent/favorite suggestions, freshness handling, and relevance-based index selection.
4. **Add only two composable producers:** Find Ensemble Media and Get Current Ensemble Track. Have Play, Open, Get Link, and a later explicit Add to Playlist consume their result.
5. **Extend to macOS cautiously:** expose useful Shortcuts actions such as Find, Open, and Get Link from shared code; do not duplicate transport controls.
6. **Evaluate iOS 27 separately:** prototype the beta audio schemas behind availability checks after the stable SDK ships, reusing the same entity, resolver, and coordinators. Do not replace SiriKit while iOS 15–26 remain supported.

### Verification Matrix

Existing resolver, playback coordinator, and system-media publication tests are useful and should stay. Add only one focused check around the mutation handoff/outcome boundary and one generated-metadata assertion if consolidation risks silently dropping shortcuts.

System verification should cover the seams that unit tests cannot prove:

- Shortcuts parameter picker with no query, typed query, duplicate names across sources, and a stale/deleted item;
- playback with Ensemble foregrounded, backgrounded, terminated, offline, and locked;
- add-to-playlist and affinity with the app terminated, no current track, an unavailable server, and two rapid requests;
- Siri on phone and HomePod/AirPlay, explicitly separating resolution success from actual playback or mutation completion;
- Spotlight and Shortcuts after a library rename, deletion, source disable, and index rebuild.

This audit did not execute those device scenarios. The build and local Shortcuts catalog were verified; background, locked-device, Siri, HomePod, and AirPlay behavior remain code-level findings until exercised on current hardware.

## iOS 27 Audio Schemas: Future Direction, Not Current Baseline

Apple's iOS 27 beta introduces an App Schema audio domain with `playAudio`, `addToLibrary`, `addToPlaylist`, `createStation`, `recognizeAudio`, `updateAudioAffinity`, and `warmupAudioQueue`. The Media Intents framework supplies structured `AudioSearch`; an app implements `IntentValueQuery` to map that request to its own audio entities.

Apple's WWDC26 CosmoTunes example is especially relevant:

- index the bounded local playlist set in Spotlight;
- do not pre-index a large, frequently changing song catalog;
- resolve songs on demand through `IntentValueQuery<AudioSearch>`;
- use the system `searchInApp` schema to hand a query to the app's own search UI;
- annotate the current song, artist, and playlist on the Now Playing session, most specific first;
- validate in stages: isolated `AppIntentsTesting`, then Shortcuts, Spotlight, and finally Siri.

All of this is preliminary iOS 27 technology. The public symbol metadata marks the audio schemas iOS 27 beta, and the selected stable Xcode 26.6 toolchain contains only the iPhoneOS 26.5 SDK and cannot build them. It should guide future model boundaries, not trigger a production migration now.

Sources: [Audio App Schema domain](https://developer.apple.com/documentation/appintents/app-schema-domain-audio), [Responding to audio search and playback requests](https://developer.apple.com/documentation/mediaintents/responding-to-audio-search-and-playback-requests), [Integrating your music app with Apple Intelligence](https://developer.apple.com/documentation/appintents/integrating-your-music-app-with-apple-intelligence), and [WWDC26: Explore advanced App Intents features](https://developer.apple.com/videos/play/wwdc2026/343/).

## Recommendations To Apply During The Ensemble Audit

1. **Optimize for 2–5 excellent App Shortcuts, not Apple Music parity.** Choose the actions people most need outside the app. Keep the remaining intents available to Shortcuts only when they are useful building blocks.
2. **Make media actions composable.** A current-track or find-media action should return the same narrow, source-scoped media entity consumed by play, queue, playlist, and open actions. Avoid separate string parsers for each verb.
3. **Keep one resolver and one execution path.** SiriKit handlers and App Intents should translate their inputs, then call the same media resolution, queue, playback, and mutation owners used by the app. The system-facing types should stay thin.
4. **Keep the shipped SiriKit Media layer while Ensemble supports iOS 15.** Use App Intents for discoverability and custom actions, and mark playback-changing App Intents as `AudioPlaybackIntent` on iOS 17+. Reconsider consolidation only after the iOS 27 audio schemas ship and Ensemble's deployment floor permits it.
5. **Replace the old launch boolean with explicit execution modes where available.** On iOS 26+, use `supportedModes` to express background-only, immediate-foreground, dynamic, or deferred-foreground behavior. Do not open Ensemble merely because the intent was invoked.
6. **Use Spotlight selectively.** On iOS 18+, index a bounded set of durable entities such as playlists with source-stable identifiers, useful title/subtitle/artwork, and a direct open route. Do not mirror the full Plex track catalog into Spotlight without evidence that its size and refresh behavior are acceptable.
7. **Do not duplicate standard transport controls.** Playback metadata belongs to `MPNowPlayingInfoCenter`; play/pause/skip/seek/shuffle/repeat belong to `MPRemoteCommandCenter`. A WidgetKit control is justified only for an Ensemble-specific action that remains useful when another app is the Now Playing app.
8. **Treat iOS 27 as an additive experiment.** When a final SDK is available, prototype the audio schemas around the existing shared resolver, use query-backed songs and indexed playlists, and compare behavior on Siri, Shortcuts, and Spotlight before replacing anything.
9. **Test the seams, not every phrase.** Verify entity identity and display, ambiguous resolution, no-match behavior, locked/background handoff, app-not-running playback, offline/unavailable servers, and exactly-once mutation. Then run a short system-surface matrix. Apple's future `AppIntentsTesting` framework can replace some manual setup once it is shippable.

## Comparison Standard

The fair target is not “support every phrase Apple Music supports.” Apple's public documentation does not expose Apple Music's implementation boundaries, and its visible behavior may span SiriKit Media, App Intents, MediaPlayer, and private system code. The useful standard is:

- users can discover Ensemble's few best actions immediately;
- the same media object flows cleanly between find, inspect, play, queue, and playlist actions;
- Siri resolves the same source-scoped content as the app;
- playback and mutations behave identically whether initiated in the app, Shortcuts, Siri, Spotlight, or a control;
- failures are explicit, fast, and do not corrupt queue, library, or playlist state.
