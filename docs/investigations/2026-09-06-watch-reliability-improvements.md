# Watch reliability improvements

Implemented follow-up to [the Watch implementation review](2026-09-04-watch-implementation-review.md).

## Changes

- Restore the full cached catalog and hidden identities before credential discovery. Keep unavailable sources visible unless explicitly disabled; do not erase the persistent catalog when discovery yields no selected libraries.
- Serialize refresh ownership and CoreData writes, reject canceled results, and remove duplicate discovery and eager playlist-target loading from startup.
- Restore the playback queue asynchronously. Write structural changes on a serial utility queue and checkpoint playback position separately instead of rewriting the full queue every five seconds.
- Persist recent source-scoped detail results, including successful empty results and duplicate playlist entries. Reuse results for 60 seconds and retain stale results when requests fail. The cache retains 32 collections; it is not a complete offline membership database.
- Reuse merged browse projections until their catalog or preferences change. Cancel obsolete autoplay requests and reject results for an altered queue.
- Preserve the remote queue during refresh, defer queue reads behind active commands, expose retry on initial failure, and reject older session snapshots. Request artwork after completing the originating command.
- Use source-aware pin identities, reject canceled artwork results, allow two-line collection titles, and place Queue modes in one accessible row.

## Verification

- `swift test -q --package-path Packages/EnsembleWatchCore`: 32 tests passed, zero failures. Coverage includes cold cached readiness, queue checkpoints across store recreation, cached source visibility, hidden-state persistence, and detail identity/order/empty results.
- `EnsembleWatch` built successfully using `Ensemble.xcworkspace`, DerivedData `/tmp/ensemble-watch-20260905`, destination `8709C9B5-56AE-445E-B5B8-6D9455DCE48F` (Apple Watch SE 3 40mm, watchOS 26.5).
- Installed executable SHA-256 matched the built executable: `5eb8b4eaf3ffc3054640669ae5200203ddb898444e0bc71495e392e8a16ec150`.
- Cold relaunches restored 1,919 albums and 21,263 tracks. Logged model cache hydration took 542, 222, and 172 ms. These are simulator cache-hydration measurements, not total launch times or a measured before/after speedup.
- Inspected cached Songs and Albums screens using DEBUG launch routes with bootstrap network discovery disabled. This exercises persisted hydration without discovery, not actual radio/network loss.
- Inspected an actual remote Queue response and the compact controls. Accessibility exposed separate Shuffle, Repeat One, and AutoPlay labels; the first track became visible without scrolling.
- Authenticated Plex identity and library-section requests returned HTTP 200. Streaming endpoints were not changed or retested.
- Local evidence: `/tmp/ensemble-watch-20260906-evidence/` (screenshots, startup log, build identity), `/tmp/watch-final-tests.log`, and `/tmp/ensemble-watch-20260906-final-build.log`. These temporary artifacts are not committed.

## Remaining limits

Simulator touch/swipe tools reported success without changing the screen, and computer use could not acquire the Simulator window. Launch routes and screenshots prove screen state, not delivered taps, scrolling, or end-to-end navigation. Physical Watch playback, Crown behavior, background durability, reachability transitions, and deliberately overlapping remote commands remain unverified.

The shared persistent-store fatal-error recovery path, database-backed category pagination, and navigation restoration remain follow-up work. This change does not claim recovery from a corrupt CoreData store or complete offline detail coverage. No phone playback changes are included.
