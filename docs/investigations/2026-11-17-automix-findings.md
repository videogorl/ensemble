# What Apple Music AutoMix does: first findings (2026-11-17)

Status: measured on one Mac (macOS 27.2, Music 1.7.2). The tables below are from the first 939 song pairs; the
data set has since grown to 1,448 pairs, 534 of them with both songs also in the Plex library. The strategy-choice rules and the
level and filter curves are not worked out yet. Plan and method: `2026-11-17-automix-reverse-engineering-plan.md`.

## How the evidence is collected

- A few seconds after a song starts, Music logs the transition it has planned into the next song: a strategy
  name, the start, pivot and end time in each song, the overlap length and the average speed of each song.
  `scripts/automix-lab/harvest.py` plays a sequence of songs, reads each plan from the log and skips on. About
  10 s per pair.
- Music also caches the per-song analysis it downloads from Apple to make that plan: beat and bar times, tempo
  and key at the beginning, middle and end, fade-in and fade-out times, a loudness curve, vocal activity,
  suggested entry and exit points, danceability and energy. `collect_analysis.py` copies it. 601 songs so far.
- The plan is computed on the device by system frameworks named SonicKit, SonicFoundation and SonicAudioUnits.
  Nothing was disassembled; names came from log text and strings.
- Data lives in `~/Developer/automix-lab-data/` (not in the repo). `join.py` builds one table of pairs.

Pairs: 378 random across the library by genre, 561 from shuffles of the playlists Favorite Songs, Ambient
Electric and dancedancedance. 648 have Apple's analysis for both songs.

## Strategies

| Strategy (Apple's name) | Pairs | Share | Overlap | Incoming song | Outgoing song |
|---|---|---|---|---|---|
| Dead-Air Removal | 741 | 79% | 1 to 10 s | from its start | plays to its end |
| Smart Cross-Fade (variants 3, 4, 33, 44) | 76 | 8% | 2 to 21 s | enters a few seconds in (median 4 s, up to 31 s) | plays to its end |
| Fallback Cross-Fade | 53 | 6% | always 2 s | from its start | plays to its end |
| No plan logged | 34 | 4% | | | |
| Beat-Matched Filtered Cross-Fade (8, 9, 12) | 25 | 3% | 13 to 39 s | enters late (median 16 s, up to 45 s) | ending dropped (median 6 s) |
| Beat-Matched Pop (16, 20) | 8 | 1% | about 7 s | enters about 11 s in | ending dropped (about 5 s) |
| Beat-Matched Hip-Hop (18) | 2 | | about 12 s | enters about 7 s in | about 20 s dropped |
| Beat-Matched Dance (17) | 1 (pilot) | | 30 s | enters 30 s in | 16 s dropped |

## Dead-Air Removal, the common case (537 pairs with analysis)

- The overlap always ends exactly at the end of the outgoing song.
- The incoming song always starts at its own beginning (the start of Apple's fade-in marker, 0 s for most).
- The overlap starts about 2 s after the point Apple marks as the start of the outgoing fade-out, so it is
  the fade-out length less about 1.5 s, held between 1 and 10 s. One in five is capped at 10 s.
- No speed change.

- The overlap belongs to the outgoing song alone: 131 songs seen before more than one next song got the same
  overlap each time.

## SmartMix against Apple on the same songs

The real `SmartMixPlanner.swift`, compiled alone, planned 534 pairs from the Plex files of songs Apple had
planned. This compares plan numbers, not sound.

- First attempt (overlap = time 10 dB down after trimming silence, 2 s floor): 85% of Dead-Air pairs got the 2 s
  floor, and counting the trimmed silence it ran over 3 s longer than Apple on 105 of 420.
- Current rule: overlap = time since the song was last within 16 dB of its usual level, to the end of the
  file, less 0.5 s, held between 1 and 10 s; the incoming song starts at 0. Against Apple's Dead-Air Removal
  (420 pairs): mean difference 0.67 s, 82% within 1 s, 92% within 2 s, correlation 0.91.
- Where Apple chose something else, SmartMix still plans this simple overlap. Fallback Cross-Fade: Apple 2 s,
  SmartMix median 9 s (21 pairs), cause not known. Smart Cross-Fade: Apple median 7 s entering the next song
  late, SmartMix 5 s from its start. Beat-matched: Apple 8 to 16 s with tempo change, SmartMix 3 to 4 s.
- Tempo: the estimator SmartMix shipped with matched Apple's tempo within 2% on 42% of 644 song starts and
  endings (52% allowing half and double). Its replacement, which follows onsets across the spectrum, matches
  66% (80%); at the confidence SmartMix requires before changing speed, 81% (91%), and at its "strong"
  confidence 87% (96%). `scripts/automix-lab/tempo_eval.py` reproduces the comparison. The remaining misses
  are mostly 2:3 and 4:3 confusions.

## Beat-matched strategies (small sample)

- The blend starts on a bar line of the outgoing song (15 of 18) and usually of the incoming one (12 of 18).
- Length is a round number of bars: about 4 for Pop, 8 or 16 for Filtered Cross-Fade.
- Both songs change speed in opposite directions to meet in the middle. Up to 7% on Filtered Cross-Fade and
  13% on one Pop pair.
- Each plan has a pivot time between start and end. On the one recorded pair the bass of the two songs swapped
  at the pivot while the outgoing highs carried on to the end.
- In about half of these the incoming song enters after its first strong vocal has already begun.
- They go with more danceable material (median danceability 0.4 against 0.2 elsewhere) and are most common
  for Electronic, Dance and Indie Pop.

## How the planner decides (508 pairs with its own reasoning)

Music logs the planner's reasoning on the `com.apple.smarttransitions` channel; `harvest.py` keeps it per
pair and `trace_summary.py` tabulates it. Everything below is the planner's stated reason unless marked
"inferred".

It tries the strategies in a fixed order, each one either produces candidates or states why not, then picks:

1. Beat-matched results win if any exist; otherwise the non-beat-matched ones; the fallback only when nothing
   else produced a result.
2. Within the winning group a single result is taken as is. With two or more, one is drawn at random weighted
   by score. The draw is repeatable: the same pair gives the same plan every time.

Checks applied to every pair first:

- Timing confidence. The analysis expects a song length; if the file being played differs by 2 s or more,
  every strategy except the fallback is ruled out ("Stereo timing inaccurate. Transition complexities
  reduced"). This is the main cause of the 2 s Fallback Cross-Fade. A second cause: the loudness curve's
  length differs from the file by 2 s or more, which removes Dead-Air Removal.
- A transition may be at most 60 s, must leave 30 s of each song untouched, and cannot start in the first
  ~10.7 s of the outgoing song.

Per strategy:

| Strategy | Requires | Seen rejected for |
|---|---|---|
| Beat-Matched Dance | both songs' main genre is Dance (Apple genre 17) | genre, all 508 pairs |
| Beat-Matched Hip-Hop | both main genres in Hip-Hop/Rap or R&B/Soul (18, 15) | genre, all 508 pairs |
| Beat-Matched Pop | both main genres Pop (14); neither song strongly acoustic; both danceable; same beats per bar; tempos compatible | genre (most), acousticness, danceability, tempo |
| Beat-Matched Filtered Cross-Fade | both main genres in a list of about 50 (Electronic, Dance, Pop, Hip-Hop, R&B, Country, Reggae, World and sub-genres; Rock 21 and Alternative 20 are not in it) but not both Pop; same acoustic, danceability, time-signature and tempo checks | genre (most), acousticness, danceability, tempo |
| Smart Cross-Fade | neither song in an excluded genre (every genre rejection involved genre 22; the full list is not logged); the outgoing song's last loudness section trends downward; the incoming song opens with a distinct start section | no fading ending (285), no start section (121), genre (25) |
| Dead-Air Removal | a usable loudness curve | curve length mismatch (13) |
| Soft Skip | only when moving early-to-early (a manual skip) | every natural song change |
| Fallback Cross-Fade | nothing; always produces a 2 s result | never |

Thresholds, inferred by matching verdicts to each song's analysis values (small samples):

- "Acoustic" means acousticness of about 0.85 or more; "not danceable" means danceability below about 0.3.
- Tempos are compatible when the ratio is within roughly 3:4 to 4:3, directly or after doubling one of them
  (ratios 0.77 to 1.23 passed, 0.70 to 0.73 and 1.35 to 1.48 failed, 0.47 to 0.64 passed as two-to-one).
- Beat-matched candidates need at least 8 matching bars between the two songs, and skip an incoming section
  boundary that falls within the first 16 bars.
- A quiet outgoing stretch (average below -15 on Apple's loudness scale) is not treated as usable material
  for a beat-matched blend; clashing keys rule a candidate out unless the passage is not melodic; a strong
  vocal at the start of the incoming song is checked for each candidate.
- Dead-Air Removal starts at the first point where the ending drops to -30 or below on Apple's loudness
  curve (413 of 413 where such a point exists); when the song never gets that quiet it uses the last sample,
  giving the 1 s overlap. The incoming song starts at 0 unless its opening is silent (42 pairs started up to
  4.5 s in).

## What each style does (Apple's own catalogue)

The planner framework ships its recipes as data:
`/System/Library/PrivateFrameworks/_SonicKit_MusicKit.framework/Versions/A/Resources/TransitionStyles.json`
(24 styles) and `DSPGraph.dspg` (the effect chain). Each style lists, per song, which processor is automated,
over which fraction of the transition, between which values and with which easing. Apple's file is not copied
into this repository; a readable table is generated outside it. Styles seen in harvests:

| ID | Apple's name | Outgoing song | Incoming song |
|---|---|---|---|
| 0 | Gapless (Dead-Air Removal) | gain 1 to 0 over the last 0.3 s | full level from its start |
| 1 | constant-power cross-fade (Fallback) | gain 1 to 0 over the whole overlap | gain 0 to 1 over the whole overlap |
| 3 | overlap | untouched | untouched |
| 33 | overlap + Reverb | reverb send rises to 0.75 over the first 2 s (decay 6 s high, 5 s low) | untouched |
| 4 | Ease-in Ring-out | untouched, rings out | gain 0 to 1 over the first 2 s |
| 44 | Ease-in Ring-out + Reverb | reverb as 33 | gain 0 to 1 over the first 2 s |
| 8 | BM - Filter high to low | low-pass closes 20 kHz to 200 Hz over the blend, cut in the last 0.3 s | in over 0.3 s; high-pass opens 20 kHz to 10 Hz; low-pass opens 1.2 kHz to 20 kHz late |
| 9 | BM - Filter expansion | from halfway: low-pass closes to 20 Hz, high-pass rises to 200 Hz; cut in last 0.3 s | band-limited around 1 kHz, widening to full range by three quarters |
| 12 | BM - Long filter high to low | as 8 but only across the middle half; cut at three quarters | as 8, entering at one quarter |
| 16 | Pop - Delay out | low-pass to 3.5 kHz, a beat-length echo (60% feedback) takes over as the dry signal is cut at one quarter; gone by half | high-pass 5.2 kHz to 20 Hz and fade in between about one fifth and two fifths |
| 20 | Pop - Reverb | low-pass sweep to 20 Hz and high-pass rise across the middle half with a 6 s reverb send | fades in across the middle half; high-pass falls from 3.3 kHz while a low-pass opens from 20 Hz to 20 kHz |

Catalogue entries never seen here: 2, 22 (splice), 5, 6, 7, 10, 11, 13, 14 ("No vocal clash one"), 15 and 18
(Hip-Hop delay-out and looping), 17 and 19 (Dance repeater and "Any Key").

All beat-matched styles also ramp playback speed linearly across the blend on both songs. Fades use
constant-power style easing (exponent 0.5); filter sweeps use steeper easing (exponents 2 and 4).

Read from the planner's code (Ghidra, addresses in the lab notes outside the repo):

- Smart Cross-Fade compares the mean loudness either side of a song-structure boundary. Incoming: the first
  section must be at least 6 louder than what precedes it. Outgoing: what follows the last section must be at
  least 6 quieter than that section and fall at 1 per second or faster without wobbling. Re-implemented, this
  reproduces 366 of 421 traced verdicts (incoming 165 of 167); the misses come from not yet knowing which
  structure boundaries the planner keeps.
- Acousticness counts as significant from 0.85; danceability passes from 0.3 or when missing; melodicness is
  insignificant below 0.25; tempo ratio limit 0.75.
- Smart Cross-Fade always proposes 3, 33, 4 and 44 and scores exactly one above zero; how that one is picked
  is not decoded.

## What SmartMix does with this

Apple's loudness curve turns out to be the plain RMS level of the mono mix in dB, one value per half second:
computed from the Plex files of songs in both libraries (about 40,000 half-second samples) it matches Apple's values with a median difference of 0.03 dB
(correlation 0.95). Apple's thresholds therefore apply to any audio file directly, with no server data.

`SmartMixPlanner` tries, in Apple's order:

| SmartMix style | Apple style | Chosen when | Overlap | Next song |
|---|---|---|---|---|
| filter blend | 8 | both songs' first genre is electronic, dance, pop, hip-hop, R&B, country, reggae or world; both tempos estimated with confidence 0.82 or more and within 8% (directly or at half or double); both stretches average -15 dB or louder; at most 12 s of ending to leave out | 32 beats, tempo gliding from one song's to the other's | from its first sound, on a matching beat |
| overlap, ease-in | 3, 4 | the outgoing song ends in a steady fall (6 dB below the 10 s before it, 1 dB/s or faster, audible for 2 s) and the next song steps up 6 dB within its first 10 s | the length of the fall, up to 20 s | two bars before the step (one if only one fits, else from the top); eased in over 2 s when it enters partway |
| the same with reverb | 33, 44 | as above, and the fall stays above -55 dB for 5 s or less | as above; the outgoing song's reverb rises over 2 s and rings on after it ends | as above |
| gapless | 0 | otherwise | from where the ending last drops to -30 dB, 1 to 10 s | at full level from its first sound (a silent opening up to 5 s is skipped) |
| cross-fade | 1 | the outgoing file could not be analysed | 2 s | from the top |

Levels, filter sweeps and the speed glide of each style follow the catalogue table above; frequencies are
interpolated linearly in Hz, which makes Apple's two style 8 sweeps meet at a crossover falling from 20 kHz to
200 Hz.

Against Apple's plans for 497 pairs of the same recordings (`smartmix_plans4.json` in the lab data):

- Apple Dead-Air Removal, 393 pairs: SmartMix agrees on 347, with the overlap within 1 s on 93% and 2 s on
  97% (mean difference 0.46 s). The other 46 get an overlap under the fade.
- Apple Smart Cross-Fade, 43 pairs: SmartMix agrees on 19. Apple decides from its own song sections, which
  audio alone does not give; the local test reproduces 73% of its "fading ending" verdicts and 76% of its
  "start section" verdicts. SmartMix never enters more than a few bars into the next song; Apple entered up
  to 31 s in.
- Apple beat-matched, 41 pairs: SmartMix blends 1 (same 15.4 s length as Apple's). Most of the rest fail the
  tempo gate: the two estimates differ by more than 8%, often by a 4:3 or 3:2 ratio.
- Apple's 2 s fallback, 20 pairs: SmartMix analyses the file itself, so it uses gapless there.

- Reverb (styles 33 and 44): Apple's traces give a "non-silent duration" for the outgoing ending; on 43 traced
  pairs it used reverb whenever that was 4 s or less and never at 6 s or more. Counting the half-seconds above
  -55 dB after the fall starts reproduces the number (mean difference 0.5 s) and the choice on 40 of 43. On the
  19 pairs where SmartMix and Apple both overlap, the reverb choice agrees on 14. SmartMix's reverb is in the
  song's path instead of on a send, so the dry signal drops about 5 dB as the reverb comes up.

Not built: the Pop styles (16, 20), a key or vocal-clash check, bar lines.

SmartMix's tempo estimate against Apple's for the same songs (about 320): within 2% on 67%, and on 87% when
SmartMix's own confidence is 0.82 or more (the rest of those are at half, double or a 3:2 ratio). A plain
chroma key detector tried offline matched Apple's key on 58% of 118 songs and a related key (relative, parallel
or a fifth away) on another 29%.

## On-device analysis, stage 1: beat grid and bar lines (2026-11-18)

`SmartMixBeatGrid` (not used by playback yet) tracks beats through the whole song by dynamic programming over
the existing onset curve, and picks the bar line as the beat phase where harmony, timbre and bass change most.
Scored against Apple's `beats` and `bars` for 316 songs of the same master (within 70 ms, after removing a
constant offset of up to 100 ms per song; the tracking tightness, confidence formula and thresholds were tuned
on these same songs):

| | Share |
|---|---|
| Beats match Apple's | 60% (55% without the offset correction) |
| At double or half Apple's tempo | 10% |
| On the off-beat | 1% |
| Wrong | 29%, mostly a tempo Apple reads differently (2:3, 4:3) or sliding between beat and off-beat |
| Bar line matches, when the beats do | 81% (chance is 25%; misses are half a bar or one beat) |

A confidence from the audio alone (tempo clarity, steadiness of the beat phase, agreement with a looser run)
at 0.7 or more trusts 31% of songs; of those 86% match Apple's beats, 93% counting double or half tempo, and
72% match beats and bar line. Pop is best (94% right when trusted), Rock worst (37% right overall), and
Electronic misses are all a tempo-level choice (Apple 150 to 174 BPM, SmartMix 75 to 88). Apple's beats are
not a fixed grid: half the songs stray 0.4 s or more from a straight line. Cost in a release build on the
Mac: 0.31 s to decode a four-minute song and 0.035 s to analyse it.

The existing 30 s tempo estimate places its beat about 50 ms late against Apple's beats. Both songs of a blend
carry the same error, so it cancels in the alignment.

## Answers so far to the four questions

- Same genre: mostly Dead-Air Removal like everything else; beat-matching appears for danceable genres.
- Different genre: Dead-Air Removal or the 2 s fallback. No beat-matched blend across unlike genres seen yet.
- Abrupt next to a fade-out: the overlap covers the fade-out and the next song starts from its first note.
  A cold ending gets 1 to 2 s.
- Losing parts of a song: nothing is lost in 85% of pairs. Loss is confined to the beat-matched and Smart
  Cross-Fade strategies.

## Not known yet

- Which song-structure boundaries the planner keeps (explains the last 13% of Smart Cross-Fade verdicts).
- Which of the four Smart Cross-Fade styles gets the score, and how beat-matched candidates are scored.
- The catalogue against recordings (one pair per seen style recorded, three taken apart at 2 s resolution):
  style 8 matches in shape (outgoing loses highs first and lows last while speeding up 2 to 4%, incoming
  arrives highs first), style 1 matches (incoming at -3 dB at the midpoint of a 2 s fade), style 4 was
  inconclusive because the tool loses a ring-out more than 25 dB down. The other recordings are not analysed.
- Beat-Matched Dance and Hip-Hop have never fired here: no pair in this library has both songs in those
  genres.
- Whether the iPhone plans the same transitions as the Mac.
- Same song into many others, and reversed pairs.
