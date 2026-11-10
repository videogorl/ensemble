# Web client and CloudKit settings design

Status: planning. Felicity approved decisions 1 to 3 on 2026-11-10 (section 8);
no implementation until she says to start. Written 2026-11-10 against
`402c9c03` on `develop`. Not part of the rearchitecture plan; schedule it
after step 3 closes (section 7).

## 1. Goal

A browser version of Ensemble, in the spirit of [Bear's web app](https://web.bear.app/),
that shares the user's Ensemble settings with the native apps through iCloud
and plays music from Plex directly.

The web app runs as a static single-page app on Cloudflare Pages (free tier),
with no backend. The browser talks to two services:

- **CloudKit**, through CloudKit JS, for Ensemble's synced settings.
- **Plex**, through its HTTP API, for sign-in, the library, and streams.

Out of scope for the first release: offline downloads, gapless playback,
Siri, the watch, and editing Plex playlists. These can follow.

## 2. What blocks this today

Ensemble syncs through three iCloud stores. Only one is reachable from a browser.

| Data | Store today | Owner | Web reachable |
|---|---|---|---|
| Profile name and photo | CloudKit private database, default zone, `UserProfile` / `currentUserProfile` | `CloudSyncService` | Yes |
| Hidden media | CloudKit private database, default zone, `HiddenMediaState` / `currentHiddenMediaState` | `CloudSyncService` | Yes |
| Accent color, swipe layout, Now Playing actions, pins, library flags, merging preferences | iCloud key-value store, keys in `EnsembleKVSKey` | `KVSSyncService`, `CloudSyncCoordinator`, `WatchCloudPreferenceStore` | **No** |
| Plex account credentials | iCloud Keychain, synchronizable items | `KeychainService` | **No**, by design |

So the prerequisite is moving the six key-value settings into CloudKit. That
also removes key-value store limits the native apps live with today: 1 MB
total, no change tags, and whole-value last-writer-wins.

Credentials stay in iCloud Keychain. The web app signs in to Plex on its
own (section 5.2) and keeps its token in the browser. Plex tokens are never
written to CloudKit.

## 3. CloudKit record design

### 3.1 One zone, one record per setting

Create one custom zone, `EnsembleSettings`, in the private database of
`iCloud.com.videogorl.ensemble`. It holds:

| Record type | Record name | Fields |
|---|---|---|
| `SyncedSetting` | The existing `EnsembleKVSKey` string, e.g. `ensemble.sync.pins` | `payload` (String), `schemaVersion` (Int64), `modifiedAt` (Date/Time) |
| `UserProfile` | `currentUserProfile` | Unchanged fields, moved into the zone |
| `HiddenMediaState` | `currentHiddenMediaState` | Unchanged fields, moved into the zone |

Reasons:

- **One record per setting** mirrors the key-value store exactly, so every
  existing encoder, decoder, and merge function is reused as is. Eight
  records in all; no finer split is needed.
- **A custom zone** is required for change tokens, database subscriptions,
  and `CKSyncEngine`. Moving the two existing records in fixes a suspected
  bug: the existing `CKDatabaseSubscription` does not fire for default-zone
  changes, so remote profile edits may only arrive on the next pull (see
  `ON_DECK.md`).
- **`payload` as a JSON string, not bytes**, keeps records readable in the
  CloudKit Console and in CloudKit JS without base64 handling.

### 3.2 The JSON contract

`payload` holds the same JSON the key-value store holds today, produced by
the existing `Codable` types. The web client must decode those shapes
exactly, so this note is their contract:

| Setting | Swift type |
|---|---|
| `accentColor` | Plain color-name string such as `blue` (not JSON; the key-value store holds it as a string) |
| `swipeLayout` | `TrackSwipeLayout` |
| `nowPlayingActions` | `NowPlayingSecondaryLayout` |
| `pins` | `[PinnedItem]` (the watch reads the subset `WatchPinnedReference`) |
| `libraryFlags` | `[EnsembleLibraryFlagEntry]` |
| `mergingPreferences` | `EnsembleMergingPreferences` |
| Hidden media | `[HiddenMediaMutation]` |

Pitfall: Swift's default `JSONEncoder` writes `Date` values as seconds since
2001-01-01, not Unix time. The web client adds `978307200` when decoding
`pinnedDate`, `modifiedAt` and similar fields, and subtracts it when
encoding. The exception is `EnsembleLibraryFlagEntry.updatedAt`, a raw
`TimeInterval` that its writers set from `timeIntervalSince1970`, so it is
already Unix seconds.

Any change to these types is now a change to a cross-client contract: bump
`schemaVersion`, and have readers ignore unknown fields and reject (not
overwrite) a newer major version.

### 3.3 Conflicts and deletion safety

- Writes use the server change tag. On `serverRecordChanged`, re-read, merge,
  and retry, as `pushHiddenMedia` already does.
- Settings with a merge function keep it: library flags use
  `EnsembleLibraryFlagPolicy.merged`, hidden media uses `mergeHiddenMedia`.
  The rest stay whole-value last-writer-wins, the same as today.
- An empty value is written as an explicit empty payload (for pins, `[]`),
  never as a deleted record. A missing record means "not migrated yet", and a
  failed fetch means "unknown". Neither one ever clears local data.

### 3.4 Synced sources list

So a new device or the web app can show which sources the user has and which
still need signing in, add one more `SyncedSetting`:
`ensemble.sync.sources`, a JSON array with one entry per source:

| Field | Meaning |
|---|---|
| `serverSourceKey` | `provider:accountID:serverID`, the existing `EnsembleSourceScope` key |
| `provider` | `plex` or `appleMusic` |
| `accountDisplayName` | What the account row shows, e.g. the Plex username |
| `serverName` | The server's display name, when the provider has servers |
| `addedAt` | When the source was added |
| `removedAt` | Set when the user removes it; `null` while active |

It holds no tokens or credentials. Sign-in always happens on the device.

Behavior:

- Settings shows every listed source with its state on this device:
  signed in, or a **Sign in** button that starts that provider's flow
  (Plex PIN sign-in, prefilled for the account where Plex allows it, or
  MusicKit authorization for Apple Music). After sign-in the device matches
  the result to the entry by account ID.
- Only an explicit removal by the user sets `removedAt`. A device that is
  not signed in to a source, or fails to reach it, never removes it. Entries
  merge per `serverSourceKey`, newest change wins, like library flags.
- On native, Plex accounts already arrive through iCloud Keychain (the
  existing **Sources** sync feature, `bootstrapSources`), so the list mostly
  helps the web app and Apple Music, which is authorized per device. The
  Keychain path stays: it carries the tokens, and this list never does.
- The per-feature sync switches in `SyncSettingsManager` (Sources, Hidden
  items, and the rest) keep working: a switched-off feature neither sends
  nor applies its record.

## 4. Native migration

### 4.1 Transport

Adopt `CKSyncEngine` for the `EnsembleSettings` zone. It is available on
iOS 17, macOS 14 and watchOS 10, so it fits every floor. It replaces the
hand-written subscription, fetch, and retry code in `CloudSyncService`, and
the plan already lists it for evaluation. If it proves heavier than eight
records warrant, the fallback is plain fetch-by-ID plus a database
subscription on the zone.

Why the current code is hand-written: `CloudSyncService` was written on
2026-04-06, when the floors were iOS 15 and macOS 12, and `CKSyncEngine`
needs iOS 17 and macOS 14. The floors were raised on 2026-10-13.

What `CKSyncEngine` changes for reliability:

- Unsent changes are queued and retried by the system. Today nothing is
  lost either, because local state persists, but a failed push waits for
  `CloudSyncCoordinator`'s own retry schedule (`firstConnectRetryDelays`),
  the next foreground, or a manual refresh. `CKSyncEngine` replaces that
  bootstrap and retry machinery.
- It creates the zone and the subscription, follows change tokens, and backs
  off on rate limits and quota errors, replacing the hand-written
  `nextProfilePullAllowedAt` throttle.
- It reports iCloud sign-out and account switches as events.
- Conflicts are still ours: it reports a `serverRecordChanged` failure and
  we merge with the existing functions (section 3.3).
- The system decides when automatic syncs run, which can lag by seconds or
  more. The app calls `fetchChanges` on foreground and `sendChanges` after a
  user edit when it needs the change to go out promptly.
- It needs its state saved between launches. Losing that state only causes
  a full re-fetch of eight records, so the cost is small.

`KVSSyncService` is deleted at the end of the migration, along with the
key-value store observer on the watch.

### 4.2 Steps

1. **Seed.** On first launch of the new build, for each setting whose
   CloudKit record is missing, copy the key-value store value into CloudKit.
   Copy `UserProfile` and `HiddenMediaState` from the default zone into
   `EnsembleSettings` the same way. If a record already exists, CloudKit
   wins and the key-value value is merged where a merge function exists.
2. **Switch reads and writes** on iPhone, iPad and Mac to CloudKit.
3. **Watch.** `WatchCloudPreferenceStore` reads the same zone through
   `CKSyncEngine` and keeps its last snapshot locally, so launch stays
   synchronous.
4. **Remove** the key-value store code, the seed path, and the default-zone
   records after one release. Removing the seed path is safe once every
   device has run a migrated build; there is only one user today, so this
   is a short window.

### 4.3 Native verification

- Change each setting on iPhone; it appears on Mac and the watch.
- Seeding: a device with only key-value data ends up with matching CloudKit
  records, and nothing is cleared when CloudKit is unreachable at launch.
- Conflict: concurrent library-flag edits on two devices merge per entry.
- Physical iPhone and watch checks go in `physical-device-backlog.md`.

## 5. Web client

### 5.1 Stack

- Vite and TypeScript, built to static files in `web/dist`.
- Svelte for the UI.
- CloudKit JS, loaded from Apple's CDN.
- hls.js for Plex transcode streams outside Safari.
- Local cache in IndexedDB, treated as disposable.

### 5.2 Sign-in

- **iCloud:** CloudKit JS "Sign in with Apple ID", using a web API token
  created in the CloudKit Console for the production environment, with the
  site's origin in the token's allowed origins.
- **Plex:** Plex's PIN sign-in flow (create a PIN, send the user to Plex's
  auth page, poll for the token), then list servers from plex.tv's
  resources endpoint. The `plex-api` skill has the endpoint details.

### 5.3 Library

The browser calls Plex servers directly over their `*.plex.direct` HTTPS
addresses; Plex servers send CORS headers. Chrome asks the user before a
public site reaches a home-network address, so the onboarding screen explains
that prompt and prefers the remote address when local access is refused.

The library cache is rebuilt from Plex like the native apps do, using paged
requests. Safari may delete a site's data after 7 days unused, unless the
site is installed to the home screen, so nothing in the cache is
authoritative.

### 5.4 Playback

- Direct file streams through an `<audio>` element. FLAC plays in current
  Safari, Chrome and Firefox.
- Plex universal transcode (HLS): native in Safari, hls.js elsewhere. Both
  paths stay supported, as on native.
- Media Session API for lock-screen, keyboard and headset controls.
- Known gaps: gapless playback, reliable background playback on iPhone
  Safari, offline downloads.

### 5.5 Settings

Read and write the `EnsembleSettings` zone with CloudKit JS: fetch zone
changes with a saved sync token on launch and on window focus, and write
with the record change tag (section 3.3). Live updates through CloudKit JS
notifications are optional for the first release.

Hidden items sync like every other setting. The web app reads the
`HiddenMediaState` record and filters hidden albums, artists, playlists and
tracks out of every list, search and shuffle, matching on the identity's kind,
item ID and source key. Hiding or unhiding on the web writes a
`HiddenMediaMutation` the native apps pick up. That record holds every hide
ever made in one JSON array, so it has a size ceiling of CloudKit's 1 MB per
record, roughly several thousand entries; split it per source if it nears that.

## 6. Repository and hosting

**Same repository, in a top-level `web/` folder.**

The two clients share no code; they share the CloudKit contract in section 3.
Keeping them together means a contract change, its Swift writer, and its
TypeScript reader land in one commit and one review, and agents see both
sides. The costs are small and handled:

- **Cloudflare Pages** builds from `web/` as its root directory, with build
  watch paths limited to `web/**`, so Swift commits do not use builds.
- **Agent guidance:** a short `web/CLAUDE.md` covers the web toolchain. The
  root guide's Xcode rules don't apply inside `web/`.
- **Xcode** ignores the folder; it is not in the workspace.

Choose a separate repository instead only if the web app should be public
while the native app stays private, or if it gets a different owner.

## 7. Order of work

1. Native migration (section 4), after step 3 closes. It touches
   `CloudSyncService`, `KVSSyncService` and `CloudSyncCoordinator`, which
   the step 3 freeze does not cover, but it is still a behavior change to
   sync and deserves its own window.
2. Web first release: sign-in, browse, search, play, queue, settings.
3. Later: gapless playback, live setting updates, home-screen install,
   limited offline caching.

## 8. Decisions

Still planning; nothing is implemented. Answers from Felicity on 2026-11-10:

1. Move the key-value settings to a CloudKit custom zone: **yes**, plus the
   synced sources list in section 3.4.
2. `CKSyncEngine` as the transport: **yes**. Today Ensemble uses no sync
   engine: two records go through hand-written `CKDatabase` fetch and save
   calls with a `CKDatabaseSubscription`, and the six settings go through
   `NSUbiquitousKeyValueStore`.
3. Same repository, `web/` folder: **yes**.
4. Web UI framework: **Svelte**. Apple Music's own web app
   (music.apple.com) is built with Svelte; checked 2026-11-10 by its served
   HTML, which carries thousands of Svelte-scoped class names.
5. Domain: open. Candidate: `app.ensemble.videogorl.me`.
