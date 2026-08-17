# Apple Music Hidden Identity Sync

**Date:** 2026-08-16
**Scope:** Apple Music songs, albums, artists, and playlists selected for Ensemble's Hidden feature. This is research only; no production code or policy changed.

## Conclusion

Yes. Ensemble can sync Apple Music Hidden selections, and the current device-local policy can be narrowed without turning the Apple Music source itself into a synced source.

The honest promise is not “every Apple Music ID works globally forever.” It is:

> Ensemble syncs an exact, typed Apple Music Hidden intent through the user's private iCloud database. Another device applies it only when its authorized Apple Music library or storefront can resolve the same item. Unresolvable records remain dormant; Ensemble never guesses by title, artist, or duration.

Catalog identity is the preferred cross-device identity. Library identity is a necessary fallback for uploads, imports, and private playlists that have no catalog counterpart. Apple explicitly distinguishes catalog IDs from library IDs and says a removed-and-readded library item receives a new library ID. Apple also scopes catalog requests to a storefront, and documents that equivalent songs and albums can have different IDs in different storefronts. ([Handling requests and responses](https://developer.apple.com/documentation/applemusicapi/handling-requests-and-responses), [catalog equivalencies](https://developer.apple.com/documentation/applemusicapi/managing-content-ratings-alternate-versions-and-equivalencies))

## Why the Current Policy Exists

The restriction entered the repository with the initial Apple Music source in commit [`ed63484b`](https://github.com/videogorl/ensemble/commit/ed63484b39a772e6c258750a3d375c033f93ab3d). That change made Apple Music a device-local source, kept enablement in `UserDefaults`, and excluded it from KVS, CloudKit, Keychain source sync, Siri shared indexes, and Watch payloads. The current condensed policy retains that boundary. ([current policy](../../.claude/skills/app-policies/references/sync-and-refresh.md#L9-L11), [local enablement](../../Packages/EnsembleCore/Sources/Services/AccountManager.swift#L832-L871))

No commit message or policy text records an Apple prohibition on syncing resource IDs. The likely rationale, inferred from the implementation, was containment: MusicKit manages user authorization and tokens on each device, while Ensemble represents Apple Music with the synthetic source key `appleMusic:device:system:library`. ([source identifier](../../Packages/EnsembleCore/Sources/Models/MusicSource.swift#L161-L179), [Apple user-token management](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit))

That rationale still supports keeping authorization, tokens, enablement, cached library rows, and provider state local. It does not require a Hidden intent referring to an Apple resource to remain local.

## Identity by Item Type

| Item | Best synced identity | Fallback | Current Ensemble state | Honest limitation |
|---|---|---|---|---|
| Song | Resource type + catalog ID + capture storefront | Library song ID | Already retains both IDs when Apple provides the catalog relationship. ([provider mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1718-L1752), [track accessors](../../Packages/EnsembleCore/Sources/Models/MusicSource.swift#L273-L300)) | Apple says the library-to-catalog relationship exists only “when known”; uploads/imports may remain library-only. ([library song relationship](https://developer.apple.com/documentation/applemusicapi/librarysongs/relationships-data.dictionary)) |
| Album | Resource type + catalog album ID + capture storefront | Library album ID | Currently persists a key derived from the library album relationship ID, not the catalog album ID. ([album mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L332-L360), [library key](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1761-L1766)) | Apple exposes an optional library-album-to-catalog-album relationship, so Ensemble can capture a catalog ID without fuzzy matching. ([catalog relationship](https://developer.apple.com/documentation/applemusicapi/libraryalbums/relationships-data.dictionary/libraryalbumscatalogrelationship)) |
| Artist | Resource type + catalog artist ID + capture storefront | Library artist ID | Currently persists a key derived from the library artist relationship ID, not the catalog artist ID. ([artist mapping](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L307-L329), [library key](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1756-L1760)) | Apple exposes an optional library-artist-to-catalog-artist relationship. It documents no cross-storefront artist-equivalency endpoint, so a missing exact catalog lookup must remain unresolved. ([catalog relationship](https://developer.apple.com/documentation/applemusicapi/libraryartists/relationships-data.dictionary)) |
| Playlist | Catalog playlist ID when an association exists | Library playlist ID | Currently persists the library playlist ID. It decodes a possible `globalId` but uses it only when classifying playlist behavior. ([playlist persistence](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1370-L1429), [`globalId` use](../../Packages/EnsembleCore/Sources/Services/AppleMusicSourceProvider.swift#L1287-L1296)) | Apple exposes a catalog relationship for at most one associated catalog playlist. Private user playlists commonly have only a library identity. ([playlist relationship](https://developer.apple.com/documentation/applemusicapi/libraryplaylists/relationships-data.dictionary)) |

The item type must be part of the identity. Apple resource objects carry both a required `id` and required `type`; a bare string is not a complete resource identity. ([Resource](https://developer.apple.com/documentation/applemusicapi/resource))

## Account and Storefront Boundaries

- Apple Music's `/me` endpoints refer to the Apple Music subscriber represented by the Music User Token, which MusicKit manages automatically on Apple platforms. The token itself should never enter Ensemble sync. ([User authentication](https://developer.apple.com/documentation/applemusicapi/user-authentication-for-musickit))
- The user's music library is available on their devices when those devices use the same Apple Account for Apple Music and have Sync Library enabled. ([Apple Support](https://support.apple.com/en-us/118285))
- Ensemble's CloudKit account and the device's Media & Purchases account are not guaranteed to be the same; Apple supports separate iCloud and media-purchases accounts. Therefore receiving a Hidden record through CloudKit does not prove that the target device is using the same Apple Music account. ([Apple Support](https://support.apple.com/en-nz/117294))
- Catalog IDs cannot be treated as storefront-independent. Apple requires a storefront for catalog requests and provides equivalency translation specifically because albums and songs may have different IDs in different storefronts. ([user storefront](https://developer.apple.com/documentation/applemusicapi/get-a-user%27s-storefront), [equivalencies](https://developer.apple.com/documentation/applemusicapi/managing-content-ratings-alternate-versions-and-equivalencies))

For a minimal first version, require the capture storefront to match the target storefront. A later version may use Apple's equivalency endpoint for songs and albums only. Do not invent equivalence for artists or playlists.

## Privacy and Storage

Apple permits user music metadata such as playlists and favorites only for a clearly disclosed function directly relevant to the app. App Review also requires the Music usage description to disclose access, forbids using the data to identify users/devices or target ads, and forbids sharing it with third parties except to support or improve the app experience. Cross-device Hidden sync is directly related to Ensemble's disclosed feature, but the privacy policy and Music purpose string should accurately cover collection and iCloud synchronization. ([Developer Program License Agreement, section 3.3.12(D)](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/), [App Review Guideline 4.5.2](https://developer.apple.com/app-store/review/guidelines/))

Do not use `NSUbiquitousKeyValueStore` for Hidden identities. Apple says not to store personal or sensitive information there because its on-disk representation is unencrypted; it is also limited to 1 MB and 1,024 keys. ([KVS documentation](https://developer.apple.com/documentation/foundation/nsubiquitouskeyvaluestore))

Use Ensemble's existing CloudKit private database transport. Apple says private-database records are owner-accessible by default, not visible in the developer portal, and count against the user's iCloud quota. Ensemble already opens its configured container's private database. ([CloudKit private database](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase), [current service](../../Packages/EnsembleCore/Sources/Services/CloudSyncService.swift#L54-L72)) Encrypted fields are optional if product requirements later promise stronger confidentiality; they are not necessary merely to support exact identity sync. ([CloudKit encrypted values](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues))

## Minimal Contract

Store one logical Hidden selection as:

```text
provider = appleMusic
kind = song | album | artist | playlist
libraryID = optional opaque string
catalogID = optional opaque string
catalogStorefront = required when catalogID exists
```

Resolution rules:

1. Keep the source itself local. Never sync MusicKit authorization, Music User Tokens, Apple Music enablement, cached Apple library metadata, or playback state.
2. Prefer catalog identity. On the capture storefront, apply only an exact typed catalog match and, for a library selection, its exact catalog-linked library counterpart.
3. Use a library ID only when no catalog identity exists. Apply it only if the target device's authorized `/me` library resolves that exact typed ID. Apple library IDs can become stale after removal and re-addition; a stale record stays dormant.
4. When both IDs exist, require the resolved library item's catalog relationship to agree with the stored catalog ID. A disagreement stays dormant rather than hiding the wrong item.
5. Never fall back to title, artist name, album name, duration, ISRC, UPC, artwork, or normalized-name matching. These are metadata, not exact user-library identity.
6. Do not display cloud-stored Apple metadata. Rehydrate labels and artwork from the target device's authorized Apple Music response; unresolved records can be described generically or omitted until resolvable.

## Recommended Policy Change

Replace the absolute “Apple Music identity does not enter KVS or CloudKit” rule with a narrow exception:

> Apple Music remains a device-local source: authorization, tokens, enablement, provider caches, playback state, and library payloads do not sync. User-authored cross-device features may store typed Apple Music resource references in the private CloudKit database. A receiving device applies a reference only after exact authorized library/catalog resolution for its account and storefront; unresolved references remain inert and metadata matching never substitutes for identity.

This preserves the reason the device-local boundary exists while allowing Hidden to behave consistently on the user's compatible devices.
