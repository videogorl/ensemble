# Apple Music Hidden Identity Sync

**Date:** 2026-08-16
**Scope:** Apple Music songs, albums, artists, and playlists selected for Ensemble's Hidden feature.

## Conclusion

Yes. Ensemble can sync Apple Music Hidden selections, and the current device-local policy can be narrowed without turning the Apple Music source itself into a synced source.

The honest promise is not “every Apple Music ID works globally forever.” It is:

> Ensemble syncs an exact, typed Apple Music library identity through the user's private iCloud database. Another device applies it only when its authorized Apple Music library resolves that same identity. Unresolvable records remain dormant; Ensemble never guesses by title, artist, or duration.

Library identity is deliberately canonical: Hidden means that exact item in the user's library. Apple explicitly distinguishes library IDs from catalog IDs and says a removed-and-readded library item receives a new library ID, so a re-added item is visible until the user hides it again. A song's catalog relationship is retained only so a surfaced catalog result can offer to unhide its exact hidden library counterpart. ([Handling requests and responses](https://developer.apple.com/documentation/applemusicapi/handling-requests-and-responses))

## Why the Current Policy Exists

The restriction entered the repository with the initial Apple Music source in commit [`ed63484b`](https://github.com/videogorl/ensemble/commit/ed63484b39a772e6c258750a3d375c033f93ab3d). That change made Apple Music a device-local source, kept enablement in `UserDefaults`, and excluded it from KVS, CloudKit, Keychain source sync, Siri shared indexes, and Watch payloads. The current condensed policy retains that boundary. ([current policy](../../.claude/skills/app-policies/references/sync-and-refresh.md#L9-L11), [local enablement](../../Packages/EnsembleCore/Sources/Services/AccountManager.swift#L832-L871))

No commit message or policy text records an Apple prohibition on syncing resource IDs. The likely rationale, inferred from the implementation, was containment: MusicKit manages user authorization and tokens on each device, while Ensemble represents Apple Music with the synthetic source key `appleMusic:device:system:library`. ([source identifier](../../Packages/EnsembleCore/Sources/Models/MusicSource.swift#L161-L179), [Apple user-token management](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit))

That rationale still supports keeping authorization, tokens, enablement, cached library rows, and provider state local. It does not require a Hidden intent referring to an Apple resource to remain local.

## Identity by Item Type

| Item | Synced identity | Optional association | Current Ensemble state | Honest limitation |
|---|---|---|---|---|
| Song | Type + library song ID | Catalog song ID for unhide discovery only | Already retains both IDs when Apple provides the catalog relationship. ([provider mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1718-L1752), [track accessors](../../Packages/EnsembleCore/Sources/Models/MusicSource.swift#L273-L300)) | The catalog relationship exists only “when known”; uploads and imports may remain library-only. ([library song relationship](https://developer.apple.com/documentation/applemusicapi/librarysongs/relationships-data.dictionary)) |
| Album | Type + library album ID | None in v1 | Persists the library album relationship ID. ([album mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L332-L360), [library key](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1761-L1766)) | Removal and re-addition can produce a new identity. |
| Artist | Type + library artist ID | None in v1 | Persists the library artist relationship ID. ([artist mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L307-L329), [library key](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1756-L1760)) | Removal and re-addition can produce a new identity. |
| Playlist | Type + library playlist ID | None in v1 | Persists the library playlist ID. ([playlist persistence](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1370-L1429)) | A deleted and recreated playlist is a new item, even if its contents match. |

The item type must be part of the identity. Apple resource objects carry both a required `id` and required `type`; a bare string is not a complete resource identity. ([Resource](https://developer.apple.com/documentation/applemusicapi/resource))

## Account and Storefront Boundaries

- Apple Music's `/me` endpoints refer to the Apple Music subscriber represented by the Music User Token, which MusicKit manages automatically on Apple platforms. The token itself should never enter Ensemble sync. ([User authentication](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit))
- The user's music library is available on their devices when those devices use the same Apple Account for Apple Music and have Sync Library enabled. ([Apple Support](https://support.apple.com/en-us/118285))
- Ensemble's CloudKit account and the device's Media & Purchases account are not guaranteed to be the same; Apple supports separate iCloud and media-purchases accounts. Therefore receiving a Hidden record through CloudKit does not prove that the target device is using the same Apple Music account. ([Apple Support](https://support.apple.com/en-nz/117294))
- Catalog IDs cannot be treated as storefront-independent. Apple requires a storefront for catalog requests and provides equivalency translation specifically because albums and songs may have different IDs in different storefronts. ([user storefront](https://developer.apple.com/documentation/applemusicapi/get-a-user%27s-storefront), [equivalencies](https://developer.apple.com/documentation/applemusicapi/managing-content-ratings-alternate-versions-and-equivalencies))

Hidden does not translate catalog identities across storefronts because catalog identity is not its canonical key.

## Privacy and Storage

Apple permits user music metadata such as playlists and favorites only for a clearly disclosed function directly relevant to the app. App Review also requires the Music usage description to disclose access, forbids using the data to identify users/devices or target ads, and forbids sharing it with third parties except to support or improve the app experience. Cross-device Hidden sync is directly related to Ensemble's disclosed feature, but the privacy policy and Music purpose string should accurately cover collection and iCloud synchronization. ([Developer Program License Agreement, section 3.3.12(D)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/), [App Review Guideline 4.5.2](https://developer.apple.com/app-store/review/guidelines/))

Do not use `NSUbiquitousKeyValueStore` for Hidden identities. Apple says not to store personal or sensitive information there because its on-disk representation is unencrypted; it is also limited to 1 MB and 1,024 keys. ([KVS documentation](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore))

Use Ensemble's existing CloudKit private database transport. Apple says private-database records are owner-accessible by default, not visible in the developer portal, and count against the user's iCloud quota. Ensemble already opens its configured container's private database. ([CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [current service](../../Packages/EnsembleCore/Sources/Services/CloudSyncService.swift#L54-L72)) Encrypted fields are optional if product requirements later promise stronger confidentiality; they are not necessary merely to support exact identity sync. ([CloudKit encrypted values](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues))

## Minimal Contract

Store one logical Hidden selection as:

```text
provider = appleMusic
kind = song | album | artist | playlist
libraryID = required opaque string
catalogID = optional song association used only to find an Unhide action
```

Resolution rules:

1. Keep the source itself local. Never sync MusicKit authorization, Music User Tokens, Apple Music enablement, cached Apple library metadata, or playback state.
2. Apply only an exact typed library-ID match in the target device's authorized library. A stale record stays dormant.
3. A complete authoritative library inventory may tombstone an identity that no longer exists. A later re-addition with a new library ID is visible.
4. A song's exact catalog association may expose Unhide for its hidden library counterpart; it never hides a catalog result by itself.
5. Never fall back to title, artist name, album name, duration, ISRC, UPC, artwork, or normalized-name matching. These are metadata, not exact user-library identity.
6. Do not sync display metadata. Rehydrate labels and artwork locally and omit unresolved records from the Hidden screen.

## Recommended Policy Change

Replace the absolute “Apple Music identity does not enter KVS or CloudKit” rule with a narrow exception:

> Apple Music remains a device-local source: authorization, tokens, enablement, provider caches, playback state, and library payloads do not sync. Hidden may store typed Apple Music library references in the private CloudKit database. A receiving device applies a reference only after exact authorized library resolution; unresolved references remain inert and metadata matching never substitutes for identity.

This preserves the reason the device-local boundary exists while allowing Hidden to behave consistently on the user's compatible devices.
