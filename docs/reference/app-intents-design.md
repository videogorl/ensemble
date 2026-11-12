# App Intents design (2026-11-11)

Status: approved by Felicity on 2026-11-11, all six phases. Phases 1 to 3 are merged; phase 5 (the Mac) is built on
`feature/app-intents-mac` and awaits the manual Mac checks in the physical-device backlog; phases 4 and 6 are not
started. "What exists today" below describes the code before phase 1. Research sources are
listed at the end.

## Built (phases 1 to 3)

Layout, under `Ensemble/App/AppIntents/` (one set, compiled for iOS and macOS):

- `MediaEntities.swift`: `IndexItemEntity` and its query protocol, the song, album, artist, playlist and any-kind
  media entities (all built by `init(item: SiriMediaIndexItem)`; type names and id formats are persisted by saved
  shortcuts and must not change), the mood entity, and the index lookup.
- `PlaybackIntents.swift`: `EnsembleIntentError`, readiness (`readyContainer()` awaits
  `prepareForBackgroundPlayback`, shared with the Siri hand-off), Play Track, Album, Artist, Playlist (with a
  shuffle option), the hidden legacy Shuffle intents, Shuffle Library, Play Favorites, Play Recently Added, Play
  Mood, Start Track Radio.
- `NowPlayingIntents.swift`: Get Current Song, Favorite Current Song, Add Current Song to Playlist, Add to
  Playlist, Play Next, Play Last, Set Shuffle, Set Repeat, Set Autoplay, Set SmartMix, Play/Pause, Next,
  Previous.
- `ShortcutIntents.swift`: the three enum wrappers used by App Shortcut phrases (Play Collection, Playback
  Option, This Song). They call the same functions as the typed editor actions.
- `OpenAndShareIntents.swift`: Open Media, Get Ensemble Link. `FocusFilter.swift`: the Focus filter.
  `SystemSurfaces.swift` (iOS): Spotlight `IndexedEntity` and the iOS 27 now-playing relevant entity.
  `AppShortcuts.swift`: the provider.
- Core: `SiriPlaybackCoordinator` resolves any request once (play, enqueue, library, favorites, track radio) and
  throws when `PlaybackService` leaves a failed state; `LibraryCollectionTracks` loads mood and recently-added
  tracks (the Mood screen uses it too); `LibraryRepository.mapTracks` reads a library in bounded batches.

Playback intents are `AudioPlaybackIntent` and start without opening the app; a process started only for an
intent awaits account loading, health checks and provider registration first. Favorites and playlist adds use the
view model's optimistic paths.

App Shortcuts (9 of the limit 10; Apple recommends 2 to 5): Play Playlist, Play Album, Play Artist, Play Track,
Play Collection (favorites, shuffled favorites, shuffled library, recently added), Playback Option (shuffle,
repeat, Autoplay, SmartMix), This Song (favorite, unfavorite, start radio), Add This Song to Playlist, Open
Media. Every other intent is an editor action.

Mac (phase 5): nothing in `Ensemble/App/AppIntents/` was iOS-guarded except `SystemSurfaces.swift`; the Ensemble target
already builds for macOS and the extracted metadata lists all 30 actions, 7 entities and the provider on the Mac. What
changed: `SystemSurfaces.swift` is shared (Spotlight `IndexedEntityQuery` reindexing and the now-playing relevant entity
are `@available(iOS 27, macOS 27)`); `refreshSystemMediaSurfaces()` (App Shortcut parameters, Siri media context, the
shared index Shortcuts pickers read, Core Spotlight) runs after the Mac's startup health checks, as it does after the
iPhone's, because an unchanged library never signals a refresh; the entity picker's string search and saved
identifiers fall back to the bounded full-store search for songs, albums and artists the capped index does not hold.
App Shortcuts on macOS: the SDK declares `AppShortcutsProvider` and `AppShortcut` from macOS 13, `AudioPlaybackIntent`
from macOS 14 and `IndexedEntity` from macOS 15; Apple's HIG says nothing firm about the Mac, so the provider ships
unchanged and what the Mac surfaces (Shortcuts app, Spotlight) is a manual check. Left for the Mac: the headless
checks below.

Left for later: Play Genre (deferred by the owner; the genre loader is not in Core), phases 4 to 6 below.


## What exists today

- **SiriKit media extension** (`EnsembleSiriIntentsExtension`): play, add to playlist, and like/dislike by voice
  ("Play X on Ensemble"), on iPhone, HomePod, CarPlay and Watch routes.
- **Eight App Intents**, iPhone and iPad only (`Ensemble/App/EnsembleAppShortcuts.swift`, 950 lines): play track,
  album, artist, playlist; shuffle artist, playlist; open media; get link. All of them open the app to run.
- **Five App Shortcuts** (play track, album, artist, playlist; open media), which since 2026-11-11 suggest recent
  items and so appear in Shortcuts and Spotlight.
- **System integrations**: a Spotlight index of the library (`IndexedEntity`), the now-playing item published as a
  relevant entity (iOS 27), and one Focus filter.
- **Not there**: the iOS 27 audio schemas that Siri AI uses, any action on what is playing or on the queue,
  Control Center controls, widgets, and anything on the Mac.

## What others do and what Apple asks for

- No third-party player documents a full set. The best are Longplay (a Control Center "Album Shuffle" control,
  filterable Find, Siri play now / next / later) and Marvis Pro (interactive Now Playing and quick-action
  widgets). Apple's Music app offers Play Music, Add to Playlist, Create Playlist, Get Playlist, Add to Up Next
  (next or later), Get Current Song, Skip and Seek (names from third-party catalogues, not Apple's reference).
- Apple's guidance: offer 2 to 5 App Shortcuts (the limit is 10), one parameter per phrase, ordered by recency;
  prefer an app schema where a domain exists; mark playback intents `AudioPlaybackIntent` so they run in the
  background; index recent and favourite content rather than everything; give every Spotlight-visible intent a
  parameter summary.
- **Siri AI (iOS and macOS 27)** talks to music apps through the **audio schema domain**: a `playAudio` intent
  paired with a search query over `AudioSearch` (free text, a URL, or "play something"), entity schemas for song,
  album, artist, playlist and station, `playbackAttributes` (shuffle, repeat), `queueInsertionLocation` (next,
  last), and `addToPlaylist`, `addToLibrary`, `updateAudioAffinity`, `createStation` and `warmupAudioQueue`. Siri
  finds content through the Spotlight index, on-screen entity identifiers, and
  `MPNowPlayingInfoPropertyAppEntityIdentifiers` for the current song.
- Siri AI is an opt-in beta on iPhone 15 Pro or later, M1 iPads and Macs, in six languages, not in the EU on
  iPhone. HomePod does not have it, so SiriKit and App Shortcut phrases stay the route there.

## Proposed design

One set of entities and intents, shared by iPhone, iPad and Mac, with the schemas layered on top.

1. **Foundation.** Replace the five near-identical entity types (track, album, artist, playlist, media) and their
   repeated mapping code with four entities (song, album, artist, playlist) built from one index item
   initialiser. Split the 950-line file by role and compile it for macOS. Playback intents become
   `AudioPlaybackIntent` and run in the background where the engine allows, instead of always opening the app.
   The two Shuffle intents fold into a shuffle option on Play. *Disappears:* about a dozen copies of the mapping
   closure, the separate media entity, two intents.
2. **Now-playing and queue actions.** Get Current Song (returns the song entity, for automations), Favourite or
   unfavourite the current song, Add the current song to a playlist, Play Next and Play Last for any song or
   album, and set shuffle, repeat and autoplay. They call the same service methods the app's buttons use.
3. **More ways to start music.** Shuffle Library, Play Favorites, Play Recently Added, Play Genre, Play Mood, and
   Start Track Radio (the existing feature). App Shortcut tiles stay at about five: Play Playlist, Play Album,
   Play Artist, Shuffle Library, Play Favorites; everything else is an action in the editor.
4. **Siri AI audio schemas** (iOS and macOS 27 only, behind availability checks). The four entities adopt the
   audio entity schemas; `playAudio` plus an `AudioSearch` query reuse the existing Siri index matcher;
   `addToPlaylist`, `updateAudioAffinity` and `createStation` map to phase 2 and 3 actions; the now-playing info
   carries the entity identifier. The SiriKit extension stays for HomePod, older devices and Siri without AI.
5. **Mac** (built; see "Mac (phase 5)" above). The same actions in Shortcuts and in Spotlight on macOS 26 and later. No App Shortcut tiles are
   assumed there: Apple's guideline and its API page disagree on whether macOS supports them.
6. **Control Center controls and widgets.** A new widget extension target: controls for Shuffle Library and
   Favourite Current Song (Control Center, Lock Screen, Action Button), then an interactive Now Playing widget.
   This is the only phase that adds a target; it also needs the playback state shared with the extension.
   **Deferred (owner decision, 2026-11-11): not being built now.** Decided for when it is taken up: keep the
   iOS 17 floor and gate controls to iOS 18; the extension holds thin copies of the intents and the app's
   existing code does the work (no shared intents package). A first slice would be controls only (Play/Pause,
   Favourite Current Song) reading a small App Group now-playing snapshot. No Lock Screen widget was requested;
   the "Lock Screen" above means a control placed there, not a separate widget.

Suggested order: 1, 2, 3 (small, no new target, checkable on the iPhone SE through the Shortcuts app), then 4,
5, and 6 last.

## Risks and open questions

- **Siri AI reach.** Apple labels parts of this "Developer Preview", not available to App Store or external
  TestFlight builds. Whether the audio schemas are included could not be confirmed. Phase 4 may ship dormant.
- **SiriKit and schemas together.** Apple does not say which wins when an app has both. Developers report
  phrases breaking after Siri AI is enabled. Needs testing on the iPhone 16 Pro; the SE cannot run Siri AI.
- **Background playback from an intent.** Starting the engine without opening the app is unproven here; if it is
  unreliable, the intents keep opening the app (today's behaviour).
- **Suggested items and voice.** Suggestions were once off so Siri could not pick an unrelated item; see
  `ON_DECK.md`.
- **Mutations.** Favourite and add-to-playlist go through the existing mutation paths; no sync code changes, so
  the step 3 freeze is not touched.

## Verification

Unit tests with Apple's AppIntentsTesting for entity queries and intents; the Shortcuts app on the iPhone SE
through Device MCP for phases 1 to 3; Siri AI by voice on the iPhone 16 Pro and the Mac for phase 4; the built Mac
app for phase 5.

## Sources

Apple: Human Interface Guidelines for App Shortcuts and Siri; App Intents documentation for the audio schema
domain, `playAudio`, `AudioSearch`, "Making actions and content discoverable by Apple Intelligence", "Siri AI
Developer Preview", `AudioPlaybackIntent`, `ControlConfigurationIntent`; WWDC22 "Design App Shortcuts", WWDC25
session 260, WWDC26 sessions 240, 343, 345 and 8011; Apple support page 127893 (Siri AI availability). Others:
Spotify's "Siri and Spotify" support page, the Longplay and Marvis Pro App Store pages, Plexamp release notes,
Doppler's 2.3 notes, and developer forum threads 832602, 847230, 844294 and 829838.
