# Offline And Connectivity Policy

- A valid downloaded track remains playable when the device or its Plex server
  is unavailable. A non-downloaded Plex track requires allowed device
  connectivity and a source that is not confirmed unavailable.
- Audio-file sharing honors the selected quality while health is unsettled or
  the server is reachable. If health confirms the server offline, a valid
  download at another quality may be shared instead.
- Device offline and server unavailable are distinct states with distinct user
  messaging. Unknown, connecting, or an in-flight check is not confirmed
  unavailability; allow the real request unless the device is known offline.
- Plex cellular streaming is user-controlled and defaults on. When disabled,
  non-downloaded Plex tracks are unavailable on cellular. Low Data Mode prefers
  a valid local file but may stream when no local payload exists. MusicKit
  remains governed by Apple/system policy.
- Queue playback filters or skips tracks proven unavailable; it must not clear or
  strand a queue because health is unknown or temporarily refreshing.
- Health, discovery, and endpoint failures never delete cached libraries,
  artwork, or downloads. Cached/last-good data remains visible while health
  settles or connectivity recovers.
- Known device-offline Plex requests fail before URLSession and failover work.
  Online requests may recover through endpoint failover.
- Plex endpoint preference is local secure, remote secure, local insecure,
  remote insecure, then relay, subject to the user's insecure-connection policy.
  Cooldowns may avoid a recently failed endpoint when another candidate exists,
  but must not make all candidates permanently unreachable.
- A health-selected endpoint seeds later requests. Request-time success and
  published source health must converge; one must not remain stale while the
  other is usable.
- WebSockets are acceleration hints, never the sole correctness path. Foreground
  refresh, polling, retry, and circuit-breaker paths must cover missed or closed
  sockets.
- Source identity is provider/account/server/library scoped as applicable.
  Display names and library section keys are not globally unique.
- Artwork stored for offline library use is durable source-scoped data, not the
  transient Nuke rendering cache. Invalidation marks it stale for replacement;
  it should remain usable offline until an authoritative replacement exists.
- Watch treats servers independently so one unreachable Plex server cannot hide
  reachable servers or their cached libraries.
