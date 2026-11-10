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
with no backend apart from one small Worker for Apple Music (section 3.5).
The browser talks to two services:

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

### 3.4 Synced accounts, servers and libraries

Felicity asked on 2026-11-10 to sync everything about sources except the
tokens, when the **Sources** sync switch is on. A new device or the web app
then shows the whole setup and only asks the user to sign in.

Add one `SyncedSetting`, `ensemble.sync.sourceInventory`, a JSON array of
accounts:

| Level | Fields |
|---|---|
| Account | `provider` (`plex` or `appleMusic`), `accountID`, `displayName`, `addedAt`, `removedAt` |
| Server (Plex) | `serverID`, `name`, `removedAt` |
| Library | `libraryID`, `title`, `kind` (music only today) |

- Which libraries are switched on stays in the existing `libraryFlags`
  setting, keyed by source key. The inventory supplies the names to show next
  to those switches; it does not duplicate them.
- Server connection addresses are not synced. They change and include home
  network addresses; each device gets fresh ones from plex.tv after sign-in.
- No tokens, passwords, or anything that grants access.

Behavior:

- Settings shows every account, server and library from the inventory, each
  marked signed in on this device or with a **Sign in** button (section 3.5).
  After sign-in the device matches the result to the entry by account ID and
  applies the library switches.
- Only an explicit removal by the user sets `removedAt`. A device that is not
  signed in, or can't reach a server, never removes anything. Entries merge
  per account and per server, newest change wins, like library flags.
- With the Sources switch off, a device neither writes nor applies the
  inventory, matching how the switch works today.
- On native, Plex accounts with tokens already arrive through iCloud Keychain
  (the existing Sources feature, `bootstrapSources`). That path stays; the
  inventory adds the web app and Apple Music, which is authorized per device.
- The per-feature sync switches in `SyncSettingsManager` keep working: a
  switched-off feature neither sends nor applies its record.

### 3.5 Signing in without syncing tokens

Three options were considered.

1. **Sign in on each device.** The baseline: Plex's PIN sign-in on the web,
   MusicKit authorization for Apple Music. Always available as the fallback.
2. **Approve from a signed-in device (recommended for Plex).** The web app
   creates a short Plex PIN and shows it as a QR code and an
   `ensemble://` link. The iPhone or Mac app, already signed in, confirms the
   account and calls `PUT https://plex.tv/api/v2/pins/link` with the code and
   its own token. The web app's pending PIN then returns a **new token of its
   own**. No token crosses iCloud; the web session appears in Plex's
   authorized devices and can be revoked there on its own. This is the call
   plex.tv/link uses, and python-plexapi's `MyPlexAccount.link` makes it, but
   Plex does not document it, and a forum thread reports a 403 (error 1068)
   for some devices. Prototype it before relying on it; option 1 stays.
3. **Store tokens in CloudKit.** Rejected. As plain fields, anyone with a
   web session on the user's Apple Account could read a token with full Plex
   access. CloudKit's encrypted fields would protect them, but developer
   reports say CloudKit JS cannot read encrypted fields (Apple's docs are
   ambiguous), so the web app could not use them anyway.

Apple Music on the web needs MusicKit JS, which needs an Apple Music
developer token: a JWT signed with a MusicKit private key, valid for up to
six months. Either embed a token rotated by hand, or mint it from a
Cloudflare Worker (free tier) that keeps the key as a secret. The Worker is
the only server piece in the design; it is needed only for Apple Music.

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

1. Move the key-value settings to a CloudKit custom zone: **yes**, plus
   syncing accounts, servers and libraries without tokens (sections 3.4
   and 3.5).
2. `CKSyncEngine` as the transport: **yes**. Today Ensemble uses no sync
   engine: two records go through hand-written `CKDatabase` fetch and save
   calls with a `CKDatabaseSubscription`, and the six settings go through
   `NSUbiquitousKeyValueStore`.
3. Same repository, `web/` folder: **yes**.
4. Web UI framework: **Svelte**. Apple Music's own web app
   (music.apple.com) is built with Svelte; checked 2026-11-10 by its served
   HTML, which carries thousands of Svelte-scoped class names.
5. Domain: open. Candidate: `app.ensemble.videogorl.me`.
