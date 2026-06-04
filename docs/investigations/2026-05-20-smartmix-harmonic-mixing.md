# SmartMix Harmonic Mixing Investigation

Date: 2026-05-20

## Context

SmartMix currently handles silence-aware overlap, equal-power fades, outgoing high-pass filtering, beat-aware timing, and confidence-gated tempo matching. It does not currently perform harmonic mixing: `AVAudioUnitTimePitch.pitch` remains at `0`, so tempo/rate changes preserve the original musical pitch.

This investigation captures research and a possible implementation direction for detecting musical key, deciding whether pitch shift would improve a SmartMix transition, and avoiding shifts that would make vocals sound unnatural.

## Research Summary

Apple provides the rendering primitive for pitch shifting through `AVAudioUnitTimePitch.pitch`. The unit is cents; `100` cents is one semitone and `1200` cents is one octave. Apple does not appear to expose a public "detect musical key" API suitable for app-side SmartMix planning. `SoundAnalysis` can run classifiers, but it is not a built-in key estimation service.

Common key detection pipelines are chroma or HPCP based:

- Downmix audio into a bounded analysis window.
- Emphasize harmonic content where practical.
- Fold spectral energy into 12 pitch classes.
- Compare the pitch-class profile against major/minor key templates such as Krumhansl or Temperley.
- Treat confidence as a combination of absolute fit, margin between the best and second-best keys, chroma clarity, and agreement across sub-windows.

DJ-oriented harmonic mixing is conservative. Typical rules use same key, neighboring Camelot keys, or relative major/minor relationships. Automatic key matching in DJ software usually keeps shifts small; VirtualDJ documents automatic harmonic adjustment up to one semitone. Larger shifts can be obvious, especially with exposed vocals.

DJ practice also avoids harmonic clashes through phrasing and EQ. Transitions are safer during percussion or instrumental sections, and DJs commonly reduce low end from the outgoing track while blending.

## Sources

- Apple `AVAudioUnitTimePitch.pitch`: https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch/pitch?language=objc
- Apple `absoluteCents`: https://developer.apple.com/documentation/audiotoolbox/audiounitparameterunit/absolutecents
- Apple SoundAnalysis: https://developer.apple.com/documentation/SoundAnalysis
- Essentia music extractor/key fields: https://essentia.upf.edu/streaming_extractor_music.html
- Essentia KeyExtractor API: https://mtg.github.io/essentia.js/docs/api/EssentiaExtractor.html
- librosa chroma overview: https://deepwiki.com/librosa/librosa/4.2-chroma-and-tonal-features
- Mixed In Key harmonic mixing overview: https://mixedinkey.com/integration/harmonic-mixing-101/
- VirtualDJ harmonic mixing/key matching: https://virtualdj.com/wiki/harmonicmixing.html
- Beatmatching/EQ transition context: https://en.wikipedia.org/wiki/Beatmatching

## Recommended Product Shape

Treat harmonic mixing as an automatic SmartMix layer, not a separate user control.

The first shippable version should:

- Detect key only from bounded SmartMix windows.
- Attach confidence to every key estimate.
- Shift pitch only when confidence is high and the shift is musically small.
- Prefer shifting the outgoing deck during the overlap, since it is already fading out and high-passed.
- Ease pitch shift in and reset it before the deck becomes live again.
- Skip pitch shifting when vocals are prominent or confidence is weak.

## Proposed Analysis Model

Extend `SmartMixAnalysis` with compact harmonic fields:

- `estimatedKey`: pitch class plus major/minor mode.
- `keyConfidence`: `0...1`.
- `keyStrength`: best-profile score.
- `keyMargin`: best minus second-best score.
- `keyWindow`: analyzed time range.
- `harmonicStatus`: analyzed, low confidence, unavailable, vocal-heavy, too-short.

Do not cache PCM. Analysis should remain bounded and in-memory, matching the existing SmartMix analysis policy.

Suggested windows:

- Outgoing: up to 30 seconds ending at the silence-trimmed outro point.
- Incoming: up to 30 seconds starting after leading silence and the planned intro cut.

## Proposed Planning Rules

Keep the current SmartMix plan valid even when key analysis is absent.

Pitch-shift eligibility:

- Both tracks must have high key confidence.
- The transition must be long enough to ease in and hide artifacts.
- Device state must pass the same kind of conservative gates used for tempo matching.
- Vocal risk must be low, or the allowed shift must be reduced.

Decision rules:

- Same key or compatible Camelot/relative key: no pitch shift.
- One semitone away with high confidence: allow `±100` cents.
- Two semitones away only with excellent confidence and low vocal risk: consider `±200` cents, but this should be treated as experimental.
- Anything larger: no pitch shift.

Preferred target:

- Shift the outgoing deck toward the incoming key during overlap.
- Keep incoming track at its original key so the promoted track settles naturally.

## Engine Behavior

Use existing deck-local `AVAudioUnitTimePitch` nodes:

- The deck being tempo-ramped can also receive a pitch target.
- Pitch should be eased with the same style of smooth ramp used for tempo/high-pass changes.
- Start pitch easing around 15-25% transition progress.
- Reset outgoing deck pitch to `0` when the transition finishes, cancels, seeks, route-rebuilds, or falls back.

Important: this is whole-deck pitch shifting. It does not isolate vocals from instruments.

## Vocal Guardrails

Pitch shifting exposed vocals is the highest artifact risk.

Possible first-pass vocal-risk signals:

- Timed lyrics indicate active vocals during the overlap.
- Existing vocal-isolation path can provide a bounded vocal-energy estimate.
- Chroma/key confidence is unstable across sub-windows, which often happens with dense vocals or ambiguous harmony.

Suggested policy:

- Vocal-heavy overlap: skip pitch shift or cap at `±50` cents.
- Mostly instrumental/percussive overlap: allow `±100` cents when confidence is high.
- No reliable vocal signal: use conservative defaults.

## Instrument-Only Pitch Shift

Instrument-only pitch shifting is technically interesting but should not be the first implementation.

The current instrumental mode uses an isolation effect in the output path. It is not currently a two-stem, per-deck render graph where vocals and instruments can be processed independently and recombined. Real-time per-deck stem splitting during a two-deck SmartMix transition would likely be CPU-heavy and risky on older devices.

A safer future experiment would be bounded offline rendering for the transition window:

- Render only the 10-15 second outgoing overlap window.
- Split vocals/instruments for that window.
- Pitch-shift the instrumental stem only.
- Recombine with the unshifted vocal stem.
- Schedule the rendered overlap segment only when all steps complete before the transition.
- Fall back to whole-deck or no pitch shift on any failure.

This should be treated as a later research phase, not a dependency for first harmonic SmartMix.

## Open Questions

- Is `±100` cents audible in a good way during real SmartMix transitions, or does it produce more artifacts than benefit?
- Should key compatibility use Camelot mapping, direct semitone distance, or both?
- Can the existing vocal-isolation implementation provide a cheap enough vocal-energy confidence signal on device?
- Should key detection run only for downloaded/local resolved files, or also for temporary stream cache files?
- Is it acceptable to shift the outgoing deck's pitch while also tempo-ramping it, or should harmonic mixing be disabled when assertive tempo matching is active?

## Suggested Implementation Order

1. Add pure key estimation and confidence tests with synthetic chroma fixtures.
2. Extend SmartMix analysis and planner with harmonic fields and pitch-shift decisions, but keep engine pitch disabled.
3. Add whole-outgoing-deck pitch easing with strict `±100` cent bounds and vocal guardrails.
4. Device-test common transitions with and without vocals.
5. Only after whole-deck pitch proves useful, investigate bounded instrument-only overlap rendering.
