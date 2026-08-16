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
