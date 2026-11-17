# Plan: measure Apple Music AutoMix and rebuild SmartMix from the findings (2026-11-17)

Status: plan only. Nothing here is built or measured. Each phase needs Felicity's go-ahead; the redesign in
Phase 5 needs its own approval after the findings exist.

Constraint from Felicity (2026-11-17): the result must not depend on Plex. Jellyfin may be added later, so
SmartMix may use only what any source can give it: the decoded audio file and generic track fields (duration,
album, artist, genre text). Server-side analysis (Plex loudness, sonic data) is never required.

## What is publicly known about AutoMix

All of this is secondary reporting; Apple has published no technical description.

- iOS 26 (original): transitions built with "time stretching and beat matching", chosen from tempo and key
  analysis. Reviewers describe one dominant style with an "underwater" filter sound, applied aggressively.
  Apple's support text says AutoMix picks the transition per pair and may only remove silence or do a plain
  crossfade. Albums play without transitions. It needs a subscription and catalog tracks; uploaded and purchased
  files reportedly get no dynamic transitions.
- iOS 27: "improved algorithms" with new transition types. Reviewers say the underwater effect is mostly gone,
  and that AutoMix now repeats parts of outros and intros and adjusts their timing to bridge tempo differences.
  Also on tvOS and HomePod.
- Not published anywhere I found: transition lengths, how much of a song is cut, how the type is chosen, what
  genre does, how cold endings and fade-outs are treated. Those are what the lab below measures.

Sources: 9to5Mac 2026-07-16 and 2025-06-16, MacRumors 2026-06-09, RouteNote, Apple Music user guide (Mac).

## What SmartMix does today (read from the code, not yet measured)

`SmartMixPlanner.swift`, `AudioPlaybackEngine.swift:1586-1615`, `PlaybackService+Loading.swift:1056-1140`.

1. One transition for every pair: a 10 s equal-power crossfade with a high-pass sweep (90 Hz to 1.4 kHz) on
   the outgoing track. No choice by ending type, genre, tempo gap or key.
2. The incoming song starts about 10 s in. `introCut = min(10, max(leadingSilence, transitionDuration))`, so
   with the default 10 s transition the first 10 s of every song is never played, and the next 10 s plays under
   a fade. This is the likely source of "skipping past important parts".
3. The outgoing song always loses its last 10 s to the fade and filter, whether it ends cold, rings out or
   already fades out by itself.
4. Tempo is one BPM value per 30 s window from an RMS-envelope autocorrelation, limited to 70-180 BPM, with a
   single "first strong onset" as the beat anchor. There is no beat grid, downbeat or phrase position.
5. Beats are not held in phase. The outgoing rate ramps from 1.0 to its target across the overlap while the
   beat offset is computed once at the start from the unramped tempos, so the two tracks drift against each
   other for most of the transition (suspected; the lab will show it).
6. Gain, filter and rate are set from a 50 ms timer hopping to the main queue, so automation is stepped and
   can jitter under UI load (suspected).
7. The outgoing track must be a local file (`ON_DECK.md`, 2026-11-10 entry). Nothing in the planner is
   Plex-specific; only the policy text says "Plex-only".
8. Ensemble's Apple Music source cannot get AutoMix. MusicKit's `MusicPlayer.Transition` in the iOS 27 SDK
   offers only `.none` and `.crossfade`.

## Method: an audio lab on the Mac

Black-box measurement of what Music.app plays. No Apple code is read or copied.

### Capture

- A small Swift command-line tool records Music.app's output with a Core Audio process tap (macOS 14.2+). It
  is digital, per-app, and can mute the app at the speakers while recording, so runs are silent. No driver to
  install. Fallback if the tap cannot see Music's audio: ScreenCaptureKit audio, then a loopback device.
- Music.app is driven by AppleScript: play a playlist, seek, read the player position and current track.
  Cua Driver is used only for settings AppleScript cannot reach (the Song Transitions choice).
- For each pair A then B, three recordings:
  1. A's last 60 s, transitions off (reference).
  2. B's first 60 s, transitions off (reference).
  3. A into B with AutoMix on, from 60 s before A ends to 60 s into B.
  References are recorded once per track and reused across pairs.
- Control: the same pairs with Apple's plain Crossfade at a known length. If the analysis does not recover
  that known overlap, the analysis is wrong, not Apple.
- Recordings of commercial audio stay outside the repo and are never committed. Only scripts and derived
  numbers are.

### Analysis

The mix is modelled as a time-warped, filtered, gain-scaled copy of A plus the same for B. This is the
approach used in the DJ-mix reverse-engineering literature (Schwarz and Fourer, UnmixDB; Kim et al., ISMIR
2020; cited from memory, to be confirmed before relying on details).

- Anchor: where the mix stops being identical to A, and where it becomes identical to B.
- Inside that span, fit per frame: which moment of A and of B is sounding (the slope is the stretch ratio; a
  backward jump is a loop), each track's gain in a few frequency bands (shows low-pass, high-pass, bass swap),
  and whether pitch moved.
- Resynthesize from the fit and report the leftover energy. A high leftover means Apple did something the
  model lacks (echo, reverb, anything generated); those pairs are flagged for listening instead of trusted.

Per transition this yields: type, length, seconds of A's ending not heard at full level, seconds of B's
start skipped or masked, stretch amount and which track was stretched, whether beats and downbeats stay
aligned, loops, filters, key relation, and whether vocals overlap.

### Test set

About 80 tracks and 150 pairs, each track labelled by genre, BPM, key, start type and ending type.

| Question | Pairs |
|---|---|
| Same genre | near tempo, far tempo, same key, clashing key |
| Different genre | electronic to acoustic, hip-hop to rock, pop to classical, anything to ambient or beatless |
| Abrupt next to fade | cold end to cold start, cold end to slow intro, fade-out to cold start, fade-out to fade-in, long ring-out, live applause |
| How much song is lost | songs with vocals in the first 2 s, songs with a final hit, short tracks under 90 s, long intros and outros |
| How it decides | same A into six different Bs, six different As into same B, A to B and B to A, same pair three times |
| Exclusions | album neighbours in a playlist, gapless albums, uploaded or purchased files |

The "how it decides" rows show whether cut points belong to a track or to the pair, and whether the result
is repeatable. Felicity's own list of pairs where SmartMix sounded wrong goes in first.

### SmartMix on the same pairs

The same tap records Ensemble's macOS build playing the same pairs from local files, through the same
analysis. That gives one table: Apple against SmartMix on every measure above, and confirms or clears items
2 to 6 in the section above.

## Phases

0. Pilot, about half a day. Build the capture tool and driver, run 5 pairs. Proves: the tap captures Apple
   Music audio; runs are silent; seeking near the end gives the same transition as playing the whole song;
   the same pair repeats; the Crossfade control is recovered. Stop here if capture is blocked.
1. Pick and label the test set from songs present in both Apple Music and the local library.
2. Capture, about 7 hours unattended, can run overnight.
3. Findings note: one section per question above, with a rule table for "given this pair, Apple does this".
4. SmartMix table on the same pairs.
5. Redesign proposal for approval, then implementation.

## Likely shape of the redesign (to be confirmed by Phase 3)

- Analysis from the audio file only: beat grid and downbeats, ending and start classification from the
  loudness envelope, key, stored per track so it is computed once. No public Apple API gives tempo or key.
- A small set of transition types chosen by a rule table: none or gapless, silence trim only, short fade,
  beat-matched blend, loop-extend. Incoming songs start at their real beginning unless a rule says otherwise.
- Sample-accurate automation in the engine in place of the 50 ms timer. Loops use `AVAudioPlayerNode`
  segment scheduling, which the engine already has.
- The policy line "SmartMix is ... Plex-only" would become "any source that provides a local file". That is a
  policy change and needs approval.

## What can and cannot be done

Can:

- Measure every audible property of iOS 27-era AutoMix on the Mac, across a wide test set, unattended.
- Derive rules that predict Apple's choice from pair features, and say how well they predict.
- Rebuild the measured transition types for local-file tracks from any source.

Cannot, or not without something more:

- See Apple's decision model. Rules are inferred from samples and will be wrong for some pairs.
- Use Apple's catalog analysis. Ours must run on device from the file, so beat and key detection will be
  weaker on hard material (rubato, live, classical). The fallback is a plain short fade.
- Test the original iOS 26 behaviour unless a device or Mac is still on 26. Otherwise it is known only from
  reviews and videos.
- Give Ensemble's Apple Music source AutoMix, or mix between Apple Music and a local track. MusicKit exposes
  no audio and only `.none` or `.crossfade`.
- Mix out of a track that is still streaming. That existing limit stays until the streaming handoff is fixed.
- Match effects that depend on stem separation or generated audio, if the leftover-energy check shows Apple
  uses them.
- Confirm the iPhone behaves like the Mac without a spot check: about 20 pairs recorded from the phone over
  USB audio into this Mac. The iPhone 16 Pro is on Bigmac, whose Device MCP did not connect in this session.

## Needed from Felicity

1. One-time macOS prompts: System Audio Recording for the capture tool, and Automation for controlling Music.
2. Confirmation that Music on this Mac is signed in with the subscription and Sync Library on (its
   preferences suggest it is, with transitions enabled).
3. Approval to create and delete playlists named "zz AutoMix Lab ..." in the Apple Music library. They sync
   to every device while they exist.
4. Approval to change Music settings during runs and restore them: Song Transitions, Dolby Atmos off, Sound
   Check, and listening history off so test plays do not shape recommendations or Replay.
5. A window when Music on this Mac is free: half a day for the pilot, one night for the full capture.
6. Pairs where SmartMix has sounded wrong, and any songs to add. Whether songs missing from the library may
   be added to it.
7. Whether any device or Mac is still on iOS 26 or macOS 26.
8. For the phone spot check: the iPhone on USB to this Mac, or Bigmac's Device MCP reconnected.
9. At the end, a listen to about 20 short clips, Apple against the new SmartMix. This is the only step that
   needs ears.

## Who does what

- Lead: design, test matrix, review of every finding.
- Sonnet implementers, separate worktrees: capture tool; Music driver; analysis pipeline.
- Haiku checker with Cua Driver, holding the `mac-gui` lock: Music settings that scripting cannot reach.
- A lead-tier model from another provider reviews the analysis maths before the findings are trusted.
