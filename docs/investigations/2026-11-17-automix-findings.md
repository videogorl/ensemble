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
| Beat-Matched Filtered Cross-Fade | both main genres in a list of about 50 (includes Rock, Alternative-adjacent, Electronic, Dance, Hip-Hop, Pop sub-genres) but not both Pop; same acoustic, danceability, time-signature and tempo checks | genre (most), acousticness, danceability, tempo |
| Smart Cross-Fade | genres in the same broad list; the outgoing song's last loudness section trends downward; the incoming song opens with a distinct start section | no fading ending (285), no start section (121), genre (25) |
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

Numbered variants ("styles") are separate effect recipes within a strategy: Smart Cross-Fade 3, 4, 33, 44;
Beat-Matched Pop 16, 20; Filtered Cross-Fade 8, 9, 12. What each one does to level and tone is being
measured from recordings.

## Answers so far to the four questions

- Same genre: mostly Dead-Air Removal like everything else; beat-matching appears for danceable genres.
- Different genre: Dead-Air Removal or the 2 s fallback. No beat-matched blend across unlike genres seen yet.
- Abrupt next to a fade-out: the overlap covers the fade-out and the next song starts from its first note.
  A cold ending gets 1 to 2 s.
- Losing parts of a song: nothing is lost in 85% of pairs. Loss is confined to the beat-matched and Smart
  Cross-Fade strategies.

## Not known yet

- How the planner cuts a loudness curve into sections and decides one is "fading out" or a "start section".
  Apple's published fade times do not predict it. Reading the framework's code would settle it.
- The level and filter curves of each numbered style. Recordings of one pair per style are being fitted.
- Beat-Matched Dance and Hip-Hop have never fired here: no pair in this library has both songs in those
  genres.
- Whether the iPhone plans the same transitions as the Mac.
- Same song into many others, and reversed pairs.
