# Siri album resolution after a library update

## Physical result

Typed requests submitted through Home's Search or Ask field and Return invoked
actual Siri. This was not a Spotlight result tap or a spoken-recognition test.
The installed iPhone 16 Pro build was `0.4.0 / 202610080652.3552`, debug UUID
`43E7A98E-CA21-3CAB-A437-79D792D867FF`, main process 2155. No debugger or profiler
was attached. Times below are October 8, Pacific daylight time.

- At 07:26, “Play the album Hunting High and Low by a-ha in Ensemble” resolved
  the existing source-scoped album 7347. The SiriKit handoff prepared a one-track
  queue, and the audio engine began playback. Playback was then paused.
- An isolated synthetic album, “Amber Telescope Willow Lantern” (17309), was
  added to Minibar Music section 3 with track 17310. Ordinary foreground sync
  cached its count as one and saved a changed Siri index.
- At 07:34, “Play the album Amber Telescope Willow Lantern in Ensemble” resolved
  that exact new album and source. The Siri handoff prepared a one-track queue
  and began playback. Playback was paused at 24.7 seconds.
- Track 17311 was added to the same album without changing its title or ID.
  Before the next request, the copied device database contained both tracks and
  album count two. The changed Siri index was saved at 07:35:10.292.
- At approximately 07:38, the identical request returned “I couldn't find the
  album 'Amber Telescope Willow Lantern' in Ensemble.” One identical controlled
  retry at approximately 07:42 also failed. Neither produced a new main-app
  playback handoff. A screenshot records the failed Siri response.

The initial new-album request passed; reliable Siri resolution after its update
did not. A changed-index save does not establish what a subsequent query process
read or which Siri route handled the failed request. These additions used
foreground notifications, not natural Background Refresh; see the separate
[membership investigation](2026-10-08-plex-membership-reconciliation.md) for the
earlier natural background evidence.

## Diagnostic limits and inspected leads

Native App Group transfer again refused the root-level `siri-media-index.json`
because it is outside permitted transfer directories. The raw saved album count
therefore remains unverified. Console capture did not establish a useful
extension/query log stream; absence from that capture is not proof that no
resolver ran. Device Hub's Computer Use bridge timed out, preventing a further
existing-album control after the failures. That comparison was not executed.

Static inspection found that modern App Shortcuts album queries reload the
shared JSON for each lookup. Identifier queries filter exact composite IDs;
string queries rank names. Neither rejects albums based on `trackCount`.
The legacy SiriKit handler likewise does not use that count as a viability gate.
No inspected path establishes count two as the failure's cause.

`updateAppShortcutParameters()` currently runs during launch, not after catalog
publication. This is a possible publication gap, not a confirmed explanation
for an identical request failing after an unchanged album ID/title. Query-route
selection, identifier lookup, catalog accessibility, and OS catalog state remain
unresolved alternatives.

The next diagnostic should make the actual shared index bytes readable through
an opt-in DEBUG-only export into the app's allowed Library diagnostics directory,
and record privacy-safe route/lookup outcomes for modern entity queries and the
legacy handler. Compare the fixture's saved and reader-loaded entries, then run
the existing-album control and the same one-to-two-track request. Do not alter
release behavior, catalog schema, ranking, or publication timing before evidence
identifies the responsible layer. This instrumentation is proposed, not built.

## Cleanup and evidence

Artifacts are under
`/Users/felicity/Documents/Codex/2026-10-08/ensemble-siri-verification`.
The fixture artist/album/track IDs were 17308–17311, source
`plex:192ce24b8461095c:168bc50f4019f1c9750f28375dcf044594d4192d:3`.
Both generated MP3s fully decoded. Guarded cleanup removed only their owned
files and directories; an independent connection confirmed all four IDs returned
HTTP 404 and exact artist/album queries were empty.

An incidental UI action temporarily favorited only owned track 17310. Its
favorite was cleared through the UI, and normal offline reconciliation removed
the resulting download. The final database matches all original 324 downloads,
six offline targets, and 409 memberships exactly, excluding Core Data version
fields and target refresh timestamps. See `final-cleanup/baseline-comparison.json`.
The latest captured library still contains the two source-scoped temporary track
records; device cache removal remains pending normal library reconciliation.
No existing Plex files, playlists, or metadata were modified.

Playback was visibly paused. With the user's permission to switch input methods
after Computer Use failed, native macOS accessibility operated Device Hub's
Lock menu. CoreDevice independently confirmed `passcodeRequired=true` in
`final-lock-receipt.json`. No simulator was used. No production code was changed.
