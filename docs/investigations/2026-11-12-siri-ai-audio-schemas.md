# Siri AI audio schemas (2026-11-12)

Motivating defect (device console, iPhone 16 Pro, iOS 27.3, Siri AI): "Add this song to playlist ZZ Test Voice" never
reached an Ensemble process. Siri AI's own `AudioAppIntentsExtension` ran an `AudioEntityIntentValueQuery` and answered
"couldn't find a playlist". Siri AI finds audio apps through the audio schema domain, not SiriKit.

## What the SDK provides

Found in the iPhoneOS 27.1 SDK: `AppIntents.framework/.../AppIntents.swiftinterface` (lines about 11205 to 11440),
`MediaIntents` (`AudioSearch`), `MediaPlayer/Headers/MPNowPlayingInfoCenter.h`, `_MediaPlayer_AppIntents.swiftinterface`;
shapes confirmed from the Xcode documentation search and, for required properties, from `appintentsmetadataprocessor`
errors (the compiler does not check them; the extraction step does, and reports each missing property).

- All of it is `@available(anyAppleOS 27.0, *)`, unavailable on watchOS and tvOS.
- Macros: `@AppIntent(schema: .audio.<name>)`, `@AppEntity(schema: .audio.<name>)`, `@AppEnum(schema: .audio.<name>)`.
  The macro only adds the conformance (`AssistantSchemaIntent` / `AssistantSchemaEntity`) carrying the availability of the
  type it is attached to. It cannot go on an existing iOS 17 type, and one entity adopts one schema.
- Intent schemas: `addToLibrary`, `addToPlaylist`, `createStation`, `playAudio`, `recognizeAudio`, `updateAudioAffinity`,
  `warmupAudioQueue`. Entity schemas: song, album, artist, playlist, songCollection, stations, podcasts, audiobook,
  and more. Enum schemas: `playbackAttributes` (shuffle, repeat), `queueInsertionLocation` (next, tail), `affinityState`
  (like, dislike, unset), `activity`, `invocationSource`, `appViewIdentifier`.
- Required properties, as the extractor reports them (optional ones must still be declared):
  - song: `title`, `artistName`, `artists: [Artist]`, `album: Album?`, `albumTitle`, `composerName`,
    `composers: [Artist]`, `internationalStandardRecordingCode`.
  - album: `title`, `artistName`, `artists`, `universalProductCode`. Artist: `name`.
  - playlist: `title`, `owner` (a `@UnionValue` of `IntentPerson | String`), `createdByMe`, `curatedForMe`.
  - A property computed in a protocol extension does not count; each must be declared on the type.
- `addToPlaylist`: parameters `audioEntity` and `playlist`. `audioEntity` must be a `@UnionValue` over schema entities
  (any subset of the listed audio entity schemas). No other parameter was required.
- `playAudio`: `audioEntity` (union), `playbackAttributes: Set<PlaybackAttributes>`, `warmupAudioQueueResult` (a
  schema entity, which must be a `TransientAppEntity`, `IndexedEntity` or have a query), `queueLocation`; marked
  `AudioPlaybackIntent`. `createStation` has no parameters.
- Search: `MediaIntents.AudioSearch` with `criteria` of `.searchQuery(String)`, `.url([URL])` or `.unspecified`. An
  entity's query conforms to `IntentValueQuery` and implements `values(for: AudioSearch) -> [Entity]`.
- Now playing: `MPNowPlayingInfoPropertyAppEntityIdentifiers` (iOS and macOS 27) takes `MPAppEntityIdentifier`
  (`_MediaPlayer_AppIntents`, `init?(entityIdentifier: EntityIdentifier)`).

## What was adopted (`Ensemble/App/AppIntents/AudioSchemaIntents.swift`)

- Four thin entities (song, album, artist, playlist) built by the same `init(item:)` and queried by the same
  `IndexItemEntityQuery`, so saved-shortcut types and identifiers are untouched.
- Each query also answers `AudioSearch` through `SiriIndexLookup.findItems` / `recentItems`, the existing matcher and
  visible-source scope (merging, hidden sources, Focus), after `restoreFocusFilter()`, failing closed.
- `addToPlaylist`: calls `add(_:to:)`, the function Add to Playlist uses (`addTarget` for the song's own server,
  "different music sources" error, smart playlists read-only). `playAudio` plays through `EnsembleMediaEntity.play` and
  enqueues next or last through `enqueue`; repeat sets repeat all. `createStation` starts the track radio from what plays.
- Each intent logs `SIRI_AI:` lines at entry and outcome (kind and flags public, names private).

## Not adopted

- `updateAudioAffinity`: Ensemble has favorite and unfavorite but no dislike, so "I don't like this song" has nothing
  to map to; adding half the enum would make the intent throw on a valid Siri value.
- `addToLibrary`, `warmupAudioQueue`, `recognizeAudio`, station and podcast entities: no equivalent action.
- `.url` search criteria: Siri-supplied URLs are not Ensemble links, so the query returns nothing for them.
- `warmupAudioQueueResult` is a required `playAudio` parameter; Ensemble supplies a transient value and never reads it.

## Open questions for the phone

- Does Siri AI now route "add this song to playlist X" to Ensemble (look for `SIRI_AI: add-to-playlist`), and does it
  pick the song from the on-screen or now-playing context without the identifier property?
- Which wins when SiriKit and the schemas both exist.
- Does `playAudio` for a bare "play <playlist>" reach `values(for:)` on the playlist query, or only on the song query?
- Is an empty `artists` list on the song entity enough for Siri's disambiguation?

## Follow-up after the first phone run (2026-11-12)

- "this song" resolved to the previous song: Siri reads the playing song from the now-playing info, which had no entity
  identifier. `MPNowPlayingInfoPropertyAppEntityIdentifiers` (MediaPlayer header, iOS/macOS/watchOS/tvOS 27) takes an
  `NSArray` of `MPAppEntityIdentifier`, built in `_MediaPlayer_AppIntents` as
  `MPAppEntityIdentifier(entityIdentifier: EntityIdentifier(for: entity))` (failable). The app builds it for
  `EnsembleSongAudioEntity` (so the identifier equals the entity's `id` and `entities(for:)` hydrates it) and hands it to
  `PlaybackNowPlayingBridge` through a closure (`PlaybackService.setNowPlayingAppEntityIdentifiers`); Core stays free of
  app types. Installed once by `installNowPlayingEntityIdentifiers()`, called from `prepareForBackgroundPlayback` (every intent or Siri hand-off, scene or not) and from the publisher's `start()`; iOS/macOS 27 only.
- Prompt updates: `updateNowPlayingInfo()` runs on every queue advance, load, play and pause path and publishes whenever
  the state differs, and the state includes the track; a track change therefore republishes at once (read from the call
  sites, not measured on a device). A stale title is not the cause of the symptom.
- Kind words in the search text ("focus playlist"): `SiriMediaIndexResolver.kindWordQuery(from:)` reads a leading or
  trailing kind word; the schema search returns nothing for another kind's query and searches this kind's without the
  word, unless the whole text exactly matches a name of the queried kind. The shared matcher already offers a
  trailing-word-stripped variant for every kind, which is why "focus playlist" scored 0.84 against the artist "Focus On
  The Family Radio Theatre" (see ON_DECK.md).
- A duplicate add: `add(_:to:)` called the optimistic add, which filters duplicates silently, so the intent reported
  "Added". It now reads the playlist's current members from its server (`SyncCoordinator.liveMembers`, the playlist list
  and body reads a sync uses, 4 s timeout), sends only tracks not already members, and says "already in" only when all
  compatible tracks are. A cached membership is never proof: offline, a failed read or a timeout means unknown, and
  everything is sent as before.

## `playAudio` withdrawn (2026-11-12, second phone run)

`playAudio` was built, run on the iPhone 16 Pro and removed. Siri AI chooses one entity kind per request, differently
each run, and queries only that kind, so a bare name cannot be resolved across kinds from the app. Session log:

```
"Play my focus playlist in Ensemble":
  audio search kind=track query='focus playlist' found=0
  entities matching kind=track query='focus playlist' found=1      (the unguarded entities(matching:) path)
  play-audio kind=track name='Focus on Sight'
"Play the playlist focus in Ensemble":
  audio search kind=album query='focus' found=1
  play-audio kind=album name='Lofi Vineyard: Chill Worship Beats to Focus and Relax - EP'
"Play focus in Ensemble" (the previous round played the playlist via kind=playlist):
  audio search kind=artist query='focus' found=2
  play-audio kind=artist name='Focus On The Family Radio Theatre'
"Play Lord Huron in Ensemble" (an artist; worked the previous round via playlist then artist):
  audio search kind=album query='Lord Huron' found=0   (four times), nothing played
```

Before phase 4 these went to the SiriKit extension, whose single cross-kind resolver played the merged "focus"
playlist. With `playAudio` gone they do again. Kept: `addToPlaylist` (passed on the phone: the right playing song once
the now-playing identifier was published, and a duplicate reported as already in), `createStation`, the four schema
entities and their queries (`addToPlaylist` needs the entities and the playlist query). The metadata step required
nothing else from `playAudio`; the action count went from 33 to 32. The kind-word guard now covers
`entities(matching:)` as well as `values(for: AudioSearch)`.

To bring `playAudio` back, one of these would have to be true: Siri queries every kind (or honours an unspecified-kind
query) for a bare name; or one schema entity type can span kinds so a single query ranks across them. Neither can be
shaped from the app today.

## `playAudio` restored with cross-kind answers (2026-11-12, third phone run)

Withdrawing `playAudio` broke add: on `64fc7c43` Siri AI no longer ran our playlist `AudioSearch` ("couldn't find a
playlist named ZZ Test Siri AI"; only `entities for ids kind=track` logged) and said Ensemble does not support
creating stations. Siri AI evidently needs `playAudio` to exist before it uses the app's audio entities at all. So
`playAudio` is back, and the kind Siri chooses is made irrelevant:

- The song, album and artist queries (`values(for: AudioSearch)` and `entities(matching:)`) answer from every kind with
  `SiriPlaybackCoordinator.rankedMatches` (the assembly and ranking `executePlayUnspecifiedKind` also uses), the top
  match when it clearly wins (`SiriMediaIndexResolver.topPicks`, the extension's 0.1 gap), else up to three, wrapped in
  the queried type. `Entity(item:)` carries the real item and `perform()` plays `item.kind`, so an album-typed
  entity wrapping the playlist "focus" plays the playlist. A kind word in the text ranks that kind only.
- The playlist query stays playlists only (it is the add destination); `addToPlaylist` refuses a destination that is
  not a playlist.
- Schema entity identifiers now carry the real kind: `kind||ratingKey||source` (`AudioSchemaEntity`), parsed by
  `SystemMediaReference`; `entities(for:)` hydrates over all kinds. The now-playing identifier uses the same format.
  Saved-shortcut entities are untouched.
- Unverified on a phone: whether Siri accepts an album-typed entity that plays a playlist, and what it says.

## Withdrawn 2026-11-12

The Siri AI schema intents were removed from the app after six phone builds (iPhone 16 Pro, iOS 27.3, typed Siri).
Siri AI's own behaviour is the unreliable part: it queries one entity kind per request, a different one each run.

| Build | What it had | Play | Add and others |
| --- | --- | --- | --- |
| `202611120727` | schema play and add, per-kind answers | right 2 of 5 (wrong artist for "my focus playlist", nothing for "the playlist focus") | add reached our intent but added the previous song |
| `202611120752` | kind-word guard | right 0 of 4 (song, album, artist, nothing) | add 2 of 2, including "already in" |
| `202611120806` | no `playAudio` | via SiriKit right 4 of 5 ("Play focus" got a Siri error) | add 0 of 2 ("couldn't find a playlist", no Ensemble call); create station "isn't supported" |
| `202611120844` | cross-kind answers | right 7 of 9 ("Play focus" played the loaded song twice) | add 2 of 6 attempts; Siri once claimed it created the playlist; create station unsupported |
| `202611120906` | plus playlist-word guard | right 4 of 6 (one went to another app, one "Audio output is unavailable") | add 0 of 4; Siri created "ZZ Test Siri AI" in Apple Music and added there |

Removed: `AudioSchemaIntents.swift` (schema entities, queries, the play, add and station intents), the now-playing
app-entity-identifier plumbing, `SiriPlaybackCoordinator.currentlyVisible`, the kind-word and top-picks helpers. Play
stays with the SiriKit extension; voice add on Siri AI phones is not supported (Siri answers it itself). Kept: the
duplicate handling of the Add to Playlist and Add Current Song to Playlist Shortcuts actions (live server membership,
proven-identity suppression, the "already in" dialog).

The full work is parked on branch `parked/siri-ai-audio-schemas` at `24cc5782` (not pushed). Retry only when a later
iOS 27 build has Siri query the playlist kind for add destinations reliably, or Apple documents how Siri AI chooses the
entity kind.
