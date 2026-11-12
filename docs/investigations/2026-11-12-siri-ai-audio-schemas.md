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
- The now-playing entity identifier: the property lives in the Core package's now-playing bridge, which does not know
  app entities, and needs a hook there plus a private `_MediaPlayer_AppIntents` import. Left until the phone shows
  whether Siri needs it (it already has the relevant-entity publisher).
- `.url` search criteria: Siri-supplied URLs are not Ensemble links, so the query returns nothing for them.
- `warmupAudioQueueResult` is a required `playAudio` parameter; Ensemble supplies a transient value and never reads it.

## Open questions for the phone

- Does Siri AI now route "add this song to playlist X" to Ensemble (look for `SIRI_AI: add-to-playlist`), and does it
  pick the song from the on-screen or now-playing context without the identifier property?
- Which wins when SiriKit and the schemas both exist.
- Does `playAudio` for a bare "play <playlist>" reach `values(for:)` on the playlist query, or only on the song query?
- Is an empty `artists` list on the song entity enough for Siri's disambiguation?
